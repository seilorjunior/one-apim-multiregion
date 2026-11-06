#!/usr/bin/env bash
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "Bash 4.4 or newer is required." >&2
    exit 1
fi
set -Eeuo pipefail
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+${MSYS2_ARG_CONV_EXCL};}/subscriptions/"
fi
umask 077
LAB_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$LAB_SCRIPT_DIR/../.." && pwd)"
LAB_TMP="$(mktemp -d)"
lab_cleanup() { rm -rf -- "$LAB_TMP"; }
trap lab_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
lab_error() { echo "ERROR: $*" >&2; return 1; }
lab_warn() { echo "WARNING: $*" >&2; }
lab_require_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null || { lab_error "Required tool not found: $tool"; return 1; }
    done
}
if command -v python3 >/dev/null && python3 -c 'import sys; assert sys.version_info >= (3, 9)' 2>/dev/null; then
    LAB_PYTHON=python3
elif command -v python >/dev/null && python -c 'import sys; assert sys.version_info >= (3, 9)' 2>/dev/null; then
    LAB_PYTHON=python
else
    lab_error "Python 3.9 or newer is required for JSON and manifest handling."
    exit 1
fi
declare -A LAB_ENV
lab_load_environment() {
    local raw line name value
    raw="$(azd env get-values)" || return
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=\"(.*)\"$ ]]; then
            name="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            LAB_ENV["$name"]="$value"
        fi
    done <<< "$raw"
}
lab_assert_values() {
    local name
    for name in "$@"; do
        [[ "${LAB_ENV[$name]:-}" =~ [^[:space:]] ]] || {
            lab_error "Missing azd value $name. Set it with: azd env set $name <value>"
            return 1
        }
    done
}
lab_readiness() {
    local stage="${1:-Infrastructure}" start="${2:-false}" wait="${3:-1800}"
    lab_assert_values AZURE_ENV_NAME || return
    local -a arguments=("$LAB_SCRIPT_DIR/../lab_readiness.py" --stage "$stage" --wait-seconds "$wait" --environment-name "${LAB_ENV[AZURE_ENV_NAME]}")
    [[ "$start" != true ]] || arguments+=(--start-resources)
    "$LAB_PYTHON" "${arguments[@]}" || return
    [[ "$stage" == Prepare ]] || lab_private_readiness
}
lab_private_readiness() {
    if [[ "${LAB_ENV[APP_INGRESS_MODE]:-public}" == private ]]; then
        local started=$SECONDS
        echo "START: Certificate metadata validation."
        lab_ingress_configuration || return
        lab_gateway_certificate "$LAB_ROOT/.azure/${LAB_ENV[AZURE_ENV_NAME]}/tls" || return
        echo "PASS: Certificate metadata ($((SECONDS - started))s elapsed). START: Private vault endpoints and isolated DNS."
        lab_gateway_vault_network || return
        echo "PASS: Vault topology ($((SECONDS - started))s elapsed). START: Scoped Private Link approvals."
        bash "$LAB_SCRIPT_DIR/Connect-PrivateOrigins.sh" || return
        echo "PASS: Private access gates ($((SECONDS - started))s total)."
    fi
    return 0
}
lab_ingress_configuration() {
    LAB_ENV[APP_GATEWAY_KEY_VAULT_NETWORK_MODE]="${LAB_ENV[APP_GATEWAY_KEY_VAULT_NETWORK_MODE]-trusted-services}"
    [[ "${LAB_ENV[APP_GATEWAY_KEY_VAULT_NETWORK_MODE]}" == trusted-services || "${LAB_ENV[APP_GATEWAY_KEY_VAULT_NETWORK_MODE]}" == private-endpoints ]] || {
        lab_error "APP_GATEWAY_KEY_VAULT_NETWORK_MODE must be trusted-services or private-endpoints."; return 1;
    }
    LAB_ENV[APP_INGRESS_MODE]="${LAB_ENV[APP_INGRESS_MODE]-public}"
    [[ "${LAB_ENV[APP_INGRESS_MODE]}" == public || "${LAB_ENV[APP_INGRESS_MODE]}" == private ]] || {
        lab_error "APP_INGRESS_MODE must be public or private."; return 1;
    }
    [[ "${LAB_ENV[APP_GATEWAY_NETWORK_MODE]-auto}" == auto || "${LAB_ENV[APP_GATEWAY_NETWORK_MODE]-auto}" == retain ]] || {
        lab_error "APP_GATEWAY_NETWORK_MODE must be auto or retain."; return 1;
    }
    if [[ "${LAB_ENV[APP_INGRESS_MODE]}" == public && -n "${LAB_ENV[APP_GATEWAY_PRIMARY_ID]:-}" && "${LAB_ENV[APP_GATEWAY_NETWORK_MODE]:-auto}" != retain ]]; then
        lab_error "Set APP_GATEWAY_NETWORK_MODE to retain before rollback. In-use Application Gateway subnets cannot be removed."; return 1
    fi
    [[ "${LAB_ENV[APP_INGRESS_MODE]}" == private ]] || return 0
    LAB_ENV[APP_GATEWAY_NETWORK_MODE]=retain
    local key name region host
    for key in PRIMARY SECONDARY; do
        name="APP_GATEWAY_${key}_HOST"
        if [[ -z "${LAB_ENV[$name]:-}" ]]; then
            lab_assert_values APP_GATEWAY_DNS_SUFFIX AZURE_LOCATION AZURE_SECONDARY_LOCATION
            if [[ "$key" == PRIMARY ]]; then region="${LAB_ENV[AZURE_LOCATION]}"; else region="${LAB_ENV[AZURE_SECONDARY_LOCATION]}"; fi
            LAB_ENV["$name"]="gw-$region.${LAB_ENV[APP_GATEWAY_DNS_SUFFIX]}"
        fi
        host="${LAB_ENV[$name],,}"
        "$LAB_PYTHON" -c '
import re, sys
host = sys.argv[1]
if len(host) > 253 or not re.fullmatch(r"([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", host) or re.search(r"(^|\.)((example\.(com|net|org))|invalid|test|localhost|internal|azure-api\.net|azurefd\.net)$", host):
    raise ValueError("Gateway hostname must be under a domain you control and covered by a publicly trusted certificate.")
' "$host" || return
        LAB_ENV["$name"]="$host"
    done
    [[ "${LAB_ENV[APP_GATEWAY_PRIMARY_HOST]}" != "${LAB_ENV[APP_GATEWAY_SECONDARY_HOST]}" ]] || {
        lab_error "Application Gateway regional hostnames must be distinct."; return 1;
    }
    lab_assert_values APP_GATEWAY_KEY_VAULT_NAME APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP APP_GATEWAY_CERTIFICATE_SECRET_ID
    [[ "${LAB_ENV[APP_GATEWAY_CERTIFICATE_SECRET_ID]}" =~ ^https://([a-z0-9-]+)\.vault\.azure\.net/secrets/([a-zA-Z0-9-]+)/?$ &&
        "${BASH_REMATCH[1]}" == "${LAB_ENV[APP_GATEWAY_KEY_VAULT_NAME]}" ]] || {
        lab_error "APP_GATEWAY_CERTIFICATE_SECRET_ID must be a versionless secret URI in the configured Key Vault."; return 1;
    }
    LAB_ENV[APP_GATEWAY_CERTIFICATE_SECRET_ID]="${LAB_ENV[APP_GATEWAY_CERTIFICATE_SECRET_ID]%/}"
}
lab_gateway_certificate() {
    local tls="$1" raw name leaf="$LAB_TMP/gateway-public.cer" issuer subject root_subject
    [[ "${LAB_ENV[APP_INGRESS_MODE]}" == private ]] || return 0
    raw="$(az keyvault show --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" \
        --resource-group "${LAB_ENV[APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP]}" \
        --name "${LAB_ENV[APP_GATEWAY_KEY_VAULT_NAME]}" --output json --only-show-errors)" || return
    if [[ "${LAB_ENV[APP_GATEWAY_KEY_VAULT_NETWORK_MODE]:-trusted-services}" == private-endpoints ]]; then
        lab_assert_values AZURE_ENV_NAME APP_GATEWAY_CERTIFICATE_ORDER_ID || return
        lab_warn "Certificate metadata alone does not prove vault access. Both regional endpoint/DNS paths require deployed-topology verification."
    fi
    "$LAB_PYTHON" -c '
