"""El paso que falla en la demo: validar un lote de eventos contra su contrato.

Orden de cada registro (importa):
  1. normalizar_registro  -> el registro se ajusta a los nombres del contrato
  2. motivos_de_rechazo   -> se valida contra el contrato
  3. tokenizar_pii        -> los campos PII se reemplazan por un hash

Si un campo PII llegara con otro nombre y se renombrara DESPUÉS de tokenizar,
viajaría en claro. Por eso cualquier ajuste de nombres va en el paso 1.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

CONTRATO = Path(__file__).resolve().parents[2] / "contracts" / "customer_events.schema.json"

_TIPOS = {"string": str, "number": (int, float), "null": type(None)}


class CalidadError(Exception):
    """El lote supera la tasa de error permitida: no se publica nada."""


@dataclass
class Reporte:
    leidos: int = 0
    validos: list[dict[str, Any]] = field(default_factory=list)
    rechazados: int = 0
    rechazos_por_motivo: dict[str, int] = field(default_factory=dict)
    campos_inesperados: list[str] = field(default_factory=list)

    @property
    def tasa_error(self) -> float:
        return self.rechazados / self.leidos if self.leidos else 0.0


def cargar_contrato(ruta: Path = CONTRATO) -> dict[str, Any]:
    return json.loads(Path(ruta).read_text(encoding="utf-8"))


def normalizar_registro(registro: dict[str, Any], contrato: dict[str, Any]) -> dict[str, Any]:
    """Ajusta un registro a los nombres y formatos del contrato, antes de validar.

    Aplica el mapeo declarativo ``x-pipeline.renames`` del contrato: cada campo
    que llega con el nombre antiguo se renombra al nombre canónico.  Si un
    registro trae los dos nombres (el antiguo y el del contrato), gana el del
    contrato (no se sobreescribe).
    """
    renames: dict[str, str] = contrato.get("x-pipeline", {}).get("renames", {})
    if not renames:
        return dict(registro)
    salida = dict(registro)
    for nombre_entrante, nombre_contrato in renames.items():
        if nombre_entrante in salida and nombre_contrato not in salida:
            salida[nombre_contrato] = salida.pop(nombre_entrante)
        elif nombre_entrante in salida:
            # El nombre canónico ya existe: descartamos el alias.
            del salida[nombre_entrante]
    return salida


def motivos_de_rechazo(registro: dict[str, Any], contrato: dict[str, Any]) -> list[str]:
    motivos = []
    for campo in contrato["required"]:
        if registro.get(campo) is None:
            motivos.append("MISSING_REQUIRED")
    for campo, regla in contrato["properties"].items():
        valor = registro.get(campo)
        if valor is None:
            continue
        tipos = regla["type"] if isinstance(regla["type"], list) else [regla["type"]]
        if not isinstance(valor, tuple(_TIPOS[t] for t in tipos)):
            motivos.append("WRONG_TYPE")
        elif "pattern" in regla and not re.match(regla["pattern"], str(valor)):
            motivos.append("PATTERN_MISMATCH")
        elif "enum" in regla and valor not in regla["enum"]:
            motivos.append("NOT_IN_ENUM")
    return motivos


def tokenizar_pii(registro: dict[str, Any], contrato: dict[str, Any], clave: bytes) -> dict[str, Any]:
    salida = dict(registro)
    for campo in contrato["x-pipeline"]["pii"]:
        if salida.get(campo) is not None:
            salida[campo] = hmac.new(clave, str(salida[campo]).encode(), hashlib.sha256).hexdigest()[:16]
    return salida


def validar_lote(
    registros: list[dict[str, Any]], contrato: dict[str, Any], clave: bytes = b"demo"
) -> Reporte:
    """Valida un lote completo y aplica el quality gate del contrato."""
    reporte = Reporte(leidos=len(registros))
    inesperados: set[str] = set()
    for original in registros:
        registro = normalizar_registro(original, contrato)
        inesperados |= set(registro) - set(contrato["properties"])
        motivos = motivos_de_rechazo(registro, contrato)
        if motivos:
            reporte.rechazados += 1
            for motivo in set(motivos):
                reporte.rechazos_por_motivo[motivo] = reporte.rechazos_por_motivo.get(motivo, 0) + 1
        else:
            reporte.validos.append(tokenizar_pii(registro, contrato, clave))
    reporte.campos_inesperados = sorted(inesperados)

    maximo = contrato["x-pipeline"]["max_error_rate"]
    if reporte.tasa_error > maximo:
        raise CalidadError(
            f"quarantine rate {reporte.tasa_error:.2%} exceeds the maximum {maximo:.2%} "
            f"({reporte.rechazados} of {reporte.leidos} records); nothing was published"
        )
    return reporte


def leer_jsonl(ruta: Path) -> list[dict[str, Any]]:
    return [json.loads(linea) for linea in Path(ruta).read_text(encoding="utf-8").splitlines() if linea.strip()]


if __name__ == "__main__":
    import sys

    lote = leer_jsonl(Path(sys.argv[1]))
    try:
        r = validar_lote(lote, cargar_contrato())
        print(f"OK: {len(r.validos)} de {r.leidos} válidos")
    except CalidadError as error:
        print(f"FALLA: {error}")
        sys.exit(5)
