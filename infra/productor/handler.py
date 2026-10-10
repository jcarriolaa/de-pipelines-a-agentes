"""Productor del CRM: cada N minutos sube eventos válidos a bronze y corre el pipeline.

Hace que el pipeline se vea vivo durante la demo. Se pausa solo:
  * si hay un archivo roto (schema_break_demo_*) pendiente en bronze: después
    de romper el contrato no queremos corridas fallidas extra ni agentes duplicados;
  * si ya hay una ejecución del pipeline corriendo (tarda ~8 min).
"""

import gzip
import json
import os
import random
import uuid
from datetime import datetime, timedelta, timezone

import boto3

BRONZE = os.environ["BRONZE_BUCKET"]
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
RECORDS = int(os.environ.get("RECORDS", "60"))
TIPOS = ["account_created", "account_updated", "payment_received", "payment_refunded", "subscription_cancelled"]

s3 = boto3.client("s3")
sfn = boto3.client("stepfunctions")


def _archivo_roto_pendiente() -> bool:
    pages = s3.get_paginator("list_objects_v2").paginate(Bucket=BRONZE, Prefix="source=crm/")
    return any("schema_break_demo_" in o["Key"] for p in pages for o in p.get("Contents", []))


def _eventos(now: datetime) -> bytes:
    lineas = []
    for _ in range(RECORDS):
        tipo = random.choice(TIPOS)
        pago = tipo.startswith("payment")
        ts = now - timedelta(minutes=random.randint(1, 9))
        lineas.append(json.dumps({
            "event_id": f"evt-{uuid.uuid4().hex[:12]}",
            "source_system": "crm",
            "customer_id": f"cust-{random.randint(1, 50):06d}",
            "event_type": tipo,
            "event_timestamp": ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "amount": round(random.uniform(5, 250), 2) if pago else None,
            "currency": random.choice(["USD", "GTQ", "EUR"]) if pago else None,
            "ingestion_timestamp": (ts + timedelta(seconds=30)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }))
    return gzip.compress(("\n".join(lineas) + "\n").encode())


def handler(event, context):
    if _archivo_roto_pendiente():
        print(json.dumps({"productor": "pausado", "motivo": "archivo roto pendiente en bronze"}))
        return {"status": "pausado"}
    corriendo = sfn.list_executions(stateMachineArn=STATE_MACHINE_ARN, statusFilter="RUNNING", maxResults=1)
    if corriendo["executions"]:
        print(json.dumps({"productor": "saltado", "motivo": "el pipeline ya está corriendo"}))
        return {"status": "saltado"}

    now = datetime.now(timezone.utc).replace(microsecond=0)
    key = f"source=crm/dt={now:%Y-%m-%d}/hr={now:%H}/crm_live_{now:%H%M%S}.jsonl.gz"
    s3.put_object(Bucket=BRONZE, Key=key, Body=_eventos(now))
    nombre = f"crm-{now:%Y%m%d-%H%M%S}"
    sfn.start_execution(stateMachineArn=STATE_MACHINE_ARN, name=nombre,
                        input=json.dumps({"run_id": None, "date_range": None}))
    print(json.dumps({"productor": "ok", "archivo": key, "ejecucion": nombre, "eventos": RECORDS}))
    return {"status": "ok", "ejecucion": nombre}
