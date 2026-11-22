#!/usr/bin/env bash
# Incident simulations against the DEPLOYED dev environment (Phase 5+). Every scenario is reversible.
#
#   scripts/simulate_incident.sh unhealthy   # /health returns 503 -> unhealthy-targets alarm
#   scripts/simulate_incident.sh errors      # / returns 500 + ERROR logs -> alb-5xx / app-errors alarms
#   scripts/simulate_incident.sh stop        # scale service to 0 -> no-healthy-targets alarm (SEV1)
#   scripts/simulate_incident.sh reset       # clear faults (does NOT restore desired count - that is
#                                            # the human-approved runbook's job in the "stop" scenario)
#   scripts/simulate_incident.sh status      # show alarms + latest incidents
set -euo pipefail

TF="terraform -chdir=terraform/envs/dev"
APP_URL="$($TF output -raw app_url)"
CLUSTER="$($TF output -raw cluster_name)"
SERVICE="$($TF output -raw service_name)"
TABLE="$($TF output -raw incident_table)"

fault_token() {
  aws secretsmanager get-secret-value --secret-id "$($TF output -raw fault_token_secret_arn)" \
    --query SecretString --output text
}

fault() {
  curl -fsS -X POST -H "X-Fault-Token: $(fault_token)" "$APP_URL/fault/$1"
  echo
}

case "${1:-}" in
  unhealthy)
    fault unhealthy
    echo "Injected: /health -> 503. Expect '<prefix>-unhealthy-targets' ALARM in ~2-3 min."
    ;;
  errors)
    fault errors
    echo "Generating traffic so the 5xx/app-error alarms have datapoints (3 min)..."
    end=$((SECONDS + 180))
    while [ $SECONDS -lt $end ]; do curl -s -o /dev/null "$APP_URL/" || true; sleep 1; done
    ;;
  stop)
    aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 \
      --query 'service.desiredCount' --output text
    echo "Service scaled to 0. Expect '<prefix>-no-healthy-targets' ALARM (SEV1) in ~2-3 min."
    ;;
  reset)
    fault reset || echo "(app unreachable - nothing to reset)"
    ;;
  status)
    aws cloudwatch describe-alarms --alarm-name-prefix "${CLUSTER%-cluster}-" \
      --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
    # Backticks below are JMESPath string literals, not shell substitutions.
    # shellcheck disable=SC2016
    aws dynamodb scan --table-name "$TABLE" \
      --projection-expression "incident_id, severity, #s, title" --expression-attribute-names '{"#s":"status"}' \
      --query 'Items[?starts_with(incident_id.S, `INC-`)].[incident_id.S, severity.S, #s.S, title.S]' \
      --output table 2>/dev/null || aws dynamodb scan --table-name "$TABLE" --max-items 10
    ;;
  *)
    sed -n '2,10p' "$0"
    exit 1
    ;;
esac
