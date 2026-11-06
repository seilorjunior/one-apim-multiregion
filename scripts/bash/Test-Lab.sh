#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
wait_seconds=0 samples=10
while (( $# )); do
    case "$1" in
        --wait-seconds) wait_seconds="${2:?Missing --wait-seconds value}"; shift 2 ;;
        --samples) samples="${2:?Missing --samples value}"; shift 2 ;;
        *) lab_error "Usage: bash Test-Lab.sh [--wait-seconds 0..3600] [--samples 1..100]"; exit 1 ;;
    esac
done
lab_range --wait-seconds "$wait_seconds" 0 3600
lab_range --samples "$samples" 1 100
lab_require_tools azd curl
lab_load_environment
lab_assert_values API_URL AZURE_PRIMARY_LOCATION AZURE_SECONDARY_LOCATION
lab_readiness Infrastructure
expected=("${LAB_ENV[AZURE_PRIMARY_LOCATION]}" "${LAB_ENV[AZURE_SECONDARY_LOCATION]}")
deadline=$((SECONDS + wait_seconds))
while :; do
    if lab_http GET "${LAB_ENV[API_URL]}/whoami" && [[ "$LAB_HTTP_STATUS" == 200 ]]; then
        lab_response "${expected[@]}" >/dev/null
        break
    fi
    lab_warn "API is not ready: HTTP $LAB_HTTP_STATUS. Infrastructure preflight passed, but runtime DNS/TLS/backend health may still fail; this is not necessarily propagation."
    (( SECONDS < deadline )) || {
        lab_error "API is not ready. Inspect Front Door probes, APIM GatewayLogs, private DNS and AKS pods."; exit 1;
    }
    sleep 15
done
for method in GET HEAD; do
    lab_http "$method" "${LAB_ENV[API_URL]}/health/ready"
    [[ "$LAB_HTTP_STATUS" == 200 ]] || { lab_error "$method readiness failed with HTTP $LAB_HTTP_STATUS."; exit 1; }
done
printf 'Sample\tRegion\tCluster\tPod\tGateway\n'
for ((index=1; index<=samples; index++)); do
    lab_http GET "${LAB_ENV[API_URL]}/whoami?sample=$index"
    row="$(lab_response "${expected[@]}")"
    printf '%s\t%s\n' "$index" "$row"
done
echo "Smoke test passed. A single client may hit only the lower-latency region; this does not prove both origins are healthy."
