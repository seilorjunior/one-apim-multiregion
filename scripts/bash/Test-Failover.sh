#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
stop_region="" timeout=600 origin_wait=900 yes=false what_if=false report_path=""
while (( $# )); do
    case "$1" in
        --stop-region) stop_region="${2:?Missing --stop-region value}"; shift 2 ;;
        --timeout-seconds) timeout="${2:?Missing --timeout-seconds value}"; shift 2 ;;
        --origin-wait-seconds) origin_wait="${2:?Missing --origin-wait-seconds value}"; shift 2 ;;
        --report-path) report_path="${2:?Missing --report-path value}"; shift 2 ;;
        --yes) yes=true; shift ;;
        --what-if) what_if=true; shift ;;
        *) lab_error "Usage: bash Test-Failover.sh --stop-region Primary|Secondary [--timeout-seconds 600] [--origin-wait-seconds 900] [--report-path path.json] [--yes] [--what-if]"; exit 1 ;;
    esac
done
[[ "$stop_region" == Primary || "$stop_region" == Secondary ]] || {
    lab_error "--stop-region must be Primary or Secondary."; exit 1;
}
lab_range --timeout-seconds "$timeout" 60 1800
lab_range --origin-wait-seconds "$origin_wait" 0 1800
lab_require_tools azd
lab_load_environment
lab_assert_values API_URL
lab_regions
lab_region "$stop_region"
target="$LAB_CLUSTER" target_location="$LAB_LOCATION"
survivor=Primary
[[ "$stop_region" != Primary ]] || survivor=Secondary
lab_region "$survivor"
survivor_location="$LAB_LOCATION"
action="Scale lab-api to zero in $target, test failover to $survivor_location, then restore its original replicas."
if [[ "$what_if" == true ]]; then echo "What if: $action"; exit 0; fi
lab_require_tools az curl
lab_confirm "$action" "$yes"
report_helper="$LAB_ROOT/scripts/failover_report.py"
report_args=(init "${LAB_ENV[APP_INGRESS_MODE]-public}" "$stop_region" "$target_location" "$survivor" "$survivor_location" "$timeout")
[[ -z "$report_path" ]] || report_args+=(--path "$report_path")
report_path="$("$LAB_PYTHON" "$report_helper" "${report_args[@]}")"
echo "Failover report: $report_path"
report() { "$LAB_PYTHON" "$report_helper" "$@" --path "$report_path"; }
report_failed=false restore=false
cleanup_report() {
    if ! report "$@"; then
        report_failed=true
        lab_warn "Could not persist cleanup evidence; restoration will still be attempted."
    fi
}
cleanup_failover() {
    local status=$? recovery_since restored_replicas restoration_ok=true
    trap - EXIT
    trap '' INT TERM
    # Cleanup commands are checked explicitly so one failure never skips reporting.
    set +e
    if [[ "$restore" == true ]]; then
        cleanup_report stage restoration running
        echo "Restoring $target to $replicas replicas..." >&2
        if lab_aks "$target" "kubectl scale deployment lab-api -n apim-lab --replicas=$replicas && kubectl rollout status deployment/lab-api -n apim-lab --timeout=180s"; then
            recovery_since="$(lab_now)"
            cleanup_report stage restoration passed
        else
            cleanup_report stage restoration failed
            lab_warn "Could not restore $target. Restore lab-api to $replicas replicas manually."
            status=1 restoration_ok=false
        fi
        cleanup_report stage replicaVerification running
        if restored_replicas="$(lab_aks "$target" "kubectl get deployment lab-api -n apim-lab -o jsonpath='{.spec.replicas}'")"; then
            if [[ "$restored_replicas" =~ ^[0-9]+$ ]]; then cleanup_report replicas restored "$restored_replicas"; fi
            if [[ "$restored_replicas" == "$replicas" ]]; then
                cleanup_report stage replicaVerification passed
            else
                cleanup_report stage replicaVerification failed
                status=1 restoration_ok=false
            fi
        else
            cleanup_report stage replicaVerification failed
            status=1 restoration_ok=false
        fi
        if [[ "$restoration_ok" == true ]]; then
            cleanup_report stage recoveryOrigins running
            if bash "$LAB_SCRIPT_DIR/Test-Origins.sh" --since "$recovery_since" --wait-seconds "$origin_wait"; then
                cleanup_report stage recoveryOrigins passed
            else
                cleanup_report stage recoveryOrigins failed
                status=1
            fi
            cleanup_report stage recoverySmoke running
            if bash "$LAB_SCRIPT_DIR/Test-Lab.sh" --wait-seconds 600; then
                cleanup_report stage recoverySmoke passed
            else
                cleanup_report stage recoverySmoke failed
                status=1
            fi
        fi
    fi
    [[ "$report_failed" != true ]] || status=1
    cleanup_report finish "$status"
    [[ "$report_failed" != true ]] || status=1
    if (( status == 0 )); then
        echo "PASS recovery: original replicas restored and both Front Door origins healthy after restoration. This does not require this client to move back."
    fi
    lab_cleanup
    exit "$status"
}
trap cleanup_failover EXIT
sample_request() {
    local phase="$1" started tick error=none result=0
    region=""
    read -r started tick < <("$LAB_PYTHON" "$report_helper" clock) || return 3
    if ! lab_http GET "${LAB_ENV[API_URL]}/whoami?$phase=$RANDOM-$SECONDS" 15; then
        error=transport result=1
    elif [[ "$LAB_HTTP_STATUS" != 200 ]]; then
        error=http result=1
    elif row="$(lab_response "$target_location" "$survivor_location")"; then
        region="${row%%$'\t'*}"
    else
        error=invalidResponse result=2
    fi
    report sample "$phase" "$started" "$tick" "$LAB_HTTP_STATUS" "$region" "$error" || return 3
    return "$result"
}
report stage readiness running
lab_readiness Workloads
report stage readiness passed
report stage preflightOrigins running
bash "$LAB_SCRIPT_DIR/Test-Origins.sh" --wait-seconds "$origin_wait"
report stage preflightOrigins passed
report stage rollouts running
for key in Primary Secondary; do
    lab_region "$key"
    lab_aks "$LAB_CLUSTER" 'kubectl rollout status deployment/lab-api -n apim-lab --timeout=120s'
