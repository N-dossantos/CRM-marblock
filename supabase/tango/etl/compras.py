"""
etl/compras.py - Tarea 7: Compras (facturas, notas, ordenes de pago, medios, items, percepciones).

Ids = ids sustitutos de Tango (ID_CPA04 para comprobantes de proveedor y ordenes de pago).
El IVA sale SOLO de los slots COD_IVA1..5 con codigo 1 / 2 / 5 de CPA14; los codigos 3 / 4 (percepcion de
IVA) y CPA18 (percepciones IIBB / internos / ganancias) van a percepciones_compra (D9, PLAN_MAESTRO 3.9) y
nunca al desglose de IVA. Van en un archivo aparte (31_percepciones_compra.sql) porque dependen de la
migracion 20261006140000: 30_compras.sql ya carga total = IMPORTE_TO de Tango (que incluye las
percepciones) y 31_ reparte ese total en percepciones_monto, de modo que la invariante del destino
total = neto + IVA + percepciones cierra recien con los dos cargados, en ese orden.

Uso:  python3 -m etl.compras   (desde supabase/tango/)  ->  sql/30_compras.sql, sql/31_percepciones_compra.sql
"""
import collections
import re
from decimal import Decimal as D

from etl import comun
from etl.comun import dec, fecha, q2, q3, texto

TOL = D("0.05")
# CPA14 (10 filas del .bak del 25/09): codigo -> (clase, detalle). Si aparece otro codigo el ETL aborta.
CPA14_IVA = {"1": (3, D("21")), "2": (2, D("10.5")), "5": (4, D("27"))}          # -> alicuotas_iva.id
CPA14_PERC = {
    "3": ("iva", None, D("3")), "4": ("iva", None, D("10")),
    "51": ("iibb", "Buenos Aires", D("1.5")), "54": ("iibb", "CABA", D("1.5")),
    "40": ("imp_internos", None, D("0")), "52": ("imp_internos", None, D("0")),
    "53": ("ganancias", None, D("3")),
}


def percepcion_cpa14(cod):
    if cod not in CPA14_PERC:
        raise ValueError("codigo de CPA14 desconocido: %r (hay que sumarlo al diccionario)" % cod)
    return CPA14_PERC[cod]


def n_comp_compra(v):
    """N_COMP de proveedor -> (letra, punto_venta de 5, numero). Tolera los dos formatos raros del .bak:
    13 digitos sin letra (el primer digito es parte del punto de venta) y un numero flotante ('...196.4')."""
    if re.fullmatch(r"[A-Z ]\d{12}", v):
        return (v[0].strip() or "A"), "%05d" % int(v[1:5]), int(v[5:])
    if re.fullmatch(r"\d{13}", v):
        comun.anomalia("N_COMP %r sin letra: se asume letra A, pv %s" % (v, v[:5]))
        return "A", v[:5], int(v[5:])
    m = re.fullmatch(r"([A-Z])(\d{4})(\d+)\.\d+", v)
    if m:
        comun.anomalia("N_COMP %r con decimales: se carga numero %d" % (v, int(m.group(3))))
        return m.group(1), "%05d" % int(m.group(2)), int(m.group(3))
    raise ValueError("N_COMP de compras con formato inesperado: %r" % v)


def estado_factura(estado, pagado):
    if estado in ("CAN", "PAG"):
        return "pagada"
    if estado == "PEN":
        return "parcial" if pagado > 0 else "pendiente"
    raise ValueError("ESTADO de factura de compra inesperado: %r" % estado)


