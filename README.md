# De pipelines a agentes

Demo de la charla **"De pipelines a agentes: Data Engineering autónomo con Claude Code en AWS"**
· AWS Community Day Guatemala · 10 de octubre de 2026 · Joseph Arriola.

Este repo contiene el **contrato de datos y la validación** del pipeline de la demo, en su versión
mínima. Es el código sobre el que el agente de monitoreo propone arreglos como *draft PR*.

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

## Probarlo

```bash
python -m pip install pytest
python -m pytest -q
PYTHONPATH=src python -m eventos.validacion data/crm_events_ok.jsonl            # OK: 5 de 5 válidos
PYTHONPATH=src python -m eventos.validacion data/crm_events_schema_break.jsonl  # FALLA: quarantine rate 100.00% ...
```

## Guardrails del agente

- **En AWS, solo lectura.** Su rol IAM no puede escribir en el pipeline; un `Deny` explícito
  lo garantiza aunque alguien agregue permisos después.
- **Lista cerrada de herramientas** con `permission_mode="dontAsk"`: lo que no está en la lista
  se deniega sin preguntar.
- **El modelo no publica nada.** El commit, el PR y el correo los hace código determinístico
  del runtime, que además verifica que el diff solo toque `contracts/`, `src/` y `tests/`.
- **Draft PR, nunca merge.** Una persona revisa y decide.
