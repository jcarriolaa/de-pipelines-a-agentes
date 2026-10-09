#!/usr/bin/env bash
# Rompe el contrato SIN tocar el código del pipeline: el CRM "renombra" una columna.
#   customer_id -> customerId   (el clásico schema change upstream del 11am)
# Genera eventos de CRM válidos, renombra el campo y sube el archivo DIRECTO a
# bronze (sin Kinesis/Firehose: sin el minuto de buffer).
#
#   ./break_contract.sh            # genera, rompe y sube
#   ./break_contract.sh --dry-run  # genera y rompe en local; no sube nada
source "$(dirname "$0")/_env.sh"

RECORDS="${RECORDS:-102}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "1/3 Generando $RECORDS eventos válidos del CRM"
python3 - "$RECORDS" > "$WORK/valid.jsonl" <<'PY'
import json, random, sys, uuid
from datetime import datetime, timedelta, timezone
random.seed(7)
now = datetime.now(timezone.utc).replace(microsecond=0)
tipos = ["account_created", "account_updated", "payment_received", "payment_refunded", "subscription_cancelled"]
for _ in range(int(sys.argv[1])):
    tipo = random.choice(tipos)
    pago = tipo.startswith("payment")
    ts = now - timedelta(minutes=random.randint(5, 55))
    print(json.dumps({
        "event_id": f"evt-{uuid.uuid4().hex[:12]}",
        "source_system": "crm",
        "customer_id": f"cust-{random.randint(1, 50):06d}",
        "event_type": tipo,
        "event_timestamp": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "amount": round(random.uniform(5, 250), 2) if pago else None,
        "currency": random.choice(["USD", "GTQ", "EUR"]) if pago else None,
        "ingestion_timestamp": (ts + timedelta(minutes=random.randint(1, 4))).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }))
PY
echo "   $(wc -l < "$WORK/valid.jsonl" | tr -d ' ') eventos"
echo "   antes:   $(head -1 "$WORK/valid.jsonl" | cut -c1-120)…"

say "2/3 Rompiendo el contrato: customer_id -> customerId"
jq -c 'if has("customer_id") then (.customerId = .customer_id | del(.customer_id)) else . end' \
  "$WORK/valid.jsonl" > "$WORK/broken.jsonl"
echo "   después: $(head -1 "$WORK/broken.jsonl" | cut -c1-120)…"
gzip -c "$WORK/broken.jsonl" > "$WORK/broken.jsonl.gz"

DT="$(date -u +%F)"; HR="$(date -u +%H)"; TS="$(date -u +%H%M%S)"
KEY="source=crm/dt=$DT/hr=$HR/schema_break_demo_$TS.jsonl.gz"
DEST="s3://$PIPELINE_PREFIX-bronze/$KEY"

if $DRY_RUN; then
  say "3/3 (dry-run) se subiría a $DEST"
  exit 0
fi

say "3/3 Subiendo a bronze"
aws s3 cp "$WORK/broken.jsonl.gz" "$DEST" --only-show-errors
echo "   $DEST"
echo
echo "Siguiente: make run"
