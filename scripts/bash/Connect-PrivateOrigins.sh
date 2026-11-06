#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
approve=false
yes=false
wait_seconds=600
while (( $# )); do
    case "$1" in
        --approve) approve=true; shift ;;
        --yes) yes=true; shift ;;
        --wait-seconds) [[ $# -ge 2 ]] || { lab_error "Missing --wait-seconds value."; exit 1; }; wait_seconds="$2"; shift 2 ;;
        *) lab_error "Usage: bash Connect-PrivateOrigins.sh [--approve [--yes]] [--wait-seconds 0..1800]"; exit 1 ;;
    esac
done
lab_range wait-seconds "$wait_seconds" 0 1800
[[ "$yes" != true || "$approve" == true ]] || { lab_error "--yes requires --approve."; exit 1; }
lab_require_tools azd az
lab_load_environment
if [[ "${LAB_ENV[APP_INGRESS_MODE]:-public}" == public ]]; then
    echo "Public ingress: no Private Link approval is required."
    exit 0
fi
[[ "${LAB_ENV[APP_INGRESS_MODE]}" == private ]] || { lab_error "APP_INGRESS_MODE must be public or private."; exit 1; }
declare -A approved=()
deadline=$((SECONDS + wait_seconds))
while true; do
    states="$(lab_private_origins)"
    pending=false
    while IFS=$'\t' read -r origin status connection profile; do
        [[ "$status" == Pending || "$status" == Initializing ]] || continue
        pending=true
        [[ "$approve" == true ]] || {
            lab_error "Private Link is pending or initializing; both origin approvals are not yet verified. Inspect requests, then run Connect-PrivateOrigins.sh --approve. After approval, rerun Deploy-LabApi.sh."; exit 1;
        }
        if [[ "$connection" != - && -z "${approved[$connection]:-}" ]]; then
            lab_warn "The request marker is not authentication. Confirm $connection belongs to $profile before approving."
            if [[ "$yes" != true ]]; then
                read -r -p "Approve this connection? [y/N] " answer
                [[ "$answer" == y || "$answer" == Y ]] || { lab_error "Approval was not performed. Private ingress is not ready."; exit 1; }
            fi
            marker="$(lab_private_link_marker "$profile")"
            az network private-endpoint-connection approve --id "$connection" --description "$marker" --only-show-errors >/dev/null
            approved["$connection"]=true
        fi
    done <<< "$states"
    if [[ "$pending" == false ]]; then
        echo "PASS: both expected origin connections are approved (Front Door or verified gateway-side evidence). Runtime TLS/API health still requires publication and fresh origin checks."
        exit 0
    fi
    (( SECONDS < deadline )) || {
        lab_error "Private Link is still pending or initializing; both origin approvals are not yet verified. Inspect connections and allow propagation, then rerun the check. No unrelated requests were approved."; exit 1;
    }
    sleep 20
done
