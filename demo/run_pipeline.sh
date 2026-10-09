#!/usr/bin/env bash
# Arranca una ejecución del pipeline y sigue su estado hasta que termina.
# Con el contrato roto, termina en FAILED en ValidateAndStage: eso dispara al agente.
source "$(dirname "$0")/_env.sh"

SM_ARN="$(state_machine_arn)"
[[ -z "$SM_ARN" || "$SM_ARN" == "None" ]] && { echo "No encuentro $STATE_MACHINE_NAME"; exit 1; }

NAME="demo-$(date -u +%Y%m%d-%H%M%S)"
say "Arrancando $STATE_MACHINE_NAME ($NAME)"
EXEC_ARN="$(aws stepfunctions start-execution --state-machine-arn "$SM_ARN" --name "$NAME" \
  --input '{"run_id": null, "date_range": null}' --query executionArn --output text)"
echo "   $EXEC_ARN"
echo "   consola: https://$AWS_REGION.console.aws.amazon.com/states/home?region=$AWS_REGION#/v2/executions/details/$EXEC_ARN"
T0=$(date +%s)

while :; do
  STATUS="$(aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --query status --output text)"
  printf '\r   %-10s %3ss' "$STATUS" "$(( $(date +%s) - T0 ))"
  [[ "$STATUS" != "RUNNING" ]] && break
  sleep 3
done
echo

if [[ "$STATUS" == "FAILED" ]]; then
  say "FAILED $(date -u +%H:%M:%SZ) — EventBridge despierta al agente ahora"
  aws stepfunctions get-execution-history --execution-arn "$EXEC_ARN" --reverse-order \
    --query "events[?type=='TaskFailed'] | [0].taskFailedEventDetails.cause" --output text \
    | cut -c1-400
  echo
  echo "Siguiente: ./watch_agent.sh"
fi
