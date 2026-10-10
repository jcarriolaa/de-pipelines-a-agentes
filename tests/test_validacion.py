import pytest

from eventos.validacion import CalidadError, cargar_contrato, validar_lote

CONTRATO = cargar_contrato()


def evento(**cambios):
    base = {
        "event_id": "evt-0123456789ab",
        "source_system": "crm",
        "customer_id": "cust-000012",
        "event_type": "payment_received",
        "event_timestamp": "2026-10-10T11:00:00Z",
        "amount": 29.38,
        "currency": "GBP",
    }
    base.update(cambios)
    return {k: v for k, v in base.items() if v is not ...}


def test_lote_valido_pasa_y_tokeniza_pii():
    reporte = validar_lote([evento()], CONTRATO)
    assert len(reporte.validos) == 1
    assert reporte.validos[0]["customer_id"] != "cust-000012"


def test_falta_campo_requerido_tumba_el_gate():
    lote = [evento(customer_id=...) for _ in range(10)]
    with pytest.raises(CalidadError, match="100.00%"):
        validar_lote(lote, CONTRATO)


def test_campo_inesperado_se_reporta():
    reporte = validar_lote([evento(extra="x")], CONTRATO)
    assert reporte.campos_inesperados == ["extra"]


# ── Tests del renombre customerId → customer_id ──────────────────────────────

def test_rename_customerId_acepta_registro_y_tokeniza_pii():
    """Un registro con customerId (alias del CRM) pasa el contrato y se tokeniza."""
    # El registro llega sin customer_id pero con customerId (como hace el CRM ahora)
    registro = evento(customer_id=..., customerId="cust-000012")
    reporte = validar_lote([registro], CONTRATO)
    assert len(reporte.validos) == 1, "el registro debió ser válido tras el renombre"
    valido = reporte.validos[0]
    # El alias desaparece del output
    assert "customerId" not in valido
    # El campo del contrato está presente y fue tokenizado (no es el valor en claro)
    assert "customer_id" in valido
    assert valido["customer_id"] != "cust-000012"


def test_rename_ambos_nombres_gana_contrato():
    """Si el registro trae customerId y customer_id, gana el valor de customer_id."""
    registro = evento(customer_id="cust-000012", customerId="cust-ALIAS")
    reporte = validar_lote([registro], CONTRATO)
    assert len(reporte.validos) == 1
    valido = reporte.validos[0]
    assert "customerId" not in valido
    # El valor tokenizado corresponde a customer_id, no al alias
    import hashlib, hmac as _hmac
    esperado = _hmac.new(b"demo", b"cust-000012", hashlib.sha256).hexdigest()[:16]
    assert valido["customer_id"] == esperado


def test_rename_lote_completo_supera_el_gate():
    """Un lote completo con customerId pasa el quality gate sin rechazos."""
    lote = [evento(customer_id=..., customerId=f"cust-{i:06d}") for i in range(10)]
    reporte = validar_lote(lote, CONTRATO)
    assert reporte.rechazados == 0
    assert len(reporte.validos) == 10
