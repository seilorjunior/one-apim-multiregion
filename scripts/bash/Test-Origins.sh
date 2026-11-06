#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/Lab.Common.sh"
since="" wait_seconds=900
while (( $# )); do
    case "$1" in
        --since) since="${2:?Missing --since timestamp}"; shift 2 ;;
        --wait-seconds) wait_seconds="${2:?Missing --wait-seconds value}"; shift 2 ;;
        *) lab_error "Usage: bash Test-Origins.sh [--since ISO-8601-UTC] [--wait-seconds 0..1800]"; exit 1 ;;
    esac
done
lab_range --wait-seconds "$wait_seconds" 0 1800
lab_require_tools azd az
lab_load_environment
lab_assert_values AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP AZURE_FRONT_DOOR_PROFILE APIM_PRIMARY_HOST APIM_SECONDARY_HOST
[[ "${LAB_ENV[APP_INGRESS_MODE]-public}" == public || "${LAB_ENV[APP_INGRESS_MODE]-public}" == private ]] || {
    lab_error "APP_INGRESS_MODE must be public or private."; exit 1;
}
if [[ "${LAB_ENV[APP_INGRESS_MODE]:-public}" == private ]]; then
    lab_assert_values FRONT_DOOR_PRIMARY_ORIGIN_HOST FRONT_DOOR_SECONDARY_ORIGIN_HOST FRONT_DOOR_ORIGIN_GROUP
    [[ "${LAB_ENV[FRONT_DOOR_ORIGIN_GROUP]}" == regional-apis-private ]] || { lab_error "Private ingress outputs are stale. Provision the private topology first."; exit 1; }
    [[ "${LAB_ENV[FRONT_DOOR_PRIMARY_ORIGIN_HOST]}" == "${LAB_ENV[APP_GATEWAY_PRIMARY_HOST]}" &&
        "${LAB_ENV[FRONT_DOOR_SECONDARY_ORIGIN_HOST]}" == "${LAB_ENV[APP_GATEWAY_SECONDARY_HOST]}" ]] || {
        lab_error "Origin host outputs do not match configured private gateways."; exit 1;
    }
else
    [[ "${LAB_ENV[FRONT_DOOR_ORIGIN_GROUP]:-regional-apis}" == regional-apis &&
        "${LAB_ENV[FRONT_DOOR_PRIMARY_ORIGIN_HOST]:-${LAB_ENV[APIM_PRIMARY_HOST]}}" == "${LAB_ENV[APIM_PRIMARY_HOST]}" &&
        "${LAB_ENV[FRONT_DOOR_SECONDARY_ORIGIN_HOST]:-${LAB_ENV[APIM_SECONDARY_HOST]}}" == "${LAB_ENV[APIM_SECONDARY_HOST]}" ]] || {
        lab_error "Ingress outputs are stale. Provision the selected public topology first."; exit 1;
    }
fi
[[ "${LAB_ENV[FRONT_DOOR_PRIMARY_ORIGIN_HOST]:-${LAB_ENV[APIM_PRIMARY_HOST]}}" != "${LAB_ENV[FRONT_DOOR_SECONDARY_ORIGIN_HOST]:-${LAB_ENV[APIM_SECONDARY_HOST]}}" ]] || {
    lab_error "Expected two distinct regional origin hosts."; exit 1;
}
now="$(lab_now)"
since="$("$LAB_PYTHON" -c '
import datetime as dt, sys
now = dt.datetime.fromisoformat(sys.argv[2].replace("Z", "+00:00"))
since = dt.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")) if sys.argv[1] else now - dt.timedelta(minutes=5)
if since.tzinfo is None or since > now:
    raise ValueError("Since must include a timezone and must not be in the future")
print(since.astimezone(dt.timezone.utc).isoformat())
' "$since" "$now")"
resource="/subscriptions/${LAB_ENV[AZURE_SUBSCRIPTION_ID]}/resourceGroups/${LAB_ENV[AZURE_RESOURCE_GROUP]}/providers/Microsoft.Cdn/profiles/${LAB_ENV[AZURE_FRONT_DOOR_PROFILE]}"
lab_readiness Infrastructure
deadline=$((SECONDS + wait_seconds))
while :; do
    now="$(lab_now)"
    query_start="$("$LAB_PYTHON" -c '
import datetime as dt, sys
since, now = (dt.datetime.fromisoformat(value.replace("Z", "+00:00")) for value in sys.argv[1:])
print(min(since, now - dt.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$since" "$now")"
    raw="$(az monitor metrics list --subscription "${LAB_ENV[AZURE_SUBSCRIPTION_ID]}" --resource "$resource" \
        --metric OriginHealthPercentage --interval PT1M --aggregation Minimum \
        --filter "Origin eq '*' and OriginGroup eq '*'" --start-time "$query_start" --end-time "$now" \
        --output json --only-show-errors)"
    result="$(lab_origin_evidence "$raw" "$since" "$now")"
    if [[ "$(lab_json_field status <<< "$result")" == healthy ]]; then
        printf '%s\n' "$result"
        echo "PASS: both protected regional origins have fresh Front Door health-probe evidence."
        exit 0
    fi
    message="$(lab_json_field reasons <<< "$result")"
    (( SECONDS < deadline )) || { lab_error "Regional origin health was not proven: $message"; exit 1; }
    lab_warn "Waiting for Azure Monitor origin health: $message"
    sleep 30
done
