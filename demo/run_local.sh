#!/usr/bin/env bash
# Corre el agente EN TU MÁQUINA contra AWS real (credenciales de tu SSO).
# Sirve para probar antes del deploy y es el PLAN B del sábado si AgentCore falla.
#
#   ./run_local.sh                     # imagen Docker local + evento de ejemplo
#   ./run_local.sh --event otro.json   # con un evento real (copiado de la consola)
#   ./run_local.sh --dry-run           # sin modelo ni AWS: valida imagen y runbook
#   ./run_local.sh --cli               # plan B mínimo: `claude -p` sin contenedor
#   EXEC_ARN=arn:... ./run_local.sh    # arma el evento a partir de una ejecución real
#   PR_LOCAL=1 ./run_local.sh          # + propone el arreglo sobre tu checkout local (sin push)
source "$(dirname "$0")/_env.sh"

EVENT="$DEMO_DIR/sample_event.json"
MODE=docker
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --event) EVENT="$2"; shift 2 ;;
    --dry-run) EXTRA+=(--dry-run); shift ;;
    --cli) MODE=cli; shift ;;
    *) echo "opción desconocida: $1"; exit 2 ;;
  esac
done

if [[ -n "${EXEC_ARN:-}" ]]; then
  # Evento sintético con la forma exacta del de EventBridge, a partir de una ejecución real.
  EVENT="$(mktemp)"
  aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --output json | python3 -c '
import json, sys
from datetime import datetime
d = json.load(sys.stdin)
ms = lambda t: int(datetime.fromisoformat(t).timestamp() * 1000)  # respeta el offset (-06:00)
print(json.dumps({"detail-type": "Step Functions Execution Status Change", "source": "aws.states",
  "detail": {k: d.get(k) for k in ("executionArn", "stateMachineArn", "name", "status", "input", "error", "cause")}
  | {"startDate": ms(d["startDate"]), "stopDate": ms(d["stopDate"])}}))' > "$EVENT"
fi

TOPIC="${DIAGNOSIS_TOPIC_ARN:-$(tf_out diagnosis_topic_arn)}"
MODEL="${MODEL_ID:-us.anthropic.claude-sonnet-4-6}"

if [[ "$MODE" == "cli" ]]; then
  say "Plan B: claude -p local (mismo runbook, mismas tools, mismo guardrail)"
  export CLAUDE_CODE_USE_BEDROCK=1 ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
  cd "$ADDON_DIR/agent"
  claude --bare -p "Una ejecución del pipeline terminó en FAILED. Evento de EventBridge:
$(cat "$EVENT")
Log group: /aws/lambda/$PIPELINE_PREFIX-pipeline · Bucket meta: s3://$PIPELINE_PREFIX-meta · Topic SNS: ${TOPIC:-NO PUBLIQUES}
Sigue el runbook, publica el JSON en SNS una vez y responde con ese JSON." \
    --model "$MODEL" \
    --append-system-prompt "$(cat runbook.md)" \
    --permission-mode dontAsk \
    --allowedTools "Bash(aws stepfunctions get-execution-history *)" "Bash(aws stepfunctions describe-execution *)" \
      "Bash(aws logs start-query *)" "Bash(aws logs get-query-results *)" "Bash(aws logs filter-log-events *)" \
      "Bash(aws s3 cp s3://$PIPELINE_PREFIX-meta* *)" "Bash(aws s3 ls *)" "Bash(aws sns publish *)" \
    --max-budget-usd 1.00 \
    --output-format json | jq '{result, total_cost_usd, num_turns, duration_ms}'
  exit
fi

say "Agente en Docker local (demo-agent:local) · evento: $(basename "$EVENT")"
CREDS=()
if [[ ${#EXTRA[@]} -eq 0 ]]; then
  # Credenciales temporales de tu sesión SSO -> variables de entorno del contenedor.
  while IFS= read -r line; do CREDS+=(-e "${line#export }"); done \
    < <(aws configure export-credentials --profile "$AWS_PROFILE" --format env)
fi
REPO_ARGS=()
if [[ "${PR_LOCAL:-}" == "1" ]]; then
  # Copia de solo lectura del repo; el agente edita un clon dentro del contenedor.
  REPO_ARGS=(-v "${DEMO_REPO_DIR:-$ADDON_DIR}:/src/repo:ro" -e PR_ENABLED=true -e REPO_SOURCE_DIR=/src/repo
             -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*')
fi
docker run --rm --platform linux/arm64 \
  ${CREDS[@]+"${CREDS[@]}"} ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} \
  -e AWS_REGION="$AWS_REGION" -e MODEL_ID="$MODEL" -e DIAGNOSIS_TOPIC_ARN="$TOPIC" \
  -e EVENT_JSON="$(cat "$EVENT")" \
  demo-agent:local python main.py ${EXTRA[@]+"${EXTRA[@]}"}
