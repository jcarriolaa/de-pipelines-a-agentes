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
# Las líneas del agente son JSON; jq las vuelve legibles en el proyector.
aws logs tail "$GROUP" --follow --since "$SINCE" --format short \
  | while IFS= read -r line; do
      json="${line#* }"
      if pretty="$(jq -r '
          if .event == "tool_use" then "🔧 \(.tool): \(.input.command // .input | tostring | .[0:220])"
          elif .event == "tool_result" then "   ↳ \(if .ok then "ok" else "DENEGADO/ERROR" end) \(.preview[0:160])"
          elif .event == "agent_text" then "💭 \(.text[0:400])"
          elif .event == "agent_start" then "🚨 agente despierto · \(.model) · max_turns=\(.max_turns) · budget=$\(.max_budget_usd)"
          elif .event == "agent_result" then "✅ diagnóstico · \(.num_turns) turnos · \(.wall_clock_s)s · $\(.total_cost_usd) · publicado por \(.published_by)\n\(.diagnosis | tostring)"
          else empty end' <<<"$json" 2>/dev/null)" && [[ -n "$pretty" ]]; then
        echo "$pretty"
      else
        echo "$line"
      fi
    done
