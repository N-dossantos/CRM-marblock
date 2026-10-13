"""
etl/contabilidad.py - Tarea 9: asientos contables historicos de Tango.

Se cargan solo las cabeceras que tienen renglones (los asientos no contabilizados de Tango -553 GV, 401 CP
y 311 SB, sin renglones- no son asientos): 17.460 asientos y 51.379 renglones. Los importes de Tango
tienen 4 decimales y asiento_items tiene 2: cada renglon se redondea y, si el asiento queda descuadrado
por un centavo, se corrige el renglon mayor y se deja constancia en _anomalias.txt.
Numeracion correlativa por (fecha, modulo GV / CP / SB, id de cabecera); contadores 'asiento' queda en el
ultimo numero. referencia_tipo / referencia_id apuntan al comprobante ya migrado (mismos ids de Tango).

Uso:  python3 -m etl.contabilidad   (desde supabase/tango/)  ->  sql/50_contabilidad.sql
"""
import collections
from decimal import Decimal as D

from etl import comun
from etl.comun import dec, fecha, q2, texto

REF_VENTA = {"FAC": "facturas", "N/C": "notas", "N/D": "notas", "REC": "recibos"}
REF_COMPRA = {"FAC": "facturas_compra", "N/C": "notas_compra", "N/D": "notas_compra"}
NOMBRE = {"FAC": "Factura", "N/C": "Nota de crédito", "N/D": "Nota de débito", "REC": "Recibo", "O/P": "Orden de pago"}


def ref_venta(t):
    return REF_VENTA[t]


def ref_compra(t):
    return REF_COMPRA[t]


def renglon(r):
    imp = q2(r["IMPORTE"])
    if r["D_H"] == "D":
        return imp, D("0.00")
    if r["D_H"] == "H":
        return D("0.00"), imp
    raise ValueError("D_H inesperado: %r" % r["D_H"])


def balancear(lineas, ctx):
    """lineas: [[cuenta, debe, haber, ...]] (listas mutables). Corrige un descuadre de redondeo en el renglon mayor."""
    dif = sum((l[1] for l in lineas), D("0")) - sum((l[2] for l in lineas), D("0"))
    if dif == 0:
        return
    if abs(dif) > D("0.05"):
        raise ValueError("%s: asiento descuadrado por %s" % (ctx, dif))
    # dif > 0: sobra debe -> bajar el debe mayor (o subir el haber mayor)
    lado = 1 if dif > 0 else 2
    mayor = max((l for l in lineas if l[lado] != 0), key=lambda l: l[lado])
    mayor[lado] -= dif if lado == 1 else -dif
    comun.anomalia("%s: descuadre de redondeo de %s corregido en el renglon mayor" % (ctx, dif))


