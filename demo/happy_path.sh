#!/usr/bin/env bash
# Camino feliz EN AWS: eventos válidos a bronze + referencia de clientes, y
# (con --run) una ejecución completa hasta gold (~7.5 min). Se corre el viernes;
# en la charla se muestra la ejecución SUCCEEDED en la consola de Step Functions.
#
# OJO: el pipeline solo marca un archivo como procesado si el batch PASA el gate.
# Un archivo roto que quedó en bronze se re-lee en cada corrida y tumba también
# el camino feliz. Este script se niega a correr si encuentra alguno
# (limpiar con ./reset_bronze.sh).
#
#   ./happy_path.sh          # solo sube los datos
#   ./happy_path.sh --run    # sube y corre el pipeline hasta el final
source "$(dirname "$0")/_env.sh"

[[ -n "$PIPELINE_DIR" ]] || { echo "Define PIPELINE_DIR=<checkout del pipeline> (genera datos válidos y customers.csv)."; exit 2; }
BRONZE="s3://$PIPELINE_PREFIX-bronze"
PENDING="$(aws s3 ls "$BRONZE/source=crm/" --recursive | grep -c 'schema_break_demo_' || true)"
if [[ "$PENDING" -gt 0 ]]; then
  echo "Hay $PENDING archivo(s) schema_break_demo_* en bronze: el camino feliz fallaría."
  echo "Límpialos primero con ./reset_bronze.sh"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "1/3 Generando ${RECORDS:-200} eventos válidos + referencia de clientes"
(cd "$PIPELINE_DIR" && .venv/bin/python -m event_pipeline generate-sample \
  --output "$WORK/sample" --records "${RECORDS:-200}" --defect-rate 0 --anchor now >/dev/null)
cat "$WORK"/sample/crm_events_*.jsonl | gzip -c > "$WORK/happy.jsonl.gz"

DT="$(date -u +%F)"; HR="$(date -u +%H)"; TS="$(date -u +%H%M%S)"
say "2/3 Subiendo a bronze"
aws s3 cp "$WORK/sample/customers.csv" "$BRONZE/reference/customers.csv" --only-show-errors
aws s3 cp "$WORK/happy.jsonl.gz" "$BRONZE/source=crm/dt=$DT/hr=$HR/happy_path_demo_$TS.jsonl.gz" --only-show-errors
echo "   $BRONZE/reference/customers.csv"
echo "   $BRONZE/source=crm/dt=$DT/hr=$HR/happy_path_demo_$TS.jsonl.gz"

if [[ "${1:-}" == "--run" ]]; then
  say "3/3 Corriendo el pipeline completo (bronze → silver → gold, ~7.5 min)"
  "$DEMO_DIR/run_pipeline.sh"
else
  say "3/3 Listo. Corre ./run_pipeline.sh cuando quieras"
fi
