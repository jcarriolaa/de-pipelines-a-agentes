# De pipelines a agentes

Demo de la charla **"De pipelines a agentes: Data Engineering autónomo con Claude Code en AWS"**
· AWS Community Day Guatemala · 10 de octubre de 2026 · Joseph Arriola.

Este repo contiene el **contrato de datos y la validación** del pipeline de la demo, en su versión
mínima. Es el código sobre el que el agente de monitoreo propone arreglos como *draft PR*.

> 📘 **¿Quieres montarlo tú?** Sigue la [guía paso a paso](docs/GUIA-PASO-A-PASO.md).

## La historia

```
El CRM renombra customer_id → customerId  (un cambio upstream, sin avisar)
  → el pipeline en AWS valida contra el contrato: 100% MISSING_REQUIRED → FAILED
  → EventBridge despierta al agente de monitoreo (Claude Agent SDK en Bedrock AgentCore)
  → el agente diagnostica en solo lectura: Step Functions, CloudWatch Logs, manifest en S3
  → propone el arreglo como draft PR en ESTE repo y avisa por correo
  → una persona revisa, el CI corre los tests, la persona decide el merge
```

El agente propone; tú decides.

## Qué hay aquí

| Ruta | Qué es |
|---|---|
| `contracts/customer_events.schema.json` | El contrato: campos requeridos, tipos, PII y el umbral de calidad (`max_error_rate`). |
| `src/eventos/validacion.py` | Valida un lote: normaliza → valida → tokeniza PII → quality gate. |
| `tests/` | Tests con `pytest`; el CI los corre en cada PR. |
| `data/` | Un lote sano y el mismo lote con el schema roto. |
| `agent/` | El agente: `main.py` (runtime + loop con Claude Agent SDK), `runbook.md` (sus instrucciones) y `Dockerfile` (imagen arm64 para AgentCore). |
| `infra/` | Terraform: regla de EventBridge, Lambda dispatcher, AgentCore Runtime (y Fargate de respaldo), IAM, SNS y secretos. |
| `demo/` | Scripts de la demo: romper el contrato, correr el pipeline, ver al agente en vivo. |
| `docs/agentes/` | Las fichas de los tres agentes del equipo: [desarrollo](docs/agentes/desarrollo.md), [calidad](docs/agentes/calidad.md) y [monitoreo](docs/agentes/monitoreo.md). |

## Probar el contrato y la validación

```bash
python -m pip install pytest
python -m pytest -q
PYTHONPATH=src python -m eventos.validacion data/crm_events_ok.jsonl            # OK: 5 de 5 válidos
PYTHONPATH=src python -m eventos.validacion data/crm_events_schema_break.jsonl  # FALLA: quarantine rate 100.00% ...
```

## Correr la demo

Requiere un pipeline `evtpipe-dev` (Step Functions + S3) desplegado en la cuenta, Docker y Terraform.

```bash
make login                 # aws sso login
make check-bedrock         # ¿el modelo está habilitado en Bedrock?
make infra-ecr && make push && make apply   # infra del agente (pide notification_email en infra/terraform.tfvars)
make break                 # el CRM "renombra" customer_id → customerId y el archivo cae en bronze
make run                   # corre el pipeline: FAILED en segundos
make watch                 # (otra terminal) los pasos del agente en vivo
```

El agente diagnostica, abre un draft PR en este repo y manda el correo. Para el PR, el token de GitHub va en
el secreto `demo-agent/github-token` (fine-grained, solo este repo, Contents + Pull requests).

## Guardrails del agente

- **En AWS, solo lectura.** Su rol IAM no puede escribir en el pipeline; un `Deny` explícito
  lo garantiza aunque alguien agregue permisos después.
- **Lista cerrada de herramientas** con `permission_mode="dontAsk"`: lo que no está en la lista
  se deniega sin preguntar.
- **El modelo no publica nada.** El commit, el PR y el correo los hace código determinístico
  del runtime, que además verifica que el diff solo toque `contracts/`, `src/` y `tests/`.
- **Draft PR, nunca merge.** Una persona revisa y decide.