import json, sys
p = json.load(sys.stdin)["properties"]
acl = p.get("networkAcls") or {}
if p.get("enableRbacAuthorization") is not True:
    raise ValueError("Certificate Key Vault must use Azure RBAC.")
if sys.argv[1] == "private-endpoints":
    if p.get("publicNetworkAccess") != "Disabled":
        raise ValueError("Private-endpoints mode requires the certificate vault public network access to remain Disabled.")
elif p.get("publicNetworkAccess") == "Disabled" or (acl.get("defaultAction") == "Deny" and "AzureServices" not in (acl.get("bypass") or "")):
    raise ValueError("Certificate Key Vault must use Azure RBAC and allow Application Gateway through public/trusted-service networking.")
' "${LAB_ENV[APP_GATEWAY_KEY_VAULT_NETWORK_MODE]:-trusted-services}" <<< "$raw" || return
    name="${LAB_ENV[APP_GATEWAY_CERTIFICATE_SECRET_ID]##*/}"
    if [[ -n "${LAB_ENV[APP_GATEWAY_CERTIFICATE_ORDER_ID]:-}" ]]; then
        "$LAB_PYTHON" -c '
import re, sys
prefix = "/subscriptions/" + re.escape(sys.argv[2]) + "/resourceGroups/"
if not re.fullmatch(prefix + r"[^/]+/providers/Microsoft\.CertificateRegistration/certificateOrders/[a-zA-Z0-9._-]+", sys.argv[1], re.I):
    raise ValueError("Certificate order must be a Microsoft.CertificateRegistration order in the configured subscription.")
' "${LAB_ENV[APP_GATEWAY_CERTIFICATE_ORDER_ID]}" "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" || return
        raw="$(az rest --method get --url "${LAB_ENV[APP_GATEWAY_CERTIFICATE_ORDER_ID]}?api-version=2024-11-01" \
            --query 'properties.{status:status,state:provisioningState,product:productType,externalKey:isPrivateKeyExternal,signed:signedCertificate,certificates:certificates}' \
            --output json --only-show-errors)" || return
        "$LAB_PYTHON" -c '
import datetime as dt, json, re, sys
m = json.load(sys.stdin)
if m["status"] != "Issued" or m["state"] != "Succeeded" or m["product"] != "StandardDomainValidatedWildCardSsl" or m["externalKey"] is not False:
    raise ValueError("Purchased wildcard must be Issued/Succeeded with an Azure-managed private key before private ingress is enabled.")
vault, name, *hosts = sys.argv[1:]
bindings = [v for v in m["certificates"].values() if v["keyVaultId"].lower() == vault.lower() and v["keyVaultSecretName"] == name and v["provisioningState"] == "Succeeded"]
if len(bindings) != 1:
    raise ValueError("Purchased certificate is not successfully synchronized to the configured Key Vault secret.")
subject = re.fullmatch(r"CN=\*\.([a-zA-Z0-9.-]+)", m["signed"]["subject"])
if not subject or any(not re.fullmatch(r"[a-zA-Z0-9-]+\." + re.escape(subject[1]), h, re.I) for h in hosts):
    raise ValueError("Purchased wildcard does not cover both gateway hostnames.")
