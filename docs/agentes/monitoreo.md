# Ficha · Agente de monitoreo

> **Vigila y diagnostica 24/7.** Despierta solo cuando algo falla, encuentra la causa y propone el arreglo.

| | |
|---|---|
| **Objetivo** | Que una falla del pipeline llegue diagnosticada, con la evidencia y una propuesta de arreglo, en minutos y no en horas. |
| **Modo** | **Autónomo**: lo despierta un evento; nadie lo llama. |
| **Dónde vive** | Amazon Bedrock AgentCore Runtime: una microVM aislada por incidente. |
| **Modelo** | Claude Sonnet 4.6 en Amazon Bedrock. |
| **Instrucciones** | [`agent/runbook.md`](../../agent/runbook.md) |
| **Escala al humano** | Siempre: su resultado es un correo y un **draft PR**. El merge lo decide una persona. |
| **En la timeline** | Las 11 am: el incidente. |

---

## 1. Cómo despierta

```
Step Functions termina en FAILED
  → EventBridge (regla: status = FAILED de evtpipe-dev-pipeline)   infra/eventbridge.tf
  → Lambda dispatcher → InvokeAgentRuntime                          infra/dispatcher/handler.py
  → AgentCore levanta una microVM con el contenedor del agente     infra/agentcore.tf
```

## 2. Cómo trabaja (el loop)

| Paso | Qué hace | Con qué |
|---|---|---|
| **Percibir** | Lee el historial de la ejecución y encuentra el error real | `aws stepfunctions get-execution-history` |
| | Busca el `run_id` en los logs de la Lambda | `aws logs filter-log-events` |
| | Lee el manifest: `rejections_by_reason`, `unexpected_fields` | `aws s3 cp s3://evtpipe-dev-meta/... -` |
| **Razonar** | Cruza la evidencia: falta `customer_id` + llegó `customerId` = renombre upstream | el modelo |
| **Actuar** | Edita el contrato, el código y los tests en un clon del repo | Edit en `contracts/`, `src/`, `tests/` |
| **Verificar** | Corre los tests | `python -m pytest -q` |

Después, el **runtime** (código determinístico, no el modelo) valida el diff, abre el draft PR y manda el correo.

## 3. Guardrails

| Candado | Dónde | ¿Depende del modelo? |
|---|---|---|
| Lista cerrada de herramientas + `dontAsk` | `agent/main.py` (`AWS_READ_TOOLS`, `REPO_EDIT_TOOLS`) | Sí |
| Sin subagentes | `agent/main.py` (`disallowed`) | Sí |
| Topes: `max_turns` y `max_budget_usd` ($1) | `agent/main.py` | No |
| Rol IAM de solo lectura + `Deny` explícito | `infra/iam.tf` (`NeverChangeThePipeline`) | **No** |
| El diff solo puede tocar `contracts/`, `src/` y `tests/` | `agent/main.py` (`open_pull_request`) | **No** |
| El token de GitHub lo lee el runtime; el modelo nunca lo ve | `agent/main.py` | **No** |
| Draft PR, nunca merge | GitHub | **No** |

## 4. Lo que medimos

| | |
|---|---|
| Falla → correo | 70–103 s |
| Turnos | 7–16 |
| Costo por incidente | $0.19 (solo diagnóstico) · $0.26–0.39 (con draft PR) |
