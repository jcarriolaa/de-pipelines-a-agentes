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


# --- Tests del renombrado customerId → customer_id ---

def test_customerId_renombrado_a_customer_id_y_pasa_validacion():
    """Un registro con customerId (camelCase) debe aceptarse igual que customer_id."""
    registro = evento(customer_id=..., customerId="cust-000012")
    reporte = validar_lote([registro], CONTRATO)
    assert reporte.rechazados == 0
    assert len(reporte.validos) == 1


def test_customerId_queda_tokenizado_como_customer_id():
    """Tras el renombre, el campo PII debe salir tokenizado (no en claro)."""
    registro = evento(customer_id=..., customerId="cust-000012")
    reporte = validar_lote([registro], CONTRATO)
    salida = reporte.validos[0]
    assert "customer_id" in salida
    assert salida["customer_id"] != "cust-000012", "El PII no fue tokenizado"
    assert "customerId" not in salida, "El alias no debería aparecer en la salida"


def test_ambos_nombres_gana_el_del_contrato():
    """Si llegan customer_id y customerId a la vez, el del contrato no se sobreescribe."""
    registro = evento(customer_id="cust-000099", customerId="cust-000012")
    reporte = validar_lote([registro], CONTRATO)
    assert reporte.rechazados == 0
    salida = reporte.validos[0]
    # El valor tokenizado corresponde a cust-000099 (el nombre del contrato gana)
    import hashlib, hmac as _hmac
    esperado = _hmac.new(b"demo", b"cust-000099", hashlib.sha256).hexdigest()[:16]
    assert salida["customer_id"] == esperado
    assert "customerId" not in salida