def desglose(r, ctx):
    """-> ([(alicuota_iva_id, iva_monto, neto)], [(tipo, jurisdiccion, alicuota, monto, base)])"""
    ne, ex = q2(dec(r["IMPORTE_NE"])), q2(dec(r["IMPORTE_EX"]))
    iva, perc = [], []
    for i in range(1, 6):
        cod, monto = r["COD_IVA%d" % i].strip(), q2(dec(r["IMP_IVA%d" % i]))
        if cod in ("", "0"):
            continue
        if cod in CPA14_IVA:
            alic, rate = CPA14_IVA[cod]
            iva.append([alic, monto, q2(monto * 100 / rate)])
        else:
            tipo, jur, ali = percepcion_cpa14(cod)
            perc.append((tipo, jur, ali, monto, ne))
    gravado = [x for x in iva]
    if gravado:
        resid = ne - sum((x[2] for x in gravado), D("0"))
        if resid != 0:
            if abs(resid) > max(TOL, ne * D("0.01")):
                comun.anomalia("%s: neto %s no coincide con IVA/alicuota (dif %s); se ajusta la alicuota mayor" % (ctx, ne, resid))
            max(gravado, key=lambda x: x[2])[2] += resid
    elif ne != 0:
        iva_sin = [[1, D("0"), ne + ex]]
        return [tuple(x) for x in iva_sin], perc
    out = [tuple(x) for x in gravado]
    if ex != 0:
        out.append((1, D("0"), ex))
    return out, perc


def _cab(r, ctx):
    letra, pv, num = n_comp_compra(r["N_COMP"])
    neto = q2(dec(r["IMPORTE_NE"]) + dec(r["IMPORTE_EX"]))
    bo = q2(dec(r["IMPORTE_BO"]))
    return letra, pv, num, neto, bo


def _percepciones_cpa18(cpa18):
    by = collections.defaultdict(list)
    for r in cpa18:
        by[(r["TCOMP_IN_C"], r["NCOMP_IN_C"])].append(r)
    return by


