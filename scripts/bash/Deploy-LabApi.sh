#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
(( $# == 0 )) || { lab_error "Usage: bash Deploy-LabApi.sh"; exit 1; }
lab_require_tools azd az openssl curl
lab_load_environment
lab_assert_values AZURE_ENV_NAME LAB_ROOT_CERTIFICATE
lab_readiness Infrastructure
lab_regions
tls="$LAB_ROOT/.azure/${LAB_ENV[AZURE_ENV_NAME]}/tls"
lab_assert_tls "$tls"
[[ "$(lab_base64 "$tls/root.cer")" == "${LAB_ENV[LAB_ROOT_CERTIFICATE]}" ]] || {
    lab_error "Local TLS CA differs from the azd CA value. Re-run azd provision before deploying workloads."; exit 1;
}
for key in Primary Secondary; do
    lab_region "$key"
    manifest="$LAB_TMP/workload-${key,,}.yaml"
    lab_manifest "$tls" > "$manifest"
    echo "Deploying sample API in $LAB_CLUSTER via AKS Run Command..."
    lab_aks "$LAB_CLUSTER" "kubectl apply -f $(basename -- "$manifest") && kubectl rollout status deployment/lab-api -n apim-lab --timeout=180s" "$manifest"
    command="$(cat <<'EOF'
for i in $(seq 1 60); do
  ip=$(kubectl get service lab-api -n apim-lab -o jsonpath='{.status.loadBalancer.ingress[0].ip}') || exit 1
  if [ "$ip" = "__BACKEND_IP__" ]; then echo "Internal service ready: $ip"; exit 0; fi
  sleep 5
done
echo "Internal Load Balancer did not receive its expected private IP" >&2
exit 1
EOF
)"
    lab_aks "$LAB_CLUSTER" "${command//__BACKEND_IP__/$LAB_BACKEND_IP}"
    rm -f -- "$manifest"
done
deployed_since="$(lab_now)"
lab_readiness Workloads
bash "$LAB_SCRIPT_DIR/Test-Lab.sh" --wait-seconds 1200
bash "$LAB_SCRIPT_DIR/Test-Origins.sh" --since "$deployed_since"
