#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
provision=false
wait_seconds=1800
while (( $# )); do
    case "$1" in
        --provision) provision=true; shift ;;
        --wait-seconds) [[ $# -ge 2 ]] || { lab_error "Missing --wait-seconds value."; exit 1; }; wait_seconds="$2"; shift 2 ;;
        *) lab_error "Usage: bash Sync-DomainBootstrap.sh [--provision] [--wait-seconds 1..7200]"; exit 1 ;;
    esac
done
lab_range wait-seconds "$wait_seconds" 1 7200
lab_load_environment
if [[ -z "${LAB_ENV[APP_DOMAIN_BOOTSTRAP_PARAMETERS_FILE]:-}" ]]; then
    echo "Domain bootstrap not configured; using the existing/manual certificate workflow."
    exit 0
fi
arguments=("$LAB_ROOT/scripts/domain_bootstrap.py" --wait-seconds "$wait_seconds")
if [[ "$provision" == true ]]; then arguments+=(--provision); fi
"$LAB_PYTHON" "${arguments[@]}"
