import pytest

from eventos.validacion import CalidadError, cargar_contrato, normalizar_registro, validar_lote

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


def test_renombre_customerId_a_customer_id():
    """El CRM envía customerId; el pipeline lo normaliza a customer_id antes de validar."""
    # Construir un evento sin customer_id canónico pero con el alias del CRM
    registro_crm = evento(customer_id=...)  # elimina customer_id
    registro_crm["customerId"] = "cust-000012"

    # normalizar_registro debe mover customerId → customer_id
    normalizado = normalizar_registro(registro_crm, CONTRATO)
    assert "customer_id" in normalizado
    assert "customerId" not in normalizado
    assert normalizado["customer_id"] == "cust-000012"


def test_renombre_pii_queda_tokenizado():
    """Después del renombre, customer_id se tokeniza como PII (no viaja en claro)."""
    registro_crm = evento(customer_id=...)
    registro_crm["customerId"] = "cust-000012"

    reporte = validar_lote([registro_crm], CONTRATO)
    assert len(reporte.validos) == 1
    # El valor tokenizado no debe ser el valor original
    assert reporte.validos[0]["customer_id"] != "cust-000012"
    # El alias no debe aparecer en el registro publicado
    assert "customerId" not in reporte.validos[0]


def test_ambos_nombres_gana_el_canonico():
    """Si el registro trae customer_id y customerId, prevalece customer_id."""
    registro_ambos = evento()  # tiene customer_id = "cust-000012"
    registro_ambos["customerId"] = "cust-ALIAS"

    normalizado = normalizar_registro(registro_ambos, CONTRATO)
    assert normalizado["customer_id"] == "cust-000012"
    assert "customerId" not in normalizado
