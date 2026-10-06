"""
etl/tesoreria.py - Tarea 8: Tesoreria (movimientos_tesoreria y cheques_propios).

Un movimiento por pata de SBA05 sobre una cuenta de dinero (D = +1, H = -1). Las cuentas de contrapartida
de Tango (2 'Deudores por ventas' y 5 'Proveedores varios', maestros.CTA_CONTRAPARTIDA) no se cargan: son el
otro lado del asiento de recibos y pagos y ya estan en recibos / pagos_proveedor. El saldo de cada cuenta
cargada = SALDO_ACT de SBA01 (control en controles_tesoreria.py), por eso saldo_inicial queda en 0.

El catalogo tipos_comprobante_tesoreria sembrado (10 codigos) se conserva y se mapea por COD_COMP de Tango.
Ids fijos del seed (migracion 20260731120000): 1 DEP, 2 EXT, 6 COBRANZA, 7 PAGO_PROV, 10 AJUSTE.

Uso:  python3 -m etl.tesoreria   (desde supabase/tango/)  ->  sql/40_tesoreria.sql
"""
from decimal import Decimal as D

from etl import comun, maestros
from etl.comun import dec, fecha, n_comp, q2, texto

TIPOS = {"REC": (6, "recibo"), "O/P": (7, "pago_proveedor"), "DEP": (1, "manual"), "EGR": (2, "manual"),
         "REV": (10, "manual")}


def tipo_origen(cod):
    if cod not in TIPOS:
        raise ValueError("COD_COMP de tesoreria desconocido: %r" % cod)
    return TIPOS[cod]


def movimientos(sba05, cabeceras, cuentas, ids_comprobante, _unused):
    """cabeceras: {(COD_COMP, N_COMP): fila SBA04}; ids_comprobante: {N_COMP: id del recibo / de la O/P}."""
    out = []
    for r in sorted(sba05, key=lambda r: int(r["ID_SBA05"])):
        if r["COD_CTA"] in maestros.CTA_CONTRAPARTIDA:
            continue
        ctx = "SBA05 %s" % r["ID_SBA05"]
        tipo, origen = tipo_origen(r["COD_COMP"])
        cab = cabeceras[(r["COD_COMP"], r["N_COMP"])]
        _, _, _, numero = n_comp(r["N_COMP"])
        ref = ids_comprobante.get(r["N_COMP"]) if origen != "manual" else None
        out.append((int(r["ID_SBA05"]), numero, fecha(r["FECHA"], ctx), int(cuentas[r["COD_CTA"]]["ID_SBA01"]), tipo,
                    1 if r["D_H"] == "D" else -1, q2(dec(r["MONTO"])), origen,
                    origen if ref else None, ref, (texto(cab["CONCEPTO"]) or "")[:300] or None,
                    r["CONCILIADO"] == "1"))
    return out


def cheque_propio(r, cuentas, ids_prov, ids_op):
    ctx = "SBA15 %s" % r["ID_SBA15"]
    num = r["N_CHEQUE"].strip()
    return (int(r["ID_SBA15"]), num.split(".")[0] if "." in num else num, int(cuentas[r["CTA_BANCO"]]["ID_SBA01"]),
            "fisico", (texto(r["ORDEN"]) or "")[:200] or None, ids_prov.get(r["COD_CPA01"].strip()),
            fecha(r["FECHA_EMI"], ctx), fecha(r["FECHA_CHEQ"], ctx), q2(dec(r["IMPORTE_CH"])),
            "entregado", ids_op.get(r["N_COMP_EMI"]))


def generar():
    sba05 = comun.leer("SBA05")
    cab = {(r["COD_COMP"], r["N_COMP"]): r for r in comun.leer("SBA04")}
    cuentas = {r["COD_CTA"]: r for r in comun.leer("SBA01")}
    gva12, cpa04 = comun.leer("GVA12"), comun.leer("CPA04")
    ids = {r["N_COMP"]: int(r["ID_GVA12"]) for r in gva12 if r["T_COMP"] == "REC" and r["ESTADO"] != "ANU"}
    ids_op = {r["N_COMP"]: int(r["ID_CPA04"]) for r in cpa04 if r["T_COMP"] == "O/P" and r["ESTADO"] != "ANU"}
    ids.update(ids_op)       # los N_COMP de REC (' 0001...') y de O/P (' 0000...') no se pisan
    ids_prov = {r["COD_PROVEE"]: int(r["ID_CPA01"]) for r in comun.leer("CPA01")}
    mov = movimientos(sba05, cab, cuentas, ids, None)
    chp = [cheque_propio(r, cuentas, ids_prov, ids_op) for r in sorted(comun.leer("SBA15"), key=lambda r: int(r["ID_SBA15"]))]
    C = comun.escribir_copy
    partes = ["-- Tesoreria de Tango (etl/tesoreria.py)\n",
        C("movimientos_tesoreria", ["id", "numero", "fecha", "cuenta_bancaria_id", "tipo_comprobante_tesoreria_id", "signo",
                                    "monto", "origen", "referencia_tipo", "referencia_id", "concepto", "conciliado"], mov),
        C("cheques_propios", ["id", "numero", "cuenta_bancaria_id", "tipo", "beneficiario", "proveedor_id", "fecha_emision",
                              "fecha_pago", "monto", "estado", "pago_proveedor_id"], chp),
        comun.reset_secuencia("movimientos_tesoreria"), comun.reset_secuencia("cheques_propios")]
    comun.escribir_sql("40_tesoreria.sql", partes)
    return {"movimientos_tesoreria": len(mov), "cheques_propios": len(chp)}


if __name__ == "__main__":
    print(generar())
    comun.escribir_anomalias()
