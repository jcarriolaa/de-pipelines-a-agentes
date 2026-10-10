# Ficha · Agente de calidad

> **Audita los datos en runtime.** Que lo que llega cumpla el contrato, y si no, que no pase.

| | |
|---|---|
| **Objetivo** | Detectar datos que no cumplen el contrato **antes** de que lleguen al negocio, y dejar la evidencia. |
| **Modo** | **Autónomo**, en cada carga. |
| **Estado hoy** | **Determinístico**: el contrato + el quality gate del pipeline. Convertirlo en agente es el siguiente paso (ver la sección 3). |
| **Escala al humano** | Cuando el lote supera el umbral de error, o cuando aparece un patrón nuevo de rechazo. |
| **En la timeline** | Las 11 am: es el primero que detecta el cambio del CRM, y su falla despierta al agente de monitoreo. |

---

## 1. Qué hace hoy (sin modelo)

En el paso `ValidateAndStage` del pipeline, cada registro pasa por el contrato:

| Control | Ejemplo | Motivo |
|---|---|---|
| Campos requeridos | falta `customer_id` | `MISSING_REQUIRED` |
| Tipos y formatos | `amount: "diez"` | `INVALID_TYPE` / `INVALID_FORMAT` |
| Valores aceptados | `currency: "BTC"` | `NOT_ACCEPTED_VALUE` |
| Reglas de negocio | monto negativo · evento en el futuro · llegó tarde | `NEGATIVE_AMOUNT` · `FUTURE_EVENT` · `LATE_ARRIVAL` |
| Integridad | cliente que no existe en la referencia | `ORPHAN_CUSTOMER` |

Y a nivel de lote:
- **Quality gate:** si los rechazos superan `max_error_rate` (5%), **no se publica nada** y la ejecución termina en FAILED.
- **Evidencia:** los rechazados van a `quarantine` con sus motivos, y el run deja un `manifest.json` con `rejections_by_reason` y `unexpected_fields`.

Este control es **determinístico a propósito**: es la primera línea de defensa y tiene que dar siempre la misma respuesta.

## 2. Dónde mirar

| Pregunta | Dónde |
|---|---|
| ¿Por qué falló este lote? | `s3://evtpipe-dev-meta/runs/run_id=<id>/manifest.json` |
| ¿Qué registros se rechazaron? | Athena: `evtpipe_dev_quarantine.records` |
| ¿Cuánto llega y cuánto se rechaza? | CloudWatch, namespace `EventPipeline/dev` |

```sql
SELECT _run_id, element_at(_reasons, 1) AS motivo, count(*) AS registros
FROM evtpipe_dev_quarantine.records
GROUP BY 1, 2 ORDER BY 1;
```

## 3. Cómo sería como agente (propuesta)

Lo determinístico **se queda**: decide qué pasa y qué no. El agente se suma **encima**, para lo que una regla fija no ve:

| | |
|---|---|
| **Se dispara** | Después de cada carga, aunque haya pasado el gate. |
| **Herramientas** | Solo lectura: Athena sobre silver y quarantine, los manifests y el contrato. |
| **Qué busca** | Tendencias: la tasa de rechazo sube de 0.5% a 4% (todavía pasa, pero algo cambió). Campos nuevos que empiezan a llegar. Distribuciones raras (todos los montos iguales, un país que desaparece). |
| **Qué produce** | Un reporte corto y, si hace falta, una propuesta de cambio al contrato como draft PR. |
| **Qué NO hace** | Nunca cambia el umbral ni deja pasar un lote rechazado. |
| **Escala al humano** | Siempre que propone tocar el contrato. |