now = dt.datetime.now(dt.timezone.utc)
parse = lambda v: dt.datetime.fromisoformat(v.replace("Z", "+00:00"))
if parse(m["signed"]["notBefore"]) > now or parse(m["signed"]["notAfter"]) <= now + dt.timedelta(days=1):
    raise ValueError("Purchased certificate is not currently valid with more than one day remaining.")
' "/subscriptions/${LAB_ENV[AZURE_SUBSCRIPTION_ID]}/resourceGroups/${LAB_ENV[APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP]}/providers/Microsoft.KeyVault/vaults/${LAB_ENV[APP_GATEWAY_KEY_VAULT_NAME]}" \
            "$name" "${LAB_ENV[APP_GATEWAY_PRIMARY_HOST]}" "${LAB_ENV[APP_GATEWAY_SECONDARY_HOST]}" <<< "$raw" || return
        echo "Purchased certificate issuance, coverage, validity, and Key Vault synchronization verified through Azure metadata. Front Door TLS validation remains mandatory."
        return 0
    fi
    raw="$(az keyvault certificate show --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" \
        --vault-name "${LAB_ENV[APP_GATEWAY_KEY_VAULT_NAME]}" --name "$name" \
        --query '{cer:cer,sid:sid,enabled:attributes.enabled,contentType:policy.secretProperties.contentType,exportable:policy.keyProperties.exportable}' --output json --only-show-errors)" || return
    "$LAB_PYTHON" -c '
import base64, json, pathlib, sys
m = json.load(sys.stdin)
if m["enabled"] is not True or m["contentType"] != "application/x-pkcs12" or m["exportable"] is not True or not m["sid"].lower().startswith(sys.argv[1].lower() + "/"):
    raise ValueError("Key Vault certificate must be enabled, exportable PFX, and correspond to the configured certificate secret.")
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(m["cer"], validate=True))
' "${LAB_ENV[APP_GATEWAY_CERTIFICATE_SECRET_ID]}" "$leaf" <<< "$raw" || return
    openssl x509 -inform DER -in "$leaf" -noout -checkend 86400 || { lab_error "Gateway certificate expires within one day."; return 1; }
    for name in "${LAB_ENV[APP_GATEWAY_PRIMARY_HOST]}" "${LAB_ENV[APP_GATEWAY_SECONDARY_HOST]}"; do
        openssl x509 -inform DER -in "$leaf" -noout -ext subjectAltName | grep -q 'DNS:' || {
            lab_error "Gateway certificate must contain DNS subject alternative names."; return 1;
        }

        openssl x509 -inform DER -in "$leaf" -noout -checkhost "$name" | grep -q 'does match certificate' || {
            lab_error "Gateway certificate SAN does not cover $name."; return 1;
        }
    done
    subject="$(openssl x509 -inform DER -in "$leaf" -noout -subject -nameopt RFC2253)"
    issuer="$(openssl x509 -inform DER -in "$leaf" -noout -issuer -nameopt RFC2253)"
    root_subject="$(openssl x509 -inform DER -in "$tls/root.cer" -noout -subject -nameopt RFC2253)"
    [[ "${issuer#issuer=}" != "${subject#subject=}" && "${issuer#issuer=}" != "${root_subject#subject=}" ]] || {
        lab_error "Gateway TLS cannot use a self-signed certificate or the lab CA."; return 1;
    }
    "$LAB_PYTHON" -c '
import datetime as dt, ssl, subprocess, sys
raw = subprocess.check_output(["openssl", "x509", "-inform", "DER", "-in", sys.argv[1], "-noout", "-startdate"], text=True).strip().split("=", 1)[1]
if ssl.cert_time_to_seconds(raw) > dt.datetime.now(dt.timezone.utc).timestamp():
    raise ValueError("Gateway certificate is not yet valid.")
