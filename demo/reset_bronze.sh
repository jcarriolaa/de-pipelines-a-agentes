#!/usr/bin/env bash
# Quita de bronze los archivos rotos de la demo (schema_break_demo_*).
# Es una acción del OPERADOR (tú), nunca del agente: su rol tiene Deny sobre
# s3:DeleteObject. El bucket es versionado: el borrado deja un delete marker y
# es recuperable.
source "$(dirname "$0")/_env.sh"

BRONZE="s3://$PIPELINE_PREFIX-bronze"
KEYS=()  # bash 3.2 de macOS: sin mapfile
while IFS= read -r key; do [[ -n "$key" ]] && KEYS+=("$key"); done \
  < <(aws s3 ls "$BRONZE/source=crm/" --recursive | awk '{print $4}' | grep 'schema_break_demo_' || true)
if [[ ${#KEYS[@]} -eq 0 ]]; then
  echo "No hay archivos schema_break_demo_* en bronze."
  exit 0
fi
printf '  %s\n' "${KEYS[@]}"
read -r -p "¿Quitar estos ${#KEYS[@]} archivo(s) de bronze? [s/N] " OK
[[ "$OK" == "s" || "$OK" == "S" ]] || { echo "Cancelado."; exit 0; }
for key in "${KEYS[@]}"; do
  aws s3 rm "$BRONZE/$key" --only-show-errors && echo "  quitado: $key"
done