done
replicas="$(lab_aks "$target" "kubectl get deployment lab-api -n apim-lab -o jsonpath='{.spec.replicas}'")"
[[ "$replicas" =~ ^[1-9][0-9]*$ ]] || { lab_error "Target must have a positive replica count before the failure test."; exit 1; }
report replicas original "$replicas"
report stage rollouts passed
report stage baseline running
for ((sample=1; sample<=5; sample++)); do
    sample_request baseline
    baseline_region="$region"
    echo "Baseline sample $sample: region=$baseline_region"
done
report stage baseline passed
transition_evidence=ContinuedService
[[ "$baseline_region" != "$target_location" ]] || transition_evidence=ObservedTransition
echo "Last baseline region=$baseline_region; stopping=$target_location."
start=$SECONDS consecutive=0 failures=0
report stage disruption running
restore=true
lab_aks "$target" 'kubectl scale deployment lab-api -n apim-lab --replicas=0 && kubectl rollout status deployment/lab-api -n apim-lab --timeout=120s'
stopped_replicas="$(lab_aks "$target" "kubectl get deployment lab-api -n apim-lab -o jsonpath='{.spec.replicas}'")"
[[ "$stopped_replicas" == 0 ]] || { lab_error "Target workload did not scale to zero."; exit 1; }
report replicas stopped 0
report stage disruption passed
report stage availability running
while :; do
    if sample_request failover; then
        echo "t=$((SECONDS - start))s region=$region"
        if [[ "$region" == "$survivor_location" ]]; then consecutive=$((consecutive + 1)); else consecutive=0; fi
    else
        sample_status=$?
        (( sample_status != 2 )) || { lab_error "Invalid failover response."; exit 1; }
        (( sample_status != 3 )) || { lab_error "Could not persist failover sample."; exit 1; }
        failures=$((failures + 1)) consecutive=0
        lab_warn "Expected disruption during failover: HTTP $LAB_HTTP_STATUS."
    fi
    (( SECONDS - start < timeout )) || { lab_error "Failover did not stabilize within $timeout seconds."; exit 1; }
    (( consecutive < 5 )) || break
    sleep 5
done
report stage availability passed
echo "PASS availability: five consecutive responses from $survivor_location; evidence=$transition_evidence; elapsed=$((SECONDS - start))s; failed samples=$failures."
if [[ "$transition_evidence" == ContinuedService ]]; then
    lab_warn "The client was already using the surviving region. Availability passed; a client traffic transition was not observed."
fi
echo "Elapsed time includes Azure Run Command overhead; it is not an exact outage-duration measurement."
