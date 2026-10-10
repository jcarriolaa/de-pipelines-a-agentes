# Ficha · Agente de desarrollo

> **Construye pipelines contigo.** Tú diriges, él ejecuta, tú apruebas.

| | |
|---|---|
| **Objetivo** | Diseñar, implementar, probar y revisar cambios en el pipeline y sus contratos de datos. |
| **Modo** | **Interactivo**: corre en tu terminal y te pide permiso antes de editar o ejecutar. |
| **Herramienta** | Claude Code, en el directorio del repo. |
| **Permisos** | Los tuyos, con aprobación paso a paso. Nunca despliega a producción por su cuenta. |
| **Escala al humano** | Siempre. Cada edición, cada comando y cada merge los apruebas tú. |
| **En la timeline** | Las 9:30 am (el pipeline nuevo) y la revisión del PR de las 11 am. |

Para usarlo: abre Claude Code en la raíz del repo y pídele *"lee docs/agentes/desarrollo.md"* antes de empezar.

---

## 1. La arquitectura que tiene que conocer

```
CRM / billing ──► S3 bronze (crudo, inmutable)
                    │
                    ▼
           Step Functions: evtpipe-dev-pipeline
                    │
   ┌────────────────┴─────────────────────────────────────────────┐
   │ 1. ValidateAndStage  (Lambda evtpipe-dev-pipeline)             │
   │      lee bronze → normaliza → valida contra el CONTRATO        │
   │      → tokeniza PII → separa válidos / rechazados              │
   │      rechazados ──► S3 quarantine (con sus motivos)            │
   │      manifest del run ──► S3 meta/runs/run_id=<id>/            │
   │ 2. DQGate            quality gate: max_error_rate              │
   │ 3. MergeSilver       Athena · upsert en silver (Iceberg)       │
   │ 4. BuildDims         Athena · dimensiones de gold, en paralelo │
   │ 5. InsertFact        Athena · hechos de gold                   │
   │ 6. InsertAggDaily    Athena · agregado diario                  │
   │ 7. Finalize          cierra el run                             │
   └────────────────────────────────────────────────────────────────┘
          si algo falla: NotifyFailure ──► ExecutionFailed
```

| Capa | Dónde | Qué contiene |
|---|---|---|
| **bronze** | `s3://evtpipe-dev-bronze/source=<sistema>/dt=<fecha>/hr=<hora>/` | Archivos tal como llegan (JSONL, CSV, gzip). Nunca se editan. |
| **quarantine** | `s3://evtpipe-dev-quarantine/` · tabla `evtpipe_dev_quarantine.records` | Registros rechazados, con `_reasons`, `_raw_payload` y `_run_id`. |
| **meta** | `s3://evtpipe-dev-meta/runs/run_id=<id>/manifest.json` | El manifest de cada run: conteos, `rejections_by_reason`, `unexpected_fields`, versión del contrato. |
| **silver** | `evtpipe_dev_silver.customer_events` (Iceberg) | Eventos válidos, deduplicados y con la PII tokenizada. |
| **gold** | `evtpipe_dev_gold.*` | Modelo estrella: `fact_customer_event`, `dim_customer`, `dim_date`, `dim_source`, `agg_customer_daily` y la vista `v_customer_events_wide`. |

**Reglas que no se rompen:**
- El pipeline solo marca un archivo como procesado si su lote **pasa** el quality gate. Un archivo roto se relee en cada corrida hasta que alguien lo quita.
- Nada llega a silver ni a gold con PII en claro: `customer_id` se convierte en `customer_token` (HMAC) en ValidateAndStage.
- El lote completo falla si los rechazos superan `max_error_rate` (5%): o se publica todo lo válido o nada.

## 2. Los contratos de datos

**Dónde están:** `contracts/`. Cada fuente tiene un contrato JSON Schema (draft-07) con un bloque `x-pipeline` de metadatos.

**Cómo se lee uno** (`contracts/customer_events.schema.json`):

| Parte | Para qué sirve |
|---|---|
| `required` | Campos que deben venir siempre. Si falta uno: `MISSING_REQUIRED`. |
| `properties` | Tipo, `pattern` y `enum` de cada campo. |
| `x-pipeline.version` | Versión semántica del contrato. Se sube en cada cambio. |
| `x-pipeline.pii` | Campos que se tokenizan antes de publicar. |
| `x-pipeline.max_error_rate` | Umbral del quality gate. |
| `x-pipeline.renames` | Mapeo `{"nombre_que_llega": "nombre_del_contrato"}` para cambios de nombre upstream (si existe). |

**Orden de cada registro en la validación** (`src/eventos/validacion.py`):
1. `normalizar_registro`: ajusta nombres y formatos (aquí van los `renames`).
2. `motivos_de_rechazo`: valida contra el contrato.
3. `tokenizar_pii`: reemplaza la PII por un hash.

> Si un campo PII llegara con otro nombre y se renombrara **después** de tokenizar, viajaría en claro. Cualquier ajuste de nombres va en el paso 1.

**Motivos de rechazo que usa el pipeline:**
`MISSING_REQUIRED` · `INVALID_TYPE` · `INVALID_FORMAT` · `NOT_ACCEPTED_VALUE` · `NEGATIVE_AMOUNT` ·
`INVALID_TIMESTAMP` · `NAIVE_TIMESTAMP` · `FUTURE_EVENT` · `LATE_ARRIVAL` · `LATE_BEYOND_WINDOW` ·
`MONETARY_FIELDS_MISSING` · `MALFORMED_RECORD` · `ORPHAN_CUSTOMER`

## 3. Cómo trabaja (recetas)

### Agregar una fuente nueva
1. Crear `contracts/<fuente>_events.schema.json`: `required`, `properties`, y en `x-pipeline` la `version` 1.0.0, la `pii` y el `max_error_rate`.
2. Agregar datos de ejemplo en `data/` (un lote sano y uno con defectos).
3. Agregar tests en `tests/`: un lote válido pasa, un campo requerido faltante tumba el gate, la PII sale tokenizada.
4. Correr `python -m pytest -q`.
5. Abrir un PR con el plan y el resultado de los tests.

### Cambiar un contrato existente
- **Compatible** (campo opcional nuevo, `renames`): subir el *minor* (1.0.0 → 1.1.0).
- **Incompatible** (quitar o renombrar un requerido sin mapeo, cambiar un tipo): subir el *major* y avisar a los consumidores. **Escala al humano.**
- Siempre: test nuevo que pruebe el cambio, y que la PII siga tokenizada.

### Revisar un PR (incluidos los del agente de monitoreo)
1. ¿El cambio va en el lugar correcto del orden normalizar → validar → tokenizar?
2. ¿La PII sigue protegida en todos los caminos?
3. ¿Los tests prueban lo que dicen (valores concretos, no solo "no falla")?
4. ¿La versión del contrato subió como corresponde?
5. Correr `python -m pytest -q` y dar un veredicto **antes** de cambiar nada.

## 4. Convenciones del repo
- Commits y títulos de PR estilo *conventional commits* (`fix(contract): …`, `feat(source): …`), en español.
- Sin atribuciones automáticas en commits ni PRs.
- Nada personal en el repo (correos, account IDs): eso va en `infra/terraform.tfvars`, que no se versiona.
- El merge lo hace una persona.
