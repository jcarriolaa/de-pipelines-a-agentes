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
