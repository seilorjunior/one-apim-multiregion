#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
temporary_admin=false samples=20 timeout=600 rbac_wait=600 origin_wait=900 yes=false what_if=false
while (( $# )); do
    case "$1" in
        --temporary-cluster-admin) temporary_admin=true; shift ;;
        --samples) samples="${2:?Missing --samples value}"; shift 2 ;;
        --timeout-seconds) timeout="${2:?Missing --timeout-seconds value}"; shift 2 ;;
        --rbac-wait-seconds) rbac_wait="${2:?Missing --rbac-wait-seconds value}"; shift 2 ;;
        --origin-wait-seconds) origin_wait="${2:?Missing --origin-wait-seconds value}"; shift 2 ;;
        --yes) yes=true; shift ;;
        --what-if) what_if=true; shift ;;
        *) lab_error "Usage: bash Test-EndToEnd.sh [--temporary-cluster-admin] [--samples 20] [--timeout-seconds 600] [--rbac-wait-seconds 600] [--origin-wait-seconds 900] [--yes] [--what-if]"; exit 1 ;;
    esac
done
lab_range --samples "$samples" 1 100
lab_range --timeout-seconds "$timeout" 60 1800
lab_range --rbac-wait-seconds "$rbac_wait" 30 1800
lab_range --origin-wait-seconds "$origin_wait" 0 1800
lab_require_tools azd
lab_load_environment
lab_assert_values AZURE_ENV_NAME API_URL
lab_regions
action="Environment ${LAB_ENV[AZURE_ENV_NAME]}: test ${LAB_ENV[AKS_PRIMARY_NAME]} and ${LAB_ENV[AKS_SECONDARY_NAME]} sequentially; restore original replicas."
[[ "$temporary_admin" != true ]] || action+=" Grant temporary Cluster Admin only where needed; remove only newly created assignments."
if [[ "$what_if" == true ]]; then echo "What if: $action"; exit 0; fi
lab_require_tools az curl
lab_confirm "$action" "$yes"
role_id=b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b
assignments=() scopes=() names=()
declare -A replicas
failover_started=false
cleanup_e2e() {
    local status=$? key count index remaining
    trap - EXIT
    if [[ "$failover_started" == true ]]; then
        for key in Primary Secondary; do
            lab_region "$key"
            count="${replicas[$LAB_CLUSTER]}"
            echo "Ensuring original replica count on $LAB_CLUSTER: $count" >&2
            if ! lab_aks "$LAB_CLUSTER" "kubectl scale deployment lab-api -n apim-lab --replicas=$count && kubectl rollout status deployment/lab-api -n apim-lab --timeout=180s"; then
                lab_warn "Could not restore $LAB_CLUSTER. Restore lab-api to $count replicas manually."
                status=1
            fi
        done
    fi
    for ((index=0; index<${#assignments[@]}; index++)); do
        if ! az role assignment delete --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" --ids "${assignments[index]}" --only-show-errors; then
            lab_warn "Could not remove temporary assignment ${assignments[index]}"
            status=1
            continue
        fi
        if ! remaining="$(az role assignment list --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" \
            --scope "${scopes[index]}" --query "[?name=='${names[index]}']" --output json --only-show-errors)"; then
            lab_warn "Could not verify removal of ${assignments[index]}"
            status=1
            continue
        fi
        if ! "$LAB_PYTHON" -c 'import json,sys; assert json.load(sys.stdin) == [], "Assignment is still present after deletion"' <<< "$remaining"; then
            lab_warn "Temporary assignment removal not verified: ${assignments[index]}"
            status=1
            continue
        fi
        echo "Temporary access removed and verified: ${assignments[index]}"
    done
    lab_cleanup
    return "$status"
}
trap 'cleanup_e2e; exit $?' EXIT
bash "$LAB_SCRIPT_DIR/Test-Origins.sh" --wait-seconds "$origin_wait"
if [[ "$temporary_admin" == true ]]; then
    user="$(az ad signed-in-user show --output json --only-show-errors)"
    user_id="$(lab_json_field id <<< "$user")"
    upn="$(lab_json_field userPrincipalName <<< "$user")"
    [[ -n "$user_id" && -n "$upn" ]] || { lab_error "Temporary Cluster Admin requires an interactive Azure CLI user login."; exit 1; }
    echo "Temporary access identity: $upn"
    for key in Primary Secondary; do
        lab_region "$key"
        scope="/subscriptions/${LAB_ENV[AZURE_SUBSCRIPTION_ID]}/resourceGroups/${LAB_ENV[AZURE_RESOURCE_GROUP]}/providers/Microsoft.ContainerService/managedClusters/$LAB_CLUSTER"
        existing="$(az role assignment list --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" \
            --assignee "$user_id" --scope "$scope" --include-inherited --include-groups --output json --only-show-errors)"
        has_role="$("$LAB_PYTHON" -c '
import json,sys
items = json.load(sys.stdin)
print("yes" if any(item["roleDefinitionId"].split("/")[-1] == sys.argv[1] for item in items) else "no")
' "$role_id" <<< "$existing")"
        if [[ "$has_role" == yes ]]; then
            echo "Preserving existing AKS RBAC Cluster Admin access on $LAB_CLUSTER."
            continue
        fi
        name="$("$LAB_PYTHON" -c 'import uuid; print(uuid.uuid4())')"
        id="$scope/providers/Microsoft.Authorization/roleAssignments/$name"
        assignments+=("$id") scopes+=("$scope") names+=("$name")
        az role assignment create --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" \
            --name "$name" --assignee-object-id "$user_id" --assignee-principal-type User \
            --role "$role_id" --scope "$scope" --output json --only-show-errors >/dev/null
        echo "Temporary access granted on $LAB_CLUSTER: $id"
    done
fi
for key in Primary Secondary; do
    lab_region "$key"
    deadline=$((SECONDS + rbac_wait))
    while :; do
        probe="$(lab_aks_result "$LAB_CLUSTER" 'kubectl auth can-i get deployments.apps -n apim-lab --quiet && kubectl auth can-i watch deployments.apps -n apim-lab --quiet && kubectl auth can-i get deployments.apps --subresource=scale -n apim-lab --quiet && kubectl auth can-i update deployments.apps --subresource=scale -n apim-lab --quiet')"
        code="$(lab_json_field exitCode <<< "$probe")"
        [[ "$code" != 0 ]] || break
        if [[ "$code" != 1 || "$temporary_admin" != true ]] || (( SECONDS >= deadline )); then
            lab_error "Kubernetes access is not ready on $LAB_CLUSTER: $(lab_json_field logs <<< "$probe"). Grant workload access or use --temporary-cluster-admin with role-assignment permissions."
            exit 1
        fi
        lab_warn "Waiting for Azure RBAC propagation on $LAB_CLUSTER."
        sleep 15
    done
    lab_aks "$LAB_CLUSTER" 'kubectl rollout status deployment/lab-api -n apim-lab --timeout=180s'
    count="$(lab_aks "$LAB_CLUSTER" "kubectl get deployment lab-api -n apim-lab -o jsonpath='{.spec.replicas}'")"
    [[ "$count" =~ ^[1-9][0-9]*$ ]] || { lab_error "Expected a positive replica count on $LAB_CLUSTER."; exit 1; }
    replicas["$LAB_CLUSTER"]="$count"
done
lab_readiness Workloads
echo "Running initial smoke test..."
bash "$LAB_SCRIPT_DIR/Test-Lab.sh" --wait-seconds 120 --samples "$samples"
for key in Primary Secondary; do
    lab_region "$key"
    echo "Testing failure of $LAB_LOCATION ($key)..."
    failover_started=true
    bash "$LAB_SCRIPT_DIR/Test-Failover.sh" --stop-region "$key" --timeout-seconds "$timeout" --origin-wait-seconds "$origin_wait" --yes
    lab_aks "$LAB_CLUSTER" 'kubectl rollout status deployment/lab-api -n apim-lab --timeout=180s'
    count="$(lab_aks "$LAB_CLUSTER" "kubectl get deployment lab-api -n apim-lab -o jsonpath='{.spec.replicas}'")"
    [[ "$count" == "${replicas[$LAB_CLUSTER]}" ]] || { lab_error "Replica count was not restored on $LAB_CLUSTER."; exit 1; }
done
# Run cleanup before the final smoke test so role-removal errors cannot look like success.
cleanup_e2e
LAB_TMP="$(mktemp -d)"
trap lab_cleanup EXIT
echo "Running final smoke test after restoring replicas and removing temporary access..."
bash "$LAB_SCRIPT_DIR/Test-Origins.sh" --wait-seconds "$origin_wait"
bash "$LAB_SCRIPT_DIR/Test-Lab.sh" --wait-seconds 600 --samples "$samples"
echo "PASS: both failover directions completed, workloads restored, and global API healthy: ${LAB_ENV[API_URL]}"
lab_warn "This is a sampled workload-failure test, not a regional outage or exact RTO measurement. Both origins were verified using fresh probe metrics; recovery does not require this client to return to its original region."