def comprobantes(cpa04, cpa05, cpa18, proveedores, ids_pagos):
    """-> facturas, iva_detalle, notas, percepciones (con 'F' / 'N' + id del comprobante)"""
    pagado = collections.defaultdict(D)
    nota_fac = collections.defaultdict(list)
    for r in cpa05:
        k = (r["COD_PROVEE"], r["N_COMP_FAC"])
        if r["T_COMP_CAN"] == "O/P":
            pagado[k] += dec(r["IMPORT_CAN"])
        else:
            pagado[k] += dec(r["IMPORT_CAN"]) if r["T_COMP_CAN"] == "N/C" else D("0")
            nota_fac[(r["COD_PROVEE"], r["T_COMP_CAN"], r["N_COMP_CAN"])].append((k, dec(r["IMPORT_CAN"])))
    p18 = _percepciones_cpa18(cpa18)
    ids_fac = {(r["COD_PROVEE"], r["N_COMP"]): int(r["ID_CPA04"]) for r in cpa04 if r["T_COMP"] == "FAC"}
    fac, det, nts, per = [], [], [], []
    vistos = set()
    for r in sorted(cpa04, key=lambda r: int(r["ID_CPA04"])):
        if r["T_COMP"] not in ("FAC", "N/C", "N/D"):
            continue
        cid = int(r["ID_CPA04"])
        ctx = "%s %s prov %s" % (r["T_COMP"], r["N_COMP"], r["COD_PROVEE"])
        letra, pv, num, neto, bo = _cab(r, ctx)
        iva, perc = desglose(r, ctx)
        for x in p18.get((r["TCOMP_IN_C"], r["NCOMP_IN_C"]), []):
            tipo, jur, ali = percepcion_cpa14(x["COD_IMPUES"].strip())
            perc.append((tipo, jur, ali, q2(dec(x["IMPORTE"])), q2(dec(r["IMPORTE_NE"]))))
        iva_monto = sum((m for _, m, _ in iva), D("0"))
        perc_monto = sum((p[3] for p in perc), D("0"))
        total = q2(dec(r["IMPORTE_TO"]))
        if abs(total - (neto + iva_monto + perc_monto)) > TOL:
            comun.anomalia("%s: IMPORTE_TO %s != neto %s + IVA %s + percepciones %s (dif %s)"
                           % (ctx, total, neto, iva_monto, perc_monto, total - neto - iva_monto - perc_monto))
        clave = (r["T_COMP"] if r["T_COMP"] != "FAC" else "FAC", r["COD_PROVEE"], letra, pv, num)
        if clave in vistos:
            raise ValueError("%s: numero repetido para el proveedor (viola la UNIQUE del CRM)" % ctx)
        vistos.add(clave)
        prov = proveedores[r["COD_PROVEE"]]
        numero = "%s-%08d" % (pv, num)
        f_emis = fecha(r["FECHA_EMIS"], ctx)
        if r["T_COMP"] == "FAC":
            k = (r["COD_PROVEE"], r["N_COMP"])
            estado = estado_factura(r["ESTADO"], q2(pagado.get(k, D("0"))))
            afip = r["COMP_AFIP"].strip()
            fac.append((cid, prov, letra, pv, num, numero, f_emis, fecha(r["FECHA_CONT"], ctx),
                        texto(r["CAICAE"]), ("%03d" % int(afip)) if afip.isdigit() and int(afip) else None,
                        neto + bo, q2(dec(r["PORC_BONIF"])), bo, neto, iva_monto, total, estado))
            for alic, m, n in iva:
                det.append((cid, alic, n, m))
            per.extend(("F", cid) + p for p in perc)
        else:
            imp = nota_fac.get((r["COD_PROVEE"], r["T_COMP"], r["N_COMP"]), [])
            fkey = None
            for k, i in imp:
                if fkey is None or i > fkey[1]:
                    fkey = (k, i)
            if len({k for k, _ in imp}) > 1:
                comun.anomalia("%s imputada a %d facturas; se vincula a la de mayor importe (D2)" % (ctx, len({k for k, _ in imp})))
            fid = ids_fac[fkey[0]] if fkey else None
            if fid is None:
                comun.anomalia("%s sin factura imputada (ESTADO %s): factura_compra_id NULL" % (ctx, r["ESTADO"]))
            nts.append((cid, prov, "NC" if r["T_COMP"] == "N/C" else "ND", letra, pv, num, numero, f_emis, fid,
                        neto + bo, bo, neto, iva_monto, total))
            per.extend(("N", cid) + p for p in perc)
    return fac, det, nts, per


def pagos_proveedor(cpa04, proveedores):
    out = []
    for r in sorted(cpa04, key=lambda r: int(r["ID_CPA04"])):
        if r["T_COMP"] != "O/P":
            continue
        if r["ESTADO"] == "ANU":      # sin proveedor (COD_PROVEE '000000') e importe 0: pagos_proveedor.proveedor_id es NOT NULL
            comun.anomalia("O/P %s anulada en Tango (sin proveedor, importe 0): no se carga" % r["N_COMP"])
            continue
        _, pv, num, numero = comun.n_comp(r["N_COMP"])
        out.append((int(r["ID_CPA04"]), numero, "%05d" % pv, num, fecha(r["FECHA_EMIS"], "O/P " + r["N_COMP"]),
                    proveedores[r["COD_PROVEE"]], q2(dec(r["IMPORTE_TO"]))))
    return out


def pago_facturas(cpa05, ids_op, ids_fac):
    """Un vinculo por (orden de pago, factura) con la suma de IMPORT_CAN (D1); las NC / ND que cancelan una
    factura no son pagos y alimentan notas_compra.factura_compra_id."""
    acum = collections.OrderedDict()
    for r in sorted(cpa05, key=lambda r: int(r["ID_CPA05"])):
        if r["T_COMP_CAN"] != "O/P":
            continue
        k = (ids_op[r["N_COMP_CAN"]], ids_fac[(r["COD_PROVEE"], r["N_COMP_FAC"])])
        acum[k] = acum.get(k, D("0")) + dec(r["IMPORT_CAN"])
    return [(i + 1, op, f, q2(imp)) for i, ((op, f), imp) in enumerate(acum.items())]


