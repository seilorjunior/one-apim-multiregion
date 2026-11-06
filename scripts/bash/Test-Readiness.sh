#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
stage=Workloads start_resources=false wait_seconds=1800
started=$SECONDS
json=false
while (( $# )); do
    case "$1" in
        --stage) stage="${2:?Missing --stage value}"; shift 2 ;;
        --start-resources) start_resources=true; shift ;;
        --json) json=true; shift ;;
        --wait-seconds) wait_seconds="${2:?Missing --wait-seconds value}"; shift 2 ;;
        *) lab_error "Usage: bash Test-Readiness.sh [--stage Infrastructure|Workloads] [--start-resources] [--json] [--wait-seconds 30..7200]"; exit 1 ;;
    esac
done
[[ "$stage" == Infrastructure || "$stage" == Workloads ]] || { lab_error "Invalid --stage."; exit 1; }
lab_range --wait-seconds "$wait_seconds" 30 7200
lab_require_tools azd az
if [[ "$json" == true ]]; then
    arguments=("$LAB_SCRIPT_DIR/../lab_readiness.py" --stage "$stage" --format json --private-check-shell bash --wait-seconds "$wait_seconds")
    [[ "$start_resources" != true ]] || arguments+=(--start-resources)
    "$LAB_PYTHON" "${arguments[@]}"
    exit $?
fi
lab_load_environment
lab_readiness "$stage" "$start_resources" "$wait_seconds"
echo "Readiness prerequisites passed ($((SECONDS - started))s total). Run Test-Lab and Test-Origins separately to prove runtime API/TLS and fresh regional health."
