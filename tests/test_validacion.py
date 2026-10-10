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


def test_rename_customerid_a_customer_id_valida_y_tokeniza():
    """El CRM envía customerId; el pipeline lo renombra a customer_id antes de
    validar y de tokenizar, por lo que el campo PII no viaja en claro."""
    registro_crm = evento(customer_id=..., customerId="cust-000099")
    reporte = validar_lote([registro_crm], CONTRATO)
    assert len(reporte.validos) == 1
    valido = reporte.validos[0]
    assert "customer_id" in valido, "el campo renombrado debe aparecer como customer_id"
    assert "customerId" not in valido, "el alias no debe sobrevivir al normalizar"
    assert valido["customer_id"] != "cust-000099", "el PII debe quedar tokenizado, no en claro"


def test_rename_gana_nombre_canonico_cuando_llegan_ambos():
    """Si un registro trae customer_id y customerId a la vez, gana customer_id."""
    registro = evento(customerId="cust-ALIAS")  # también tiene customer_id del base
    normalizado = normalizar_registro(registro, CONTRATO)
    assert normalizado["customer_id"] == "cust-000012"
    assert "customerId" not in normalizado