' "$leaf" || return
    local -a chain_args=()
    if [[ -n "${LAB_ENV[APP_GATEWAY_CERTIFICATE_CHAIN_FILE]:-}" ]]; then
        [[ -f "${LAB_ENV[APP_GATEWAY_CERTIFICATE_CHAIN_FILE]}" ]] || { lab_error "Certificate chain file does not exist."; return 1; }
        if grep -q -- '-----BEGIN .*PRIVATE KEY-----' "${LAB_ENV[APP_GATEWAY_CERTIFICATE_CHAIN_FILE]}"; then
            lab_error "Chain file must contain only public CA certificates, never private keys."; return 1
        fi
        chain_args=(-untrusted "${LAB_ENV[APP_GATEWAY_CERTIFICATE_CHAIN_FILE]}")
    fi
    openssl x509 -inform DER -in "$leaf" -out "$LAB_TMP/gateway-public.pem"
    openssl verify -purpose sslserver "${chain_args[@]}" "$LAB_TMP/gateway-public.pem" || {
        lab_error "Gateway certificate chain is not trusted locally. Supply public intermediates through APP_GATEWAY_CERTIFICATE_CHAIN_FILE if needed; never trust the lab CA."; return 1;
    }
    echo "Gateway public certificate metadata, validity, and local trust chain checked. Front Door public-chain validation remains mandatory after deployment."
}
lab_gateway_vault_network() {
    [[ "${LAB_ENV[APP_INGRESS_MODE]:-public}" == private && "${LAB_ENV[APP_GATEWAY_KEY_VAULT_NETWORK_MODE]:-trusted-services}" == private-endpoints ]] || return 0
    lab_assert_values AZURE_SUBSCRIPTION_ID APP_GATEWAY_KEY_VAULT_NAME APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP || return
    local region endpoint zone gateway prefix ids vnet nic previous_zone="" previous_vnet=""
    local vault="/subscriptions/${LAB_ENV[AZURE_SUBSCRIPTION_ID]}/resourceGroups/${LAB_ENV[APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP]}/providers/Microsoft.KeyVault/vaults/${LAB_ENV[APP_GATEWAY_KEY_VAULT_NAME]}"
    for region in PRIMARY SECONDARY; do
        lab_assert_values "APP_GATEWAY_${region}_ID" "APP_GATEWAY_${region}_VAULT_ENDPOINT_ID" "APP_GATEWAY_${region}_VAULT_DNS_ZONE_ID" || return
        gateway="${LAB_ENV[APP_GATEWAY_${region}_ID]}"
        endpoint="${LAB_ENV[APP_GATEWAY_${region}_VAULT_ENDPOINT_ID]}"
        zone="${LAB_ENV[APP_GATEWAY_${region}_VAULT_DNS_ZONE_ID]}"
        "$LAB_PYTHON" -c '
import re, sys
prefix = re.escape("/subscriptions/" + sys.argv[1] + "/resourceGroups/") + r"[^/]+/providers/Microsoft.Network/"
for value, kind in zip(sys.argv[2:5], (r"applicationGateways/[^/]+", r"privateEndpoints/[^/]+", r"privateDnsZones/privatelink\.vaultcore\.azure\.net")):
    if not re.fullmatch(prefix + kind, value, re.I):
        raise ValueError("Private vault resource IDs must belong to this subscription.")
if sys.argv[4].lower() == sys.argv[5].lower():
    raise ValueError("Private vault access requires separate regional DNS zones.")
' "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" "$gateway" "$endpoint" "$zone" "$previous_zone" || return
        prefix="$LAB_TMP/vault-$region"
        az rest --method get --url "${gateway}?api-version=2024-05-01" --output json --only-show-errors > "$prefix-gateway.json" || return
        az rest --method get --url "${endpoint}?api-version=2024-05-01" --output json --only-show-errors > "$prefix-endpoint.json" || return
        ids="$("$LAB_PYTHON" -c '
import json, re, sys
from pathlib import Path
g = json.loads(Path(sys.argv[1] + "-gateway.json").read_text())["properties"]
p = json.loads(Path(sys.argv[1] + "-endpoint.json").read_text())["properties"]
configs = g["gatewayIPConfigurations"]
if g["provisioningState"] != "Succeeded" or len(configs) != 1 or not configs[0]["properties"]["subnet"]["id"].lower().endswith("/subnets/application-gateway"):
    raise ValueError("Application Gateway is not successfully provisioned in the expected subnet.")
vnet = re.sub(r"/subnets/application-gateway$", "", configs[0]["properties"]["subnet"]["id"], flags=re.I)
connections = p["privateLinkServiceConnections"]
if p["provisioningState"] != "Succeeded" or p["subnet"]["id"].lower() != (vnet + "/subnets/vault-private-endpoints").lower() or vnet.lower() == sys.argv[3].lower() or len(connections) != 1 or len(p["networkInterfaces"]) != 1:
    raise ValueError("Vault endpoint must be successful and local to its isolated gateway VNet.")
c = connections[0]["properties"]
if c["privateLinkServiceId"].lower() != sys.argv[2].lower() or c["groupIds"] != ["vault"] or c["privateLinkServiceConnectionState"]["status"] != "Approved":
    raise ValueError("Vault endpoint must target the exact configured vault, group vault, and be Approved.")
print(vnet)
print(p["networkInterfaces"][0]["id"])
' "$prefix" "$vault" "$previous_vnet")" || return
        ids="${ids//$'\r'/}"
        vnet="${ids%%$'\n'*}"
        nic="${ids#*$'\n'}"
        az rest --method get --url "${vnet}?api-version=2024-05-01" --output json --only-show-errors > "$prefix-vnet.json" || return
        az rest --method get --url "${nic}?api-version=2024-05-01" --output json --only-show-errors > "$prefix-nic.json" || return
        az rest --method get --url "${endpoint}/privateDnsZoneGroups?api-version=2024-05-01" --output json --only-show-errors > "$prefix-groups.json" || return
        az rest --method get --url "${zone}/virtualNetworkLinks?api-version=2024-06-01" --output json --only-show-errors > "$prefix-links.json" || return
        az rest --method get --url "${zone}/A/${LAB_ENV[APP_GATEWAY_KEY_VAULT_NAME]}?api-version=2024-06-01" --output json --only-show-errors > "$prefix-record.json" || return
        "$LAB_PYTHON" -c '
import json, sys
from pathlib import Path
def read(name):
    return json.loads(Path(sys.argv[1] + "-" + name + ".json").read_text())
endpoint, zone, vnet = sys.argv[2:]
if (read("vnet")["properties"].get("dhcpOptions") or {}).get("dnsServers"):
    raise ValueError("Managed private vault DNS requires the Azure-provided VNet resolver.")
p = read("endpoint")["properties"]
n = read("nic")["properties"]
ips = n["ipConfigurations"]
if n["privateEndpoint"]["id"].lower() != endpoint.lower() or len(ips) != 1 or ips[0]["properties"]["subnet"]["id"].lower() != p["subnet"]["id"].lower() or not ips[0]["properties"]["privateIPAddress"]:
    raise ValueError("Endpoint NIC does not identify a single local private address.")
groups = read("groups")["value"]
if len(groups) != 1 or groups[0]["properties"]["provisioningState"] != "Succeeded" or len(groups[0]["properties"]["privateDnsZoneConfigs"]) != 1 or groups[0]["properties"]["privateDnsZoneConfigs"][0]["properties"]["privateDnsZoneId"].lower() != zone.lower():
    raise ValueError("Vault DNS zone group is missing or points to another zone.")
links = read("links")["value"]
if len(links) != 1 or links[0]["properties"]["provisioningState"] != "Succeeded" or links[0]["properties"]["virtualNetwork"]["id"].lower() != vnet.lower() or links[0]["properties"]["registrationEnabled"] is not False:
    raise ValueError("Vault DNS zone must link only to its local gateway VNet without auto-registration.")
records = read("record")["properties"]["aRecords"]
if len(records) != 1 or records[0]["ipv4Address"] != ips[0]["properties"]["privateIPAddress"]:
    raise ValueError("Vault DNS must resolve only to its own endpoint address.")
' "$prefix" "$endpoint" "$zone" "$vnet" || return
        previous_zone="$zone"
        previous_vnet="$vnet"
    done
    echo "PASS: Both private vault endpoint approvals, local gateway VNets, NIC addresses, DNS zone groups and isolated records verified. Runtime TLS still requires end-to-end testing."
}