def pago_medios(sba05, sba14, sba15, ids_op, cuentas):
    """Patas H de SBA05 de cada O/P: caja -> efectivo; cuenta 4 -> cheque_tercero (SBA14 con salida por la
    O/P); cuenta de banco -> cheque_propio (SBA15 emitido por la O/P en esa cuenta) y el resto transferencia."""
    ch3 = collections.defaultdict(list)
    for r in sba14:
        if r["T_COMP_SAL"] == "O/P":
            ch3[r["N_COMP_SAL"]].append(r)
    ch_propios = collections.defaultdict(list)
    for r in sba15:
        if r["T_COMP_EMI"] == "O/P":
            ch_propios[r["N_COMP_EMI"]].append(r)
    out = []
    for r in sorted(sba05, key=lambda r: int(r["ID_SBA05"])):
        if r["COD_COMP"] != "O/P" or r["D_H"] != "H" or r["N_COMP"] not in ids_op:
            continue
        op, cta, monto = ids_op[r["N_COMP"]], cuentas[r["COD_CTA"]], q2(dec(r["MONTO"]))
        ctx = "O/P %s cta %s" % (r["N_COMP"], r["COD_CTA"])
        if cta["TIPO"] == "C":
            usados = D("0")
            for c in sorted(ch3.get(r["N_COMP"], []), key=lambda c: int(c["ID_SBA14"])):
                out.append((op, "cheque_tercero", None, None, int(c["ID_SBA14"]), None, q2(dec(c["IMPORTE_CH"]))))
                usados += q2(dec(c["IMPORTE_CH"]))
            if usados != monto:
                comun.anomalia("%s: cheques de terceros %s != pata de tesoreria %s" % (ctx, usados, monto))
        elif cta["TIPO"] == "B":
            usados = D("0")
            for c in sorted(ch_propios.get(r["N_COMP"], []), key=lambda c: int(c["ID_SBA15"])):
                if c["CTA_EMISIO"] == r["COD_CTA"]:
                    out.append((op, "cheque_propio", None, int(cta["ID_SBA01"]), None, int(c["ID_SBA15"]), q2(dec(c["IMPORTE_CH"]))))
                    usados += q2(dec(c["IMPORTE_CH"]))
            resto = monto - usados
            if resto > D("0.005"):
                out.append((op, "transferencia", texto(cta["DESCRIPCIO"]), int(cta["ID_SBA01"]), None, None, resto))
            elif resto < D("-0.005"):
                comun.anomalia("%s: cheques propios %s superan la pata de tesoreria %s" % (ctx, usados, monto))
        else:
            out.append((op, "efectivo", None, None, None, None, monto))
    return [(i + 1,) + m for i, m in enumerate(out)]


def _renglon_concepto(r, mat):
    """Renglon de CPA47 (concepto de CPA45). CPA47 no trae cantidad: 1 x IMPORTE_NE."""
    m = mat[r["COD_CONCEP"]]
    imp = q2(dec(r["IMPORTE_NE"]))
    return (int(m["ID_CPA45"]), (texto(m["DESC_CONCE"]) or m["COD_CONCEP"])[:300],
            D("1.000"), imp, D("0.00"), CPA14_IVA.get(m["COD_IVA"].strip(), (1, None))[0], imp)


def _renglon_articulo(r, descripciones):
    """Renglon de CPA46 (articulo de stock). No hay material_id: el COD_ARTICU de Tango no es un
    concepto de CPA45, asi que queda NULL con la descripcion de STA11 (mismo criterio que Ventas)."""
    cod = r["COD_ARTICU"].strip()
    cant = dec(r["CANTIDAD"])
    neto = dec(r["PRECIO_NET"])
    precio = dec(r["PRECIO_PAN"]) if dec(r["PORCE_DCTO"]) != 0 else neto
    return (None, (descripciones.get(cod) or cod)[:300], q3(cant), q2(precio),
            q2(dec(r["PORCE_DCTO"])), 3, q2(cant * neto))


