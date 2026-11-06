#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
vus=2 duration=60 p95=1500 p99=3000 summary=load-results/summary.json yes=false what_if=false
while (( $# )); do
    case "$1" in
        --vus) vus="${2:?Missing --vus value}"; shift 2 ;;
        --duration-seconds) duration="${2:?Missing duration}"; shift 2 ;;
        --p95-milliseconds) p95="${2:?Missing p95}"; shift 2 ;;
        --p99-milliseconds) p99="${2:?Missing p99}"; shift 2 ;;
        --summary-path) summary="${2:?Missing summary path}"; shift 2 ;;
        --yes) yes=true; shift ;;
        --what-if) what_if=true; shift ;;
        *) lab_error "Unknown load-test argument: $1"; exit 1 ;;
    esac
done
lab_range --vus "$vus" 1 50
lab_range --duration-seconds "$duration" 1 600
lab_range --p95-milliseconds "$p95" 1 60000
lab_range --p99-milliseconds "$p99" "$p95" 60000
lab_require_tools azd
lab_load_environment
lab_assert_values API_URL AZURE_PRIMARY_LOCATION AZURE_SECONDARY_LOCATION
action="Generate up to $vus concurrent requests to ${LAB_ENV[API_URL]} for $duration seconds, plus drain time."
if [[ "$what_if" == true ]]; then echo "What if: $action"; exit 0; fi
lab_require_tools az k6
lab_confirm "$action" "$yes"
lab_readiness Workloads
mkdir -p -- "$(dirname -- "$summary")"
k6 run --no-usage-report --summary-export "$summary" \
    --env "API_URL=${LAB_ENV[API_URL]}" --env "PRIMARY_REGION=${LAB_ENV[AZURE_PRIMARY_LOCATION]}" \
    --env "SECONDARY_REGION=${LAB_ENV[AZURE_SECONDARY_LOCATION]}" --env CONFIRM_LOAD=yes \
    --env "LOAD_VUS=$vus" --env "LOAD_SECONDS=$duration" \
    --env "LOAD_P95_MS=$p95" --env "LOAD_P99_MS=$p99" "$LAB_SCRIPT_DIR/../../tests/load/lab.js"
echo "PASS: k6 thresholds passed. Summary: $summary. This is not strict regional origin-health or failover evidence."
