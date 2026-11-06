#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
preview=false
start_resources=false
wait_seconds=1800
while (( $# )); do
    case "$1" in
        --preview) preview=true; shift ;;
        --start-resources) start_resources=true; shift ;;
        --wait-seconds) [[ $# -ge 2 ]] || { lab_error "Missing --wait-seconds value."; exit 1; }; wait_seconds="$2"; shift 2 ;;
        *) lab_error "Usage: bash Provision-Lab.sh [--preview] [--start-resources] [--wait-seconds 30..7200]"; exit 1 ;;
    esac
done
lab_range wait-seconds "$wait_seconds" 30 7200
lab_require_tools azd
if [[ "$preview" == true ]]; then
    azd provision --preview
else
    bash "$LAB_SCRIPT_DIR/Sync-DomainBootstrap.sh" --provision --wait-seconds "$wait_seconds"
    startup=()
    [[ "$start_resources" != true ]] || startup+=(--start-resources)
    bash "$LAB_SCRIPT_DIR/Prepare-Lab.sh" "${startup[@]}" --wait-seconds "$wait_seconds"
    azd provision
fi
