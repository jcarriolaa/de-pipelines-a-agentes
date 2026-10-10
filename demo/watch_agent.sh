#!/usr/bin/env bash
# Logs del agente en vivo, del runtime activo (AgentCore o Fargate).
#   ./watch_agent.sh              # el agente
#   ./watch_agent.sh dispatcher   # la Lambda que lo lanza (si el agente no arranca)
source "$(dirname "$0")/_env.sh"

SINCE="${SINCE:-15m}"
RUNTIME="$(tf_out agent_runtime)"

if [[ "${1:-}" == "dispatcher" ]]; then
  GROUP="/aws/lambda/$(tf_out dispatcher_function_name)"
elif [[ "$RUNTIME" == "fargate" ]]; then
  GROUP="$(tf_out fargate_log_group)"
else
  GROUP="/aws/bedrock-agentcore/runtimes/$(tf_out agentcore_runtime_id)-DEFAULT"
fi

say "Siguiendo $GROUP (runtime: ${RUNTIME:-?})"
echo "   esperando eventos… (Ctrl+C para salir)"

# Consulta cada 3 s en vez de `aws logs tail --follow`: con un pipe, el CLI
# guarda la salida en buffer y las líneas llegan tarde o en bloque.
MINUTES="${SINCE%m}"
LAST=$(( ($(date +%s) - ${MINUTES:-15} * 60) * 1000 ))
while :; do
  OUT="$(aws logs filter-log-events --log-group-name "$GROUP" --start-time "$LAST" --output json 2>/dev/null || echo '{}')"
  NEW_LAST="$(jq -r '[.events[]?.timestamp] | max // empty' <<<"$OUT")"
  jq -r '.events[]?.message' <<<"$OUT" | while IFS= read -r line; do
    if pretty="$(jq -r '
        if .event == "tool_use" then "🔧 \(.tool): \(.input.command // .input.file_path // (.input | tostring) | .[0:200])"
        elif .event == "tool_result" then "   ↳ \(if .ok then "ok" else "⛔ DENEGADO / ERROR" end) \(.preview[0:140])"
        elif .event == "agent_text" then "💭 \(.text[0:300])"
        elif .event == "agent_start" then "\n🚨 AGENTE DESPIERTO · \(.model) · max_turns=\(.max_turns) · budget=$\(.max_budget_usd)"
        elif .event == "repo_ready" then "📦 repo clonado en rama \(.branch)"
        elif .event == "pr_opened" then "\n📬 DRAFT PR ABIERTO: \(.url)"
        elif .event == "published" then "📧 correo enviado"
        elif .event == "agent_result" then "\n✅ LISTO · \(.num_turns) turnos · \(.wall_clock_s) s · $\(.total_cost_usd)\n   causa: \(.diagnosis.causa)"
        elif .event == "agent_error" then "❌ \(.error[0:300])"
        elif .event == "dispatch" or .dispatch then "📨 dispatcher → \(.dispatch // "")"
        else empty end' <<<"$line" 2>/dev/null)"; then
      if [[ -n "$pretty" ]]; then echo "$pretty"; fi
    elif [[ "$GROUP" == /aws/lambda/* ]]; then
      echo "$line"
    fi
  done || true   # el monitor nunca se cae: una línea rara no lo detiene
  if [[ -n "$NEW_LAST" ]]; then LAST=$(( NEW_LAST + 1 )); fi
  sleep 3
done