def items(cpa47, cpa45, cpa04, cpa46, descripciones):
    """-> (facturas_compra_items, nota_compra_items).

    El link de los renglones con su comprobante es (TCOMP_IN_C, NCOMP_IN_C), que es unico en CPA04:
    NCOMP_IN_C es el id interno de Tango, NO el N_COMP (hay 58 N_COMP repetidos entre proveedores).
    FP -> factura, CP -> nota de credito, DP -> nota de debito.
    Los ids se renumeran de 1 en adelante porque las dos tablas de origen (CPA47 y CPA46) tienen
    rangos de id solapados.
    """
    mat = {r["COD_CONCEP"]: r for r in cpa45}
    comp = {(r["TCOMP_IN_C"], r["NCOMP_IN_C"]): int(r["ID_CPA04"]) for r in cpa04}
    fac, nts = [], []
    renglones = ([("CPA47", r, int(r["ID_CPA47"]), _renglon_concepto(r, mat)) for r in cpa47]
                 + [("CPA46", r, int(r["ID_CPA46"]), _renglon_articulo(r, descripciones)) for r in cpa46])
    for origen, r, rid, campos in sorted(renglones, key=lambda x: (x[0], x[2])):
        if r["TCOMP_IN_C"] not in ("FP", "CP", "DP"):
            raise ValueError("%s %s: TCOMP_IN_C desconocido %r" % (origen, rid, r["TCOMP_IN_C"]))
        cid = comp.get((r["TCOMP_IN_C"], r["NCOMP_IN_C"]))
        if cid is None:
            comun.anomalia("%s %s: sin comprobante en CPA04 (%s %s); el renglon no se carga"
                           % (origen, rid, r["TCOMP_IN_C"], r["NCOMP_IN_C"]))
            continue
        mat_id, desc, cant, precio, dto, alic, sub = campos
        orden = int(r["N_RENGL_C"])
        if r["TCOMP_IN_C"] == "FP":
            fac.append((cid, mat_id, desc, cant, precio, dto, alic, sub, orden))
        else:
            # nota_compra_items no tiene alicuota_iva_id: el IVA de la nota vive en la cabecera.
            nts.append((cid, mat_id, desc, cant, precio, dto, sub, orden))
    return ([(i + 1,) + f for i, f in enumerate(fac)],
            [(i + 1,) + n for i, n in enumerate(nts)])