lab_private_link_marker() {
    "$LAB_PYTHON" -c 'import sys,uuid; print("apim-lab:" + str(uuid.uuid5(uuid.UUID("11fb06fb-712d-4ddd-98c7-e71bbd588830"), sys.argv[1].lower())), end="")' "$1"
}

lab_private_origins() {
    lab_assert_values AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP AZURE_FRONT_DOOR_PROFILE \
        APP_GATEWAY_PRIMARY_ID APP_GATEWAY_SECONDARY_ID APP_GATEWAY_PRIMARY_HOST APP_GATEWAY_SECONDARY_HOST \
        AZURE_LOCATION AZURE_SECONDARY_LOCATION
    [[ "${LAB_ENV[APP_GATEWAY_PRIMARY_ID],,}" != "${LAB_ENV[APP_GATEWAY_SECONDARY_ID],,}" ]] || {
        lab_error "Private ingress requires two distinct regional Application Gateways."; return 1;
    }
    local scope="/subscriptions/${LAB_ENV[AZURE_SUBSCRIPTION_ID]}/resourceGroups/${LAB_ENV[AZURE_RESOURCE_GROUP]}"
    local profile="$scope/providers/Microsoft.Cdn/profiles/${LAB_ENV[AZURE_FRONT_DOOR_PROFILE]}"
    local key origin gateway prefix raw status connections connection host location selection
    prefix="$scope/providers/Microsoft.Network/applicationGateways/"
    for key in PRIMARY SECONDARY; do
        if [[ "$key" == PRIMARY ]]; then origin=br; else origin=us; fi
        gateway="${LAB_ENV[APP_GATEWAY_${key}_ID]}"
        host="${LAB_ENV[APP_GATEWAY_${key}_HOST]}"
        if [[ "$key" == PRIMARY ]]; then location="${LAB_ENV[AZURE_LOCATION]}"; else location="${LAB_ENV[AZURE_SECONDARY_LOCATION]}"; fi
        "$LAB_PYTHON" -c '
import re, sys
gateway, prefix = sys.argv[1:]
if not gateway.lower().startswith(prefix.lower()) or not re.fullmatch(r"[a-zA-Z0-9._-]+", gateway[len(prefix):]):
    raise ValueError("Application Gateway ID is outside the configured lab scope.")
' "$gateway" "$prefix" || return
        raw="$(az rest --method get --url "$profile/originGroups/regional-apis-private/origins/$origin?api-version=2024-09-01" --output json --only-show-errors)" || return
        status="$("$LAB_PYTHON" -c '
import json, sys
p = json.load(sys.stdin)["properties"]
link = p["sharedPrivateLinkResource"]
if link["privateLink"]["id"].lower() != sys.argv[1].lower() or link["groupId"] != "private" or p["hostName"].lower() != sys.argv[2].lower() or p["enforceCertificateNameCheck"] is not True:
    raise ValueError("Private origin does not match configured gateway, private frontend, hostname, and TLS validation.")
status = link.get("status")
if status is None or (isinstance(status, str) and not status.strip()):
    status = "Initializing"
elif status not in ("Approved", "Pending"):
    raise ValueError("Private origin is " + str(status) + ". Investigate before requesting a new connection.")
print(status)
' "$gateway" "$host" <<< "$raw")" || return
        status="${status%$'\r'}"
        connection=-
        if [[ "$status" != Approved ]]; then
            connections="$(az rest --method get --url "$gateway?api-version=2024-05-01" \
                --query properties.privateEndpointConnections --output json --only-show-errors)" || return
            selection="$("$LAB_PYTHON" -c '
import json, re, sys, uuid
connections = json.load(sys.stdin)
gateway, profile, status, raw, host, location = sys.argv[1:]
markers = ("apim-lab:" + str(uuid.uuid5(uuid.UUID("11fb06fb-712d-4ddd-98c7-e71bbd588830"), profile.lower())), "apim-lab:" + profile)
matching = [c for c in connections if c["properties"]["privateLinkServiceConnectionState"]["description"] in markers]
if len(matching) > 1:
    raise ValueError("Multiple requests match the gateway. Inspect and approve the intended connection manually.")
if not matching and status != "Initializing":
    raise ValueError("No matching pending or approved request was found. Inspect Private Link requests; unrelated connections will not be approved.")
identifier = "-"
if matching:
    identifier = matching[0]["id"]
    prefix = gateway + "/privateEndpointConnections/"
    if not identifier.lower().startswith(prefix.lower()) or not re.fullmatch(r"[a-zA-Z0-9._-]+", identifier[len(prefix):]):
        raise ValueError("Private endpoint connection ID is outside the configured gateway scope.")
    gateway_status = matching[0]["properties"]["privateLinkServiceConnectionState"]["status"]
    if gateway_status not in ("Approved", "Pending"):
        raise ValueError("Matching gateway request is " + str(gateway_status) + ". Investigate before requesting a new connection.")
    if gateway_status != "Pending":
        identifier = "-"
        if status == "Initializing":
            p = json.loads(raw)["properties"]
            link = p["sharedPrivateLinkResource"]
            if p.get("provisioningState") != "Succeeded" or p.get("enabledState") != "Enabled" or p.get("originHostHeader", "").lower() != host.lower() or link.get("privateLinkLocation", "").lower() != location.lower() or link.get("requestMessage") not in markers or matching[0]["properties"].get("provisioningState") != "Succeeded":
                raise ValueError("Unreported Front Door status requires a successful enabled origin, exact Host/region/request marker, and a Succeeded/Approved gateway connection.")
            status = "ApprovedAtGateway"
            print("WARNING: Front Door has not reported status; exact scoped gateway connection is Succeeded/Approved. Using gateway-side approval evidence only; runtime TLS/API health remains unverified.", file=sys.stderr)
print(status + "\t" + identifier)
' "$gateway" "$profile" "$status" "$raw" "$host" "$location" <<< "$connections")" || return
            selection="${selection%$'\r'}"
            IFS=$'\t' read -r status connection <<< "$selection"
        fi
        if [[ "$status" == Initializing ]]; then
            lab_warn "Front Door origin $origin has not reported its Private Link status yet and no verified gateway approval is available."
        fi
        printf '%s\t%s\t%s\t%s\n' "$origin" "$status" "$connection" "$profile"
    done
}
lab_wait_clusters_running() {
    local start_clusters="$1" wait_seconds="${2:-1800}" raw rows name group id state power pending
    lab_range wait-seconds "$wait_seconds" 30 7200
    lab_assert_values AZURE_ENV_NAME AZURE_SUBSCRIPTION_ID
    raw="$(az resource list --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" \
        --tag "azd-env-name=${LAB_ENV[AZURE_ENV_NAME]}" \
        --query "[?type=='Microsoft.ContainerService/managedClusters'].{name:name,resourceGroup:resourceGroup,id:id}" \
        --output json --only-show-errors)" || return
    rows="$("$LAB_PYTHON" -c '
