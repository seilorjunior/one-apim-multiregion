"""Shared offline contracts for the Bash and PowerShell lab entrypoints."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import math
from pathlib import Path
import re
import sys


class ContractError(ValueError):
    pass


def ingress_configuration(values):
    """Return only normalized settings; never echo the rest of the environment."""
    def required(*names):
        for name in names:
            if not isinstance(values.get(name), str) or not values[name].strip():
                raise ContractError(
                    f"Missing azd value {name}. Set it with: azd env set {name} <value>"
                )

    result = {}
    for name, default, allowed in (
        ("APP_GATEWAY_KEY_VAULT_NETWORK_MODE", "trusted-services",
         ("trusted-services", "private-endpoints")),
        ("APP_INGRESS_MODE", "public", ("public", "private")),
        ("APP_GATEWAY_NETWORK_MODE", "auto", ("auto", "retain")),
    ):
        value = values.get(name, default)
        if value not in allowed:
            raise ContractError(f"{name} must be {' or '.join(allowed)}.")
        if name != "APP_GATEWAY_NETWORK_MODE" or name in values:
            result[name] = value
    if result["APP_INGRESS_MODE"] == "public":
        if values.get("APP_GATEWAY_PRIMARY_ID") and values.get("APP_GATEWAY_NETWORK_MODE") != "retain":
            raise ContractError(
                "Set APP_GATEWAY_NETWORK_MODE to retain before rollback. "
                "In-use Application Gateway subnets cannot be removed."
            )
        return result

    result["APP_GATEWAY_NETWORK_MODE"] = "retain"
    for key, location in (("PRIMARY", "AZURE_LOCATION"), ("SECONDARY", "AZURE_SECONDARY_LOCATION")):
        name = f"APP_GATEWAY_{key}_HOST"
        host = values.get(name)
        if host is not None and not isinstance(host, str):
            raise ContractError(f"{name} must be a hostname string.")
        if host is None or not host.strip():
            required("APP_GATEWAY_DNS_SUFFIX", "AZURE_LOCATION", "AZURE_SECONDARY_LOCATION")
            host = f"gw-{values[location]}.{values['APP_GATEWAY_DNS_SUFFIX']}"
        host = host.lower()
        if (
            len(host) > 253
            or not re.fullmatch(r"([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", host)
            or re.search(r"(^|\.)((example\.(com|net|org))|invalid|test|localhost|internal|azure-api\.net|azurefd\.net)$", host)
        ):
            raise ContractError(
                f"{name} must be a hostname under a domain you control, "
                "covered by a publicly trusted certificate."
            )
        result[name] = host
    if result["APP_GATEWAY_PRIMARY_HOST"] == result["APP_GATEWAY_SECONDARY_HOST"]:
        raise ContractError("Application Gateway regional hostnames must be distinct.")
    required("APP_GATEWAY_KEY_VAULT_NAME", "APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP",
             "APP_GATEWAY_CERTIFICATE_SECRET_ID")
    secret = values["APP_GATEWAY_CERTIFICATE_SECRET_ID"]
    match = re.fullmatch(r"https://([a-z0-9-]+)\.vault\.azure\.net/secrets/([a-zA-Z0-9-]+)/?", secret)
    if not match or match[1].lower() != values["APP_GATEWAY_KEY_VAULT_NAME"].lower():
        raise ContractError(
            "APP_GATEWAY_CERTIFICATE_SECRET_ID must be a versionless secret URI "
            "in the configured Key Vault."
        )
    result["APP_GATEWAY_CERTIFICATE_SECRET_ID"] = secret.rstrip("/")
    return result


def render_manifest(template, tls, region, cluster, ip, subnet):
    text = Path(template).read_text(encoding="utf-8")
    replacements = {"REGION": region, "CLUSTER": cluster, "BACKEND_IP": ip, "APIM_SUBNET": subnet}
    for key, name in (("TLS_CERTIFICATE", "tls.crt"), ("TLS_KEY", "tls.key")):
        replacements[key] = base64.b64encode((Path(tls) / name).read_bytes()).decode("ascii")
    for key, value in replacements.items():
        text = text.replace(f"__{key}__", value)
    text = text.replace("__WORKLOAD_HASH__", hashlib.sha256(text.encode("utf-8")).hexdigest())
    if re.search(r"__[A-Z_]+__", text):
        raise ContractError("Unresolved workload placeholder")
    return text


def timestamp(value):
    try:
        result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        raise ContractError("Origin timestamps must be valid ISO-8601 timestamps.") from None
    if result.tzinfo is None:
        raise ContractError("Origin timestamps require a timezone")
    return result.timestamp()


def origin_evidence(metrics, since, now, group, hosts):
    items = [m for m in metrics["value"] if m["name"]["value"] == "OriginHealthPercentage"]
    if len(items) != 1:
        raise ContractError("Expected exactly one OriginHealthPercentage metric")
    metric = items[0]
    if metric.get("errorCode", "Success") != "Success":
        raise ContractError("Origin health metric reported an error; inspect Azure metric access.")
    since, now = timestamp(since), timestamp(now)
    minimum = math.ceil(since / 60) * 60
    reasons, evidence = [], []
    for host in hosts:
        expected = host.lower() + ":443"
        series = []
        for item in metric["timeseries"]:
            dimensions = {v["name"]["value"]: v["value"] for v in item["metadatavalues"]}
            if dimensions.get("Origin", "").lower() == expected and dimensions.get("OriginGroup") == group:
                series.append(item)
        if len(series) > 1:
            raise ContractError("Duplicate metric series for " + expected)
        if not series:
            reasons.append(host + ": missing origin metric series")
            continue
        points = sorted(
            (p for p in series[0]["data"]
             if minimum <= timestamp(p["timeStamp"]) and timestamp(p["timeStamp"]) + 60 <= now),
            key=lambda p: timestamp(p["timeStamp"]),
        )
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
                raise ContractError("Invalid origin health percentage for " + host)
            if value != 100:
                healthy = False
        if not healthy:
            reasons.append(host + ": both completed buckets must report minimum=100; missing data is not healthy")
            continue
        evidence.append({"origin": expected, "latestBucketUtc": last["timeStamp"], "minimumPercent": 100})
    return {"status": "healthy" if not reasons else "waiting", "reasons": reasons, "origins": evidence}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("ingress")
    manifest = commands.add_parser("manifest")
    for name in ("template", "tls", "region", "cluster", "ip", "subnet"):
        manifest.add_argument("--" + name, required=True)
    manifest.add_argument("--text", action="store_true")
    metrics = commands.add_parser("origins")
    for name in ("since", "now", "group"):
        metrics.add_argument("--" + name, required=True)
    metrics.add_argument("--hosts", nargs=2, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "manifest":
            text = render_manifest(args.template, args.tls, args.region, args.cluster, args.ip, args.subnet)
            if args.text:
                sys.stdout.write(text)
                return 0
            result = {"manifest": text}
        else:
            payload = json.load(sys.stdin)
            if not isinstance(payload, dict):
                raise ContractError("Contract input must be a JSON object.")
            if args.command == "ingress":
                result = ingress_configuration(payload)
            else:
                result = origin_evidence(payload, args.since, args.now, args.group, args.hosts)
    except ContractError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        print("ERROR: Invalid contract input or unreadable workload/TLS file.", file=sys.stderr)
        return 1
    print(json.dumps(result, allow_nan=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
