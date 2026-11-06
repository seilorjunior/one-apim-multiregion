#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
start_clusters=false
start_resources=false
wait_seconds=1800
while (( $# )); do
    case "$1" in
        --start-clusters) start_clusters=true; shift ;;
        --start-resources) start_resources=true; shift ;;
        --wait-seconds) [[ $# -ge 2 ]] || { lab_error "Missing --wait-seconds value."; exit 1; }; wait_seconds="$2"; shift 2 ;;
        *) lab_error "Usage: bash Prepare-Lab.sh [--start-resources|--start-clusters] [--wait-seconds 30..7200]"; exit 1 ;;
    esac
done
lab_range wait-seconds "$wait_seconds" 30 7200
lab_require_tools azd az openssl
lab_load_environment
lab_assert_values AZURE_ENV_NAME AZURE_SUBSCRIPTION_ID AZURE_LOCATION APIM_PUBLISHER_EMAIL
[[ "${LAB_ENV[AZURE_ENV_NAME]}" =~ ^[a-z][a-z0-9-]{2,23}$ ]] || {
    lab_error "Environment name must have 3-24 lowercase letters/digits/hyphens and start with a letter."; exit 1;
}
[[ "${LAB_ENV[APIM_PUBLISHER_EMAIL]}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || {
    lab_error "APIM_PUBLISHER_EMAIL must contain a valid publisher email address."; exit 1;
}
if [[ -z "${LAB_ENV[AZURE_SECONDARY_LOCATION]+present}" ]]; then
    LAB_ENV[AZURE_SECONDARY_LOCATION]=eastus
    azd env set AZURE_SECONDARY_LOCATION eastus
fi
if [[ -z "${LAB_ENV[APIM_PUBLISHER_NAME]+present}" ]]; then
    azd env set APIM_PUBLISHER_NAME "Multi-region laboratory"
fi
[[ "${LAB_ENV[AZURE_LOCATION]}" != "${LAB_ENV[AZURE_SECONDARY_LOCATION]}" ]] || {
    lab_error "Primary and secondary regions must be different."; exit 1;
}
for region in "${LAB_ENV[AZURE_LOCATION]}" "${LAB_ENV[AZURE_SECONDARY_LOCATION]}"; do
    [[ "$region" =~ ^[a-z][a-z0-9]+$ ]] || { lab_error "Use the Azure location identifier without spaces: $region"; exit 1; }
done
account="$(az account show --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" --output json --only-show-errors)"
[[ "$(lab_json_field state <<< "$account")" == Enabled ]] || { lab_error "Azure subscription is not enabled."; exit 1; }
if [[ -n "${LAB_ENV[APP_DOMAIN_BOOTSTRAP_PARAMETERS_FILE]:-}" ]]; then
    bash "$LAB_SCRIPT_DIR/Sync-DomainBootstrap.sh"
    lab_load_environment
fi
lab_ingress_configuration
directory="$LAB_ROOT/.azure/${LAB_ENV[AZURE_ENV_NAME]}/tls"
if [[ ! -e "$directory" ]]; then
    lab_new_tls "$directory"
fi
lab_assert_tls "$directory"
lab_gateway_certificate "$directory"
if [[ "${LAB_ENV[APP_INGRESS_MODE]}" == private ]]; then
    for name in APP_GATEWAY_PRIMARY_HOST APP_GATEWAY_SECONDARY_HOST APP_GATEWAY_CERTIFICATE_SECRET_ID APP_GATEWAY_NETWORK_MODE; do
        azd env set "$name" "${LAB_ENV[$name]}"
    done
    lab_warn "Private ingress changes APIM to Internal and adds two billable Application Gateways. Plan cutover and approve expected Front Door Private Link requests before publishing."
fi
azd env set LAB_ROOT_CERTIFICATE "$(lab_base64 "$directory/root.cer")"
if [[ "$start_clusters" == true && "$start_resources" != true ]]; then
    lab_wait_clusters_running true "$wait_seconds"
fi
lab_readiness Prepare "$start_resources" "$wait_seconds"
echo "Prepared lab for subscription ${LAB_ENV[AZURE_SUBSCRIPTION_ID]}: ${LAB_ENV[AZURE_LOCATION]} + ${LAB_ENV[AZURE_SECONDARY_LOCATION]}."
lab_warn "Provisioning creates two Premium classic APIM units, two AKS clusters and Front Door Premium. Charges accrue while resources exist."