import json, re, sys
targets = json.load(sys.stdin)
if not isinstance(targets, list) or len(targets) > 2:
    raise ValueError("Invalid or ambiguous AKS discovery results.")
ids, groups = set(), set()
for target in targets:
    name, group, rid = (target[k] for k in ("name", "resourceGroup", "id"))
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", name) or not re.fullmatch(r"[a-zA-Z0-9_.()-]+", group):
        raise ValueError("Invalid cluster discovery response.")
    expected = f"/subscriptions/{sys.argv[1]}/resourceGroups/{group}/providers/Microsoft.ContainerService/managedClusters/{name}"
    if rid.lower() != expected.lower() or (sys.argv[2] and group.lower() != sys.argv[2].lower()):
        raise ValueError("Discovered AKS scope does not match the selected environment.")
    if rid.lower() in ids:
        raise ValueError("Duplicate AKS discovery results.")
    ids.add(rid.lower())
    groups.add(group.lower())
if len(groups) > 1:
    raise ValueError("Environment AKS clusters span multiple resource groups.")
for target in targets:
    print("|".join(target[k] for k in ("name", "resourceGroup", "id")))
' "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" "${LAB_ENV[AZURE_RESOURCE_GROUP]:-}" <<< "$raw")" || return
    if [[ -z "$rows" ]]; then
        echo "No existing AKS clusters match this environment; Bicep can create them."
        return
    fi
    local deadline=$((SECONDS + wait_seconds))
    local -A requested=()
    local -a stopped=()
    while true; do
        (( SECONDS < deadline )) || {
            lab_error "AKS startup did not reach Running/Succeeded within $wait_seconds seconds. Azure operations may still be running; inspect the clusters before retrying."; return 1;
        }
        pending=false
        stopped=()
        while IFS='|' read -r name group id; do
            raw="$(az aks show --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" \
                --resource-group "$group" --name "$name" \
                --query '{provisioningState:provisioningState,powerState:powerState.code}' \
                --output json --only-show-errors)" || return
            state="$("$LAB_PYTHON" -c '
import json, sys
value = json.load(sys.stdin)
state, power = value["provisioningState"], value["powerState"]
if state not in ("Succeeded", "Starting", "Stopping", "Updating", "Creating") or power not in ("Running", "Stopped"):
    raise ValueError(f"AKS has an unsupported state: {state}/{power}.")