def generar():
    gva12, cpa04, sba04 = comun.leer("GVA12"), comun.leer("CPA04"), comun.leer("SBA04")
    cuentas = {r["ID_CUENTA"] for r in comun.leer("CUENTA")}
    gv_comp = {r["NCOMP_IN_V"]: r for r in gva12}
    cp_comp = {r["NCOMP_IN_C"]: r for r in cpa04 if r["TCOMP_IN_C"] in ("FP", "CP", "DP")}
    sb_comp = {r["N_INTERNO"]: r for r in sba04}
    ids_rec = {r["N_COMP"]: int(r["ID_GVA12"]) for r in gva12 if r["T_COMP"] == "REC"}
    ids_op = {r["N_COMP"]: int(r["ID_CPA04"]) for r in cpa04 if r["T_COMP"] == "O/P"}
    cabs = []    # (fecha, orden_modulo, id_cab, origen, descripcion, ref_tipo, ref_id, items)
    for mod, col_cab, orig in (("GV", "ID_ASIENTO_COMPROBANTE_GV", "venta"), ("CP", "ID_ASIENTO_COMPROBANTE_CP", "compra"),
                               ("SB", "ID_ASIENTO_COMPROBANTE_SB", "tesoreria")):
        its = collections.defaultdict(list)
        for r in sorted(comun.leer("ASIENTO_" + mod), key=lambda r: (int(r[col_cab]), int(r["NRO_RENGLON_ASIENTO_" + mod]))):
            if r["ID_CUENTA"] not in cuentas:
                raise ValueError("ASIENTO_%s %s: cuenta %s inexistente" % (mod, r["ID_ASIENTO_" + mod], r["ID_CUENTA"]))
            its[r[col_cab]].append(r)
        for h in sorted(comun.leer("ASIENTO_COMPROBANTE_" + mod), key=lambda h: int(h[col_cab])):
            filas = its.get(h[col_cab])
            if not filas:
                continue
            if mod == "GV":
                c = gv_comp[h["NCOMP_IN_V"]]
                f, desc = fecha(c["FECHA_EMIS"], "asiento GV"), "%s %s (Tango)" % (NOMBRE[c["T_COMP"]], comun.n_comp(c["N_COMP"])[3])
                rt, rid = ref_venta(c["T_COMP"]), int(c["ID_GVA12"])
            elif mod == "CP":
                c = cp_comp.get(h["NCOMP_IN_C"])
                if c is None:
                    f = fecha(h["FECHA_CONTABILIZACION"], "asiento CP %s" % h[col_cab])
                    desc, rt, rid = "Asiento de compras sin comprobante (Tango, interno %s)" % h["NCOMP_IN_C"], None, None
                    comun.anomalia("ASIENTO_COMPROBANTE_CP %s: sin comprobante en CPA04; se carga sin referencia" % h[col_cab])
                else:
                    f = fecha(c["FECHA_CONT"], "asiento CP") or fecha(c["FECHA_EMIS"], "asiento CP")
                    desc = "%s %s (Tango)" % (NOMBRE[c["T_COMP"]], c["N_COMP"].strip())
                    rt, rid = ref_compra(c["T_COMP"]), int(c["ID_CPA04"])
            else:
                c = sb_comp[h["N_INTERNO"]]
                f = fecha(c["FECHA"], "asiento SB")
                concepto = texto(c["CONCEPTO"]) or c["COD_COMP"]
                desc = "%s %s (Tango)" % (concepto, c["N_COMP"].strip())
                if c["COD_COMP"] == "REC":
                    rt, rid = "recibos", ids_rec.get(c["N_COMP"])
                elif c["COD_COMP"] == "O/P":
                    rt, rid = "pagos_proveedor", ids_op.get(c["N_COMP"])
                else:
                    rt, rid = None, None
                if rid is None:
                    rt = None
            lineas = []
            for r in filas:
                imp = dec(r["IMPORTE_RENGLON_BASE_" + mod])
                d, hh = renglon({"D_H": r["D_H"], "IMPORTE": imp})
                lineas.append([int(r["ID_CUENTA"]), d, hh, (texto(r.get("DESC_LEYENDA", "")) or "")[:300] or None,
                               int(r["NRO_RENGLON_ASIENTO_" + mod]), int(r["ID_ASIENTO_" + mod])])
            balancear(lineas, "asiento %s %s" % (mod, h[col_cab]))
            cabs.append((f, {"GV": 0, "CP": 1, "SB": 2}[mod], int(h[col_cab]), orig, desc[:300], rt, rid, lineas))
    cabs.sort(key=lambda c: (c[0], c[1], c[2]))
    cab_rows, item_rows = [], []
    for n, (f, _, _, orig, desc, rt, rid, lineas) in enumerate(cabs, 1):
        cab_rows.append((n, n, f, desc, orig, rt, rid, "confirmado"))
        for cuenta, d, hh, det, orden, _ in lineas:
            item_rows.append((len(item_rows) + 1, n, cuenta, d, hh, det, orden))
    C = comun.escribir_copy
    partes = ["-- Contabilidad historica de Tango (etl/contabilidad.py)\n",
        C("asientos_contables", ["id", "numero", "fecha", "descripcion", "origen", "referencia_tipo", "referencia_id", "estado"], cab_rows),
        C("asiento_items", ["id", "asiento_id", "cuenta_id", "debe", "haber", "detalle", "orden"], item_rows),
        "UPDATE contadores SET ultimo_numero = %d WHERE tipo = 'asiento';\n" % len(cab_rows),
        comun.reset_secuencia("asientos_contables"), comun.reset_secuencia("asiento_items")]
    comun.escribir_sql("50_contabilidad.sql", partes)
    return {"asientos_contables": len(cab_rows), "asiento_items": len(item_rows)}


if __name__ == "__main__":
    print(generar())
    comun.escribir_anomalias()