def generar():
    cpa04, cpa05 = comun.leer("CPA04"), comun.leer("CPA05")
    prov = {r["COD_PROVEE"]: int(r["ID_CPA01"]) for r in comun.leer("CPA01")}
    ids_op = {r["N_COMP"]: int(r["ID_CPA04"]) for r in cpa04 if r["T_COMP"] == "O/P" and r["ESTADO"] != "ANU"}
    ids_fac = {(r["COD_PROVEE"], r["N_COMP"]): int(r["ID_CPA04"]) for r in cpa04 if r["T_COMP"] == "FAC"}
    cuentas = {r["COD_CTA"]: r for r in comun.leer("SBA01")}
    fac, det, nts, per = comprobantes(cpa04, cpa05, comun.leer("CPA18"), prov, None)
    pagos = pagos_proveedor(cpa04, prov)
    pfac = pago_facturas(cpa05, {r["N_COMP"]: int(r["ID_CPA04"]) for r in cpa04 if r["T_COMP"] == "O/P"}, ids_fac)
    pmed = pago_medios(comun.leer("SBA05"), comun.leer("SBA14"), comun.leer("SBA15"), ids_op, cuentas)
    desc_art = {r["COD_ARTICU"].strip(): r["DESCRIPCIO"].strip() for r in comun.leer("STA11")}
    its, nts_its = items(comun.leer("CPA47"), comun.leer("CPA45"), cpa04, comun.leer("CPA46"), desc_art)
    C = comun.escribir_copy
    partes = ["-- Compras de Tango (etl/compras.py)\n",
        C("facturas_compra", ["id", "proveedor_id", "tipo", "punto_venta", "numero_comp", "numero", "fecha",
                              "fecha_recepcion", "cae", "afip_tipo_comprobante", "subtotal", "descuento_general",
                              "descuento_monto", "neto_gravado", "iva_monto", "total", "estado"], fac),
        C("factura_compra_iva_detalle", ["factura_compra_id", "alicuota_iva_id", "neto_gravado", "iva_monto"], det),
        C("facturas_compra_items", ["id", "factura_compra_id", "material_id", "descripcion", "cantidad",
                                    "precio_unitario", "descuento_item", "alicuota_iva_id", "subtotal", "orden"], its),
        C("notas_compra", ["id", "proveedor_id", "tipo", "tipo_letra", "punto_venta", "numero_comp", "numero", "fecha",
                           "factura_compra_id", "subtotal", "descuento_monto", "neto_gravado", "iva_monto", "total"], nts),
        C("nota_compra_items", ["id", "nota_compra_id", "material_id", "descripcion", "cantidad", "precio_unitario",
                                "descuento_item", "subtotal", "orden"], nts_its),
        C("pagos_proveedor", ["id", "numero", "punto_venta", "numero_comp", "fecha", "proveedor_id", "total"], pagos),
        C("pago_proveedor_facturas", ["id", "pago_proveedor_id", "factura_compra_id", "importe"], pfac),
        C("pago_proveedor_medios", ["id", "pago_proveedor_id", "tipo", "detalle", "cuenta_bancaria_id", "cheque_id",
                                    "cheque_propio_id", "monto"], pmed),
    ] + [comun.reset_secuencia(t) for t in ("facturas_compra", "factura_compra_iva_detalle", "facturas_compra_items",
                                           "notas_compra", "nota_compra_items", "pagos_proveedor",
                                           "pago_proveedor_facturas", "pago_proveedor_medios")]
    comun.escribir_sql("30_compras.sql", partes)
    pf = [(i + 1, p[1] if p[0] == "F" else None, p[1] if p[0] == "N" else None) + p[2:] for i, p in enumerate(per)]
    partes = ["-- Percepciones de compra (D9, PLAN_MAESTRO 3.9). REQUIERE la migracion de 3.9 (percepciones_compra y\n"
              "-- percepciones_monto en facturas_compra / notas_compra). Cargar despues de 30_compras.sql.\n",
        C("percepciones_compra", ["id", "factura_compra_id", "nota_compra_id", "tipo", "jurisdiccion", "alicuota", "monto",
                                  "base_imponible"], pf),
        "UPDATE facturas_compra f SET percepciones_monto = s.m FROM (SELECT factura_compra_id, SUM(monto) AS m "
        "FROM percepciones_compra WHERE factura_compra_id IS NOT NULL GROUP BY 1) s WHERE f.id = s.factura_compra_id;\n",
        "UPDATE notas_compra n SET percepciones_monto = s.m FROM (SELECT nota_compra_id, SUM(monto) AS m "
        "FROM percepciones_compra WHERE nota_compra_id IS NOT NULL GROUP BY 1) s WHERE n.id = s.nota_compra_id;\n",
        comun.reset_secuencia("percepciones_compra")]
    comun.escribir_sql("31_percepciones_compra.sql", partes)
    return {"facturas_compra": len(fac), "iva_detalle": len(det), "items": len(its), "notas_compra": len(nts),
            "nota_items": len(nts_its), "pagos_proveedor": len(pagos), "pago_facturas": len(pfac),
            "pago_medios": len(pmed), "percepciones": len(per)}


if __name__ == "__main__":
    print(generar())
    comun.escribir_anomalias()