print(state + "|" + power)
' <<< "$raw")" || return
            IFS='|' read -r state power <<< "$state"
            echo "AKS $name: $power/$state."
            [[ "$state" != Succeeded || "$power" != Running ]] || continue
            if [[ "$start_clusters" != true ]]; then
                lab_error "AKS $name is not Running/Succeeded. Use scripts/powershell/Provision-Lab.ps1 -StartResources or scripts/bash/Provision-Lab.sh --start-resources to explicitly start stopped compute before provisioning. Preview and direct azd hooks never start clusters."
                return 1
            fi
            pending=true
            if [[ "$state" == Succeeded && "$power" == Stopped && -z "${requested[$id]:-}" ]]; then
                stopped+=("$name|$group|$id")
            fi
        done <<< "$rows"
        (( SECONDS < deadline )) || {
            lab_error "AKS startup did not reach Running/Succeeded within $wait_seconds seconds. Azure operations may still be running; inspect the clusters before retrying."; return 1;
        }
        [[ "$pending" == true ]] || return 0
        for raw in "${stopped[@]}"; do
            IFS='|' read -r name group id <<< "$raw"
            lab_warn "Starting AKS $name; compute charges resume. Other lab clusters will start without waiting for this operation."
            az aks start --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" \
                --resource-group "$group" --name "$name" --no-wait --output none --only-show-errors || return
            requested["$id"]=true
        done
        sleep 15
    done
}
lab_regions() {
    lab_assert_values AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP AZURE_PRIMARY_LOCATION \
        AZURE_SECONDARY_LOCATION AKS_PRIMARY_NAME AKS_SECONDARY_NAME BACKEND_PRIMARY_IP \
        BACKEND_SECONDARY_IP APIM_PRIMARY_SUBNET APIM_SECONDARY_SUBNET
}
lab_region() {
    local suffix="${1^^}"
    LAB_CLUSTER="${LAB_ENV[AKS_${suffix}_NAME]}"
    LAB_LOCATION="${LAB_ENV[AZURE_${suffix}_LOCATION]}"
    LAB_BACKEND_IP="${LAB_ENV[BACKEND_${suffix}_IP]}"
    LAB_APIM_SUBNET="${LAB_ENV[APIM_${suffix}_SUBNET]}"
}
lab_json_field() {
    "$LAB_PYTHON" -c '
import json, sys
value = json.load(sys.stdin)[sys.argv[1]]
if value is None:
    raise ValueError("Missing JSON value: " + sys.argv[1])
print(value if not isinstance(value, (dict, list)) else json.dumps(value))
' "$1"
}
lab_range() {
    [[ "$2" =~ ^(0|[1-9][0-9]*)$ ]] && (( ${#2} <= 6 )) && (( $2 >= $3 && $2 <= $4 )) || {
        lab_error "$1 must be an integer from $3 to $4."; return 1;
    }
}
lab_confirm() {
    echo "$1" >&2
    if [[ "$2" == true ]]; then return; fi
    local answer
    read -r -p "Continue? [y/N] " answer || { lab_error "Confirmation required; use --yes for unattended execution."; return 1; }
    [[ "$answer" == y || "$answer" == Y ]] || { lab_error "Operation cancelled."; return 1; }
}
lab_aks_result() {
    local cluster="$1" command="$2" file="${3:-}" raw command_id deadline script=""
    local -a args=(aks command invoke --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}"
        --resource-group "${LAB_ENV[AZURE_RESOURCE_GROUP]}" --name "$cluster")
    if [[ "$command" == *$'\n'* || "$command" == *$'\r'* ]]; then
        script="$(mktemp "$LAB_TMP/command-XXXXXXXX.sh")" || return
        printf '%s\n' "${command//$'\r'/}" > "$script"
        command="sh $(basename -- "$script")"
        args+=(--file "$script")
    fi
    [[ -z "$file" ]] || args+=(--file "$file")
    raw="$(az "${args[@]}" --command "$command" --output json --only-show-errors)" || return
    [[ -z "$script" ]] || rm -f -- "$script"
    deadline=$((SECONDS + 600))
    while [[ ! "$raw" =~ ^[[:space:]]*\{ ]]; do
        if [[ "$raw" =~ command\ id:\ ([0-9a-fA-F]{32}),\ started\ at: ]]; then
            command_id="${BASH_REMATCH[1]}"
        else
            lab_error "AKS Run Command returned an unexpected response format for $cluster."; return 1
        fi
        (( SECONDS < deadline )) || { lab_error "AKS command $command_id in $cluster is still running after ten minutes."; return 1; }
        lab_warn "Waiting for AKS command $command_id in $cluster."
        sleep 5
        raw="$(az aks command result --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" \
            --resource-group "${LAB_ENV[AZURE_RESOURCE_GROUP]}" --name "$cluster" \
            --command-id "$command_id" --output json --only-show-errors)" || return
    done
    printf '%s' "$raw" | "$LAB_PYTHON" -c '
import json, sys
result = json.load(sys.stdin)
if type(result.get("exitCode")) is not int:
    raise ValueError("AKS Run Command returned no integer exit code")
print(json.dumps(result))
'
}
lab_aks() {
    local raw
    raw="$(lab_aks_result "$@")" || return
    printf '%s' "$raw" | "$LAB_PYTHON" -c '
import json, sys
result = json.load(sys.stdin)
if result["exitCode"] != 0:
    sys.exit("AKS command failed (exit %s): %s" % (result["exitCode"], result.get("logs", "")))
print(result.get("logs", ""), end="")
'
}
lab_new_tls() {
    local directory="$1" work
    [[ ! -e "$directory" ]] || { lab_error "TLS directory already exists. Refusing to overwrite certificates."; return 1; }
    mkdir -p -- "$directory"
    chmod 700 "$directory"
    work="$(mktemp -d "$LAB_TMP/tls-XXXXXXXX")"
    openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 90 \
        -subj '/CN=APIM Multi Region Lab Root' -keyout "$work/root.key" -out "$work/root.pem" \
        -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign'
    openssl req -new -newkey rsa:2048 -nodes -sha256 -subj '/CN=br.api.lab.internal' \
        -keyout "$directory/tls.key" -out "$work/leaf.csr"
    cat > "$work/leaf.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,serverAuth
subjectAltName=DNS:br.api.lab.internal,DNS:us.api.lab.internal
EOF
    openssl x509 -req -in "$work/leaf.csr" -CA "$work/root.pem" -CAkey "$work/root.key" \
        -set_serial "0x$(openssl rand -hex 16)" -days 60 -sha256 -extfile "$work/leaf.ext" -out "$work/leaf.pem"
    openssl x509 -in "$work/root.pem" -outform DER -out "$directory/root.cer"
    cat "$work/leaf.pem" "$work/root.pem" > "$directory/tls.crt"
    rm -rf -- "$work"
}
lab_assert_tls() {
    local directory="$1" file certificate_key private_key
    for file in root.cer tls.crt tls.key; do
        [[ -s "$directory/$file" ]] || { lab_error "Incomplete TLS material: missing $file in $directory."; return 1; }
    done
    openssl x509 -inform DER -in "$directory/root.cer" -out "$LAB_TMP/root.pem" || return
    openssl x509 -in "$directory/tls.crt" -checkend 604800 -noout || {
        lab_error "Laboratory TLS certificate expires in less than seven days. Rotate and reprovision."; return 1;
    }
    for file in br.api.lab.internal us.api.lab.internal; do
        openssl verify -CAfile "$LAB_TMP/root.pem" -purpose sslserver \
            -verify_hostname "$file" "$directory/tls.crt" || return
    done
    certificate_key="$(openssl x509 -in "$directory/tls.crt" -pubkey -noout)" || return
    private_key="$(openssl pkey -in "$directory/tls.key" -pubout)" || return
    [[ "$certificate_key" == "$private_key" ]] || { lab_error "TLS certificate and key do not match."; return 1; }
}
lab_base64() { openssl base64 -A -in "$1"; }
lab_manifest() {
    "$LAB_PYTHON" -c '
import base64, hashlib, pathlib, re, sys
template, tls, region, cluster, ip, subnet = sys.argv[1:]
text = pathlib.Path(template).read_text(encoding="utf-8")
values = {"REGION": region, "CLUSTER": cluster, "BACKEND_IP": ip, "APIM_SUBNET": subnet}
for key, name in (("TLS_CERTIFICATE", "tls.crt"), ("TLS_KEY", "tls.key")):
    values[key] = base64.b64encode((pathlib.Path(tls) / name).read_bytes()).decode()
for key, value in values.items():
    text = text.replace("__" + key + "__", value)
text = text.replace("__WORKLOAD_HASH__", hashlib.sha256(text.encode("utf-8")).hexdigest())
if re.search(r"__[A-Z_]+__", text):
    raise ValueError("Unresolved workload placeholder")
print(text, end="")
' "$LAB_ROOT/src/lab-api/workload.yaml" "$1" "$LAB_LOCATION" "$LAB_CLUSTER" "$LAB_BACKEND_IP" "$LAB_APIM_SUBNET"
}
lab_http() {
    local method="$1" url="$2" timeout="${3:-30}" status
    local -a args=(--silent --show-error --location --max-time "$timeout"
        --dump-header "$LAB_TMP/headers" --output "$LAB_TMP/body" --write-out '%{http_code}')
    [[ "$method" != HEAD ]] || args+=(--head)
    if status="$(curl "${args[@]}" "$url")"; then
        LAB_HTTP_STATUS="$status"
    else
        LAB_HTTP_STATUS=000
        lab_warn "API transport failure or timeout: $url"
        return 1
    fi
}
lab_response() {
    [[ "$LAB_HTTP_STATUS" == 200 ]] || { lab_error "Unexpected API HTTP status: $LAB_HTTP_STATUS"; return 1; }
    "$LAB_PYTHON" -c '
import json, pathlib, sys
body = json.loads(pathlib.Path(sys.argv[1]).read_text())
for field in ("region", "cluster", "pod"):
    if not isinstance(body.get(field), str) or not body[field].strip():
        raise ValueError("API response must identify region, cluster and pod")
if body["region"] not in sys.argv[3:]:
    raise ValueError("Unexpected backend region: " + body["region"])
headers = pathlib.Path(sys.argv[2]).read_text().splitlines()
gateways = [line.split(":", 1)[1].strip().replace(" ", "").lower()
            for line in headers if line.lower().startswith("x-lab-gateway-region:")]
if not gateways or gateways[-1] != body["region"]:
    raise ValueError("Gateway/backend locality mismatch")
print(body["region"] + "\t" + body["cluster"] + "\t" + body["pod"] + "\t" + gateways[-1])
' "$LAB_TMP/body" "$LAB_TMP/headers" "$@"
}
lab_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
lab_origin_evidence() {
    "$LAB_PYTHON" -c '
import datetime as dt, json, math, sys
def timestamp(value):
    result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Origin timestamps require a timezone")
    return result.timestamp()
raw, since, now, group, *hosts = sys.argv[1:]
metrics = json.loads(raw)
items = [m for m in metrics["value"] if m["name"]["value"] == "OriginHealthPercentage"]
if len(items) != 1:
    raise ValueError("Expected exactly one OriginHealthPercentage metric")
metric = items[0]
if metric.get("errorCode", "Success") != "Success":
    raise ValueError("Origin health metric error: " + metric["errorCode"])
since, now = timestamp(since), timestamp(now)
minimum = math.ceil(since / 60) * 60
reasons, evidence = [], []
for host in hosts:
    expected = host.lower() + ":443"
    series = []
    for item in metric["timeseries"]:
        dims = {v["name"]["value"]: v["value"] for v in item["metadatavalues"]}
        if dims.get("Origin", "").lower() == expected and dims.get("OriginGroup") == group:
            series.append(item)
    if len(series) > 1:
        raise ValueError("Duplicate metric series for " + expected)
    if not series:
        reasons.append(host + ": missing origin metric series")
        continue
    points = sorted((p for p in series[0]["data"]
                     if minimum <= timestamp(p["timeStamp"]) and timestamp(p["timeStamp"]) + 60 <= now),
                    key=lambda p: timestamp(p["timeStamp"]))
    if len(points) < 2:
        reasons.append(host + ": need two completed one-minute buckets after the requested boundary")
        continue
    previous, last = points[-2:]
    last_time = timestamp(last["timeStamp"])
    if last_time - timestamp(previous["timeStamp"]) != 60 or now - last_time > 300:
        reasons.append(host + ": origin evidence is stale or not consecutive")
        continue
    healthy = True
    for point in (previous, last):
        value = point.get("minimum")
        if value is None:
            healthy = False
            continue
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 100:
            raise ValueError("Invalid origin health percentage for " + host)
        if value != 100:
            healthy = False
    if not healthy:
        reasons.append(host + ": both completed buckets must report minimum=100; missing data is not healthy")
        continue
    evidence.append({"origin": expected, "latestBucketUtc": last["timeStamp"], "minimumPercent": 100})
print(json.dumps({"status": "healthy" if not reasons else "waiting", "reasons": reasons, "origins": evidence}))
' "$1" "$2" "$3" "${LAB_ENV[FRONT_DOOR_ORIGIN_GROUP]:-regional-apis}" \
        "${LAB_ENV[FRONT_DOOR_PRIMARY_ORIGIN_HOST]:-${LAB_ENV[APIM_PRIMARY_HOST]}}" \
        "${LAB_ENV[FRONT_DOOR_SECONDARY_ORIGIN_HOST]:-${LAB_ENV[APIM_SECONDARY_HOST]}}"
}
