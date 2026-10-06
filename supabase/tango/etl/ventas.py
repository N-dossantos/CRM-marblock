"""
etl/ventas.py - Tarea 6: Ventas (facturas, notas, recibos, medios, remitos, cheques de terceros).

Ids de destino = ids sustitutos de Tango (ID_GVA12 para facturas / notas / recibos, ID_STA14 remitos,
ID_GVA53 / ID_STA20 renglones, ID_SBA14 cheques). Los comprobantes entran por INSERT directo y conservan
numero, fecha, importes y estado de Tango. Tango no tiene percepciones de venta (H11) ni CAE (H1, D4).

Uso:  python3 -m etl.ventas   (desde supabase/tango/)  ->  sql/20_ventas.sql
"""
import collections
from decimal import Decimal as D

from etl import comun
from etl.comun import dec, fecha, n_comp, q2, q3, texto

ALICUOTAS = {D("0"): 1, D("10.5"): 2, D("21"): 3, D("27"): 4}       # alicuotas_iva.id
TOL = D("0.01")
CONSUMIDOR_FINAL = "000004"       # COD_CLIENT de "Consumidor Final" en GVA14


def alicuota_id(porc, exento):
    if exento != 0 or porc == 0:
        return 1
    if porc not in ALICUOTAS:
        raise ValueError("PORC_IVA sin alicuota en el CRM: %s" % porc)
    return ALICUOTAS[porc]


def estado_factura(estado, cobrado, total, ctx=""):
    if estado in ("CAN", "PAG"):
        return "cobrada"
    if estado == "ANU":
        return "anulada"
    if estado == "PEN":
        return "parcial" if cobrado > 0 else "pendiente"
    # '***': Tango no la dejo clasificada; se resuelve por el saldo y se revisa a mano
    res = "cobrada" if cobrado >= total - TOL else ("parcial" if cobrado > 0 else "pendiente")
    comun.anomalia("%s: ESTADO '***' de Tango, se cargo como %s (cobrado %s de %s); revisar a mano" % (ctx, res, cobrado, total))
    return res


def elegir_factura(imputaciones):
    """[(factura_key, importe)] -> la de mayor importe (empate: la primera). D2 = a."""
    mejor = None
    for k, imp in imputaciones:
        if mejor is None or imp > mejor[1]:
            mejor = (k, imp)
    return mejor[0] if mejor else None


def estado_cheque(r):
    """D6 (inferida de los datos; Nico debe confirmarla abriendo un cheque de cada codigo en Tango):
    A = activo -> TIPO_SAL 'P' (orden de pago a proveedor) = entregado, 'D' (deposito) = depositado;
    C = ingresado y todavia en cartera; X = revertido (ULT_T_COMP = 'REV'): no se carga (None)."""
    if r["ESTADO"] == "X":
        return None
    if fecha(r["FECHA_RECH"]):
        return "rechazado_banco"
    if r["TIPO_SAL"] == "P":
        return "entregado"
    if r["TIPO_SAL"] == "D":
        return "depositado"
    return "en_cartera"


def cuit_titular(v, ctx):
    """CUIT del librador: varchar(13); si Tango trae uno malformado de 14 caracteres se guardan solo los digitos."""
    c = texto(v)
    if c and len(c) > 13:
        comun.anomalia("%s: CUIT del librador %r malformado; se guarda sin guiones" % (ctx, c))
        c = c.replace("-", "")
    return c


def numero_cheque(v):
    v = v.strip()
    return v.split(".")[0] if "." in v else v


def item(r, descripciones):
    """GVA53 -> (id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, alicuota_iva_id).
    precio_unitario = precio de lista (PRECIO_PAN) con el descuento del renglon aparte; el subtotal es el
    importe real = cantidad x PRECIO_NET (ya neto del descuento del renglon)."""
    cod = r["COD_ARTICU"].strip()
    desc = descripciones.get(cod) or cod
    cant = dec(r["CANTIDAD"])
    if abs(cant) >= 10 ** 7:
        raise ValueError("cantidad fuera de rango en GVA53 %s" % r["ID_GVA53"])
    precio = dec(r["PRECIO_PAN"]) if dec(r["PORC_DTO"]) != 0 else dec(r["PRECIO_NET"])
    return (int(r["ID_GVA53"]), comun_recortar(desc, 300), q3(cant), q2(precio), q2(dec(r["PORC_DTO"])),
            q2(cant * dec(r["PRECIO_NET"])), int(r["N_RENGL_V"]),
            alicuota_id(dec(r["PORC_IVA"]), dec(r["IMPORTE_EXENTO"])))


def comun_recortar(v, n):
    return v if len(v) <= n else v[:n]


def _cab(r, items, cobrado, clientes, ctx, con_estado):
    letra, pv, num, numero = n_comp(r["N_COMP"])
    neto = q2(dec(r["IMPORTE_GR"]) + dec(r["IMPORTE_EX"]))
    bo = q2(dec(r["IMPORTE_BO"]))
    iva, total = q2(dec(r["IMPORTE_IV"])), q2(dec(r["IMPORTE"]))
    subtotal = q2(sum((i[5] for i in items), D("0"))) if items else neto + bo
    if abs(subtotal - (neto + bo)) > D("0.05"):
        comun.anomalia("%s: subtotal de renglones %s distinto de neto+bonificacion %s (dif %s)"
                       % (ctx, subtotal, neto + bo, subtotal - (neto + bo)))
    if abs(total - (neto + iva)) > D("0.05"):
        comun.anomalia("%s: IMPORTE %s distinto de neto+IVA %s (dif %s)" % (ctx, total, neto + iva, total - neto - iva))
    return letra, pv, num, numero, neto, bo, iva, total, subtotal


def facturas(gva12, gva53, gva07, clientes, descripciones):
    """-> (filas_facturas, filas_items, ids_estado)"""
    items = collections.defaultdict(list)
    for r in sorted(gva53, key=lambda r: (int(r["N_RENGL_V"]), int(r["ID_GVA53"]))):
        if r["T_COMP"] == "FAC":
            items[r["N_COMP"]].append(r)
    cobrado = collections.defaultdict(D)
    for r in gva07:
        if r["T_COMP"] == "FAC" and r["T_COMP_CAN"] in ("REC", "N/C"):
            cobrado[r["N_COMP"]] += dec(r["IMPORT_CAN"])
    fac, its = [], []
    for r in sorted(gva12, key=lambda r: int(r["ID_GVA12"])):
        if r["T_COMP"] != "FAC":
            continue
        ctx = "FAC %s" % r["N_COMP"]
        its_r = [item(i, descripciones) for i in items.get(r["N_COMP"], [])]
        letra, pv, num, numero, neto, bo, iva, total, subtotal = _cab(r, its_r, 0, clientes, ctx, True)
        if letra not in ("A", "B"):
            raise ValueError("%s: letra %r no soportada por el CRM" % (ctx, letra))
        estado = estado_factura(r["ESTADO"], q2(cobrado.get(r["N_COMP"], D("0"))), total, ctx)
        fac.append((int(r["ID_GVA12"]), numero, "%05d" % pv, num, letra, fecha(r["FECHA_EMIS"], ctx),
                    clientes[r["COD_CLIENT"]], q2(dec(r["PORC_BONIF"])), subtotal, bo, neto, D("21.00"),
                    iva, total, estado, D("0.00")))
        its.extend((int(r["ID_GVA12"]),) + i for i in its_r)
    return fac, its


def notas(gva12, gva53, gva07, clientes, descripciones, facturas_id):
    """-> (filas_notas, filas_items). factura_id por GVA07 (D2 = a); NULL si la nota no esta imputada.
    cliente_id sale siempre de GVA12.COD_CLIENT, no de la factura: las 30 notas sin imputar se
    quedarian sin cliente y la cuenta corriente no cerraria contra GVA14.SALDO_CC (H22)."""
    items = collections.defaultdict(list)
    for r in sorted(gva53, key=lambda r: (int(r["N_RENGL_V"]), int(r["ID_GVA53"]))):
        if r["T_COMP"] in ("N/C", "N/D"):
            items[(r["T_COMP"], r["N_COMP"])].append(r)
    imput = collections.defaultdict(list)
    for r in gva07:
        if r["T_COMP_CAN"] in ("N/C", "N/D") and r["T_COMP"] == "FAC":
            imput[(r["T_COMP_CAN"], r["N_COMP_CAN"])].append((r["N_COMP"], dec(r["IMPORT_CAN"])))
    out, its = [], []
    for r in sorted(gva12, key=lambda r: int(r["ID_GVA12"])):
        if r["T_COMP"] not in ("N/C", "N/D"):
            continue
        ctx = "%s %s" % (r["T_COMP"], r["N_COMP"])
        its_r = [item(i, descripciones) for i in items.get((r["T_COMP"], r["N_COMP"]), [])]
        letra, pv, num, numero, neto, bo, iva, total, subtotal = _cab(r, its_r, 0, clientes, ctx, False)
        imp = imput.get((r["T_COMP"], r["N_COMP"]), [])
        if len({k for k, _ in imp}) > 1:
            comun.anomalia("%s imputada a %d facturas; se vincula a la de mayor importe (D2)" % (ctx, len({k for k, _ in imp})))
        fkey = elegir_factura(imp)
        fid = facturas_id[fkey] if fkey else None
        if fid is None:
            comun.anomalia("%s sin factura imputada (ESTADO %s): factura_id NULL (D2)" % (ctx, r["ESTADO"]))
        out.append((int(r["ID_GVA12"]), numero, "%05d" % pv, num, "NC" if r["T_COMP"] == "N/C" else "ND", letra,
                    fecha(r["FECHA_EMIS"], ctx), fid, clientes[r["COD_CLIENT"]],
                    subtotal, bo, neto, iva, total))
        its.extend((int(r["ID_GVA12"]),) + i for i in its_r)
    return out, its


def recibos(gva12, clientes):
    out = []
    for r in sorted(gva12, key=lambda r: int(r["ID_GVA12"])):
        if r["T_COMP"] != "REC":
            continue
        letra, pv, num, numero = n_comp(r["N_COMP"])
        out.append((int(r["ID_GVA12"]), numero, "%05d" % pv, num, fecha(r["FECHA_EMIS"], "REC " + r["N_COMP"]),
                    clientes[r["COD_CLIENT"]], q2(dec(r["IMPORTE"]))))
    return out


def recibo_facturas(gva07, ids_rec, ids_fac):
    """Un vinculo por (recibo, factura) con la suma de IMPORT_CAN (D1). Los recibos que cancelan una ND
    no tienen destino (recibo_facturas.factura_id referencia facturas) y quedan en anomalias."""
    acum = collections.OrderedDict()
    ndd = 0
    for r in sorted(gva07, key=lambda r: int(r["ID_GVA07"])):
        if r["T_COMP_CAN"] != "REC":
            continue
        if r["T_COMP"] != "FAC":
            ndd += 1
            continue
        k = (ids_rec[r["N_COMP_CAN"]], ids_fac[r["N_COMP"]])
        acum[k] = acum.get(k, D("0")) + dec(r["IMPORT_CAN"])
    if ndd:
        comun.anomalia("GVA07: %d imputaciones de recibos a notas de debito no se cargan (recibo_facturas solo admite facturas)" % ndd)
    return [(i + 1, rid, fid, q2(imp)) for i, ((rid, fid), imp) in enumerate(acum.items())]


def recibo_medios(sba05, sba14, ids_rec, cuentas, bancos, ids_cli):
    """Medios de cada recibo desde las patas D de SBA05: caja -> efectivo, cuenta de banco -> transferencia,
    cuenta 4 (valores a depositar) -> un 'cheque' por cada cheque de SBA14 del recibo; cualquier otra cuenta
    (retenciones sufridas) -> 'transferencia' con el nombre de la cuenta en detalle."""
    cheques = collections.defaultdict(list)
    for r in sba14:
        if r["T_COMP_REC"] == "REC":
            cheques[r["N_COMP_REC"]].append(r)
    out = []
    for r in sorted(sba05, key=lambda r: int(r["ID_SBA05"])):
        if r["COD_COMP"] != "REC" or r["D_H"] != "D" or r["N_COMP"] not in ids_rec:
            continue
        rid, cta = ids_rec[r["N_COMP"]], cuentas[r["COD_CTA"]]
        monto = q2(dec(r["MONTO"]))
        if cta["TIPO"] == "C":
            for c in sorted(cheques.get(r["N_COMP"], []), key=lambda c: int(c["ID_SBA14"])):
                out.append((rid, "cheque", None, numero_cheque(c["N_CHEQUE"]), bancos.get(c["ID_BANCO"].strip()),
                            texto(c["RAZON_EMIS"]), cuit_titular(c["N_CUIT"], "SBA14 %s" % c["ID_SBA14"]), fecha(c["F_EMISION"]),
                            fecha(c["FECHA_CHEQ"], "SBA14 %s FECHA_CHEQ" % c["ID_SBA14"]), q2(dec(c["IMPORTE_CH"]))))
        elif cta["TIPO"] == "O" and cta["COD_CTA"] == "1.0":
            out.append((rid, "efectivo", None, None, None, None, None, None, None, monto))
        else:
            out.append((rid, "transferencia", texto(cta["DESCRIPCIO"]), None, None, None, None, None, None, monto))
    # control: cheques de SBA14 contra la pata D de la cuenta 4 del mismo recibo
    return [(i + 1,) + m for i, m in enumerate(out)]


def cheques(sba14, bancos, ids_cli, ids_prov):
    out, salteados = [], 0
    for r in sorted(sba14, key=lambda r: int(r["ID_SBA14"])):
        est = estado_cheque(r)
        if est is None:
            salteados += 1
            comun.anomalia("SBA14 %s: cheque revertido (ESTADO X, ULT_T_COMP=%s) por $%s no se carga"
                           % (r["ID_SBA14"], r["ULT_T_COMP"], q2(dec(r["IMPORTE_CH"]))))
            continue
        ctx = "SBA14 %s" % r["ID_SBA14"]
        # fecha_emision / fecha_vcto son NOT NULL: con fecha absurda se usa la de recepcion (FECHA_REC)
        emision = fecha(r["F_EMISION"], ctx) or fecha(r["FECHA_REC"], ctx)
        vcto = fecha(r["FECHA_CHEQ"], ctx + " FECHA_CHEQ") or fecha(r["FECHA_REC"], ctx)
        if not emision or not vcto:
            raise ValueError("%s: sin fechas utilizables" % ctx)
        prov = ids_prov.get(r["COD_CPA01"].strip()) if est == "entregado" and r["COD_CPA01"].strip() else None
        out.append((int(r["ID_SBA14"]), numero_cheque(r["N_CHEQUE"]), bancos.get(r["ID_BANCO"].strip()) or "Sin dato",
                    texto(r["RAZON_EMIS"]), cuit_titular(r["N_CUIT"], ctx), emision, vcto, q2(dec(r["IMPORTE_CH"])),
                    ids_cli.get(r["COD_GVA14"].strip()), prov, est))
    return out


def remitos(sta14, sta20, gva54, clientes, ids_fac, descripciones):
    rems = {r["NCOMP_IN_S"]: r for r in sta14 if r["T_COMP"] == "REM"}
    fac_de = collections.defaultdict(collections.Counter)
    for r in gva54:
        if r["TCOMP_IN_S"] == "RE" and r["T_COMP_V"] == "FAC":
            fac_de[r["NCOMP_IN_S"]][r["N_COMP"]] += 1
    out, its = [], []
    for ncomp, r in sorted(rems.items(), key=lambda kv: int(kv[1]["ID_STA14"])):
        letra, pv, num, numero = n_comp(r["N_COMP"])
        cands = fac_de.get(ncomp)
        fid = None
        if cands:
            if len(cands) > 1:
                comun.anomalia("REM %s vinculado a %d facturas; se usa la de mas renglones" % (r["N_COMP"], len(cands)))
            fid = ids_fac[cands.most_common(1)[0][0]]
        estado = {"F": "facturado", "A": "anulado", "P": "pendiente"}[r["ESTADO_MOV"]]
        out.append((int(r["ID_STA14"]), numero, "%05d" % pv, num, fecha(r["FECHA_MOV"], "REM " + r["N_COMP"]),
                    clientes[r["COD_PRO_CL"]], fid, estado))
    ids = {n: int(r["ID_STA14"]) for n, r in rems.items()}
    for r in sorted(sta20, key=lambda r: int(r["ID_STA20"])):
        if r["TCOMP_IN_S"] == "RE" and r["NCOMP_IN_S"] in ids:
            cod = r["COD_ARTICU"].strip()
            its.append((int(r["ID_STA20"]), ids[r["NCOMP_IN_S"]], comun_recortar(descripciones.get(cod) or cod, 300),
                        q3(dec(r["CANTIDAD"])), int(r["N_RENGL_S"])))
    return out, its


def generar():
    gva12, gva53, gva07 = comun.leer("GVA12"), comun.leer("GVA53"), comun.leer("GVA07")
    desc = {r["COD_ARTICU"].strip(): r["DESCRIPCIO"].strip() for r in comun.leer("STA11")}
    clientes = {r["COD_CLIENT"]: int(r["ID_GVA14"]) for r in comun.leer("GVA14")}
    ids_cli = {r["COD_GVA14"] if "COD_GVA14" in r else r["COD_CLIENT"]: int(r["ID_GVA14"]) for r in comun.leer("GVA14")}
    ids_prov = {r["COD_PROVEE"]: int(r["ID_CPA01"]) for r in comun.leer("CPA01")}
    bancos = {r["ID_BANCO"]: r["DESC_BANCO"].strip() for r in comun.leer("BANCO")}
    cuentas = {r["COD_CTA"]: r for r in comun.leer("SBA01")}
    # Los comprobantes anulados de Tango no tienen cliente (COD_CLIENT '000000', importes en 0): se cargan
    # con "Consumidor Final" para conservar el hueco de numeracion (clientes_id es NOT NULL).
    n_anu = sum(1 for r in gva12 if r["COD_CLIENT"] == "000000")
    clientes["000000"] = clientes[CONSUMIDOR_FINAL]
    comun.anomalia("GVA12: %d comprobantes anulados sin cliente se cargan a nombre de Consumidor Final (importes en 0)" % n_anu)
    ids_fac = {r["N_COMP"]: int(r["ID_GVA12"]) for r in gva12 if r["T_COMP"] == "FAC"}
    ids_rec = {r["N_COMP"]: int(r["ID_GVA12"]) for r in gva12 if r["T_COMP"] == "REC"}

    fac, fac_its = facturas(gva12, gva53, gva07, clientes, desc)
    nts, nts_its = notas(gva12, gva53, gva07, clientes, desc, ids_fac)
    recs = recibos(gva12, clientes)
    rfac = recibo_facturas(gva07, ids_rec, ids_fac)
    # recibos anulados: total 0 en GVA12; sus patas de tesoreria quedaron como historia y no son cobranzas
    ids_rec_vigentes = {r["N_COMP"]: int(r["ID_GVA12"]) for r in gva12 if r["T_COMP"] == "REC" and r["ESTADO"] != "ANU"}
    rmed = recibo_medios(comun.leer("SBA05"), comun.leer("SBA14"), ids_rec_vigentes, cuentas, bancos, ids_cli)
    chq = cheques(comun.leer("SBA14"), bancos, ids_cli, ids_prov)
    rem, rem_its = remitos(comun.leer("STA14"), comun.leer("STA20"), comun.leer("GVA54"), clientes, ids_fac, desc)

    C = comun.escribir_copy
    partes = ["-- Ventas de Tango (etl/ventas.py)\n",
        C("facturas", ["id", "numero", "punto_venta", "numero_comp", "tipo", "fecha", "cliente_id", "descuento_general",
                       "subtotal", "descuento_monto", "neto_gravado", "iva_alicuota", "iva_monto", "total", "estado",
                       "percepciones_monto"], fac),
        C("factura_items", ["factura_id", "id", "descripcion", "cantidad", "precio_unitario", "descuento_item",
                            "subtotal", "orden", "alicuota_iva_id"], fac_its),
        C("remitos", ["id", "numero", "punto_venta", "numero_comp", "fecha", "cliente_id", "factura_id", "estado"], rem),
        C("remito_items", ["id", "remito_id", "descripcion", "cantidad", "orden"], rem_its),
        C("notas", ["id", "numero", "punto_venta", "numero_comp", "tipo", "tipo_letra", "fecha", "factura_id",
                    "cliente_id", "subtotal", "descuento_monto", "neto_gravado", "iva_monto", "total"], nts),
        C("nota_items", ["nota_id", "id", "descripcion", "cantidad", "precio_unitario", "descuento_item", "subtotal",
                         "orden", "alicuota_iva_id"], nts_its),
        C("recibos", ["id", "numero", "punto_venta", "numero_comp", "fecha", "cliente_id", "total"], recs),
        C("recibo_facturas", ["id", "recibo_id", "factura_id", "importe"], rfac),
        C("recibo_medios", ["id", "recibo_id", "tipo", "detalle", "numero_cheque", "banco", "titular", "cuit_titular",
                            "fecha_emision", "fecha_vcto", "monto"], rmed),
        C("cheques", ["id", "numero", "banco", "titular", "cuit_titular", "fecha_emision", "fecha_vcto", "monto",
                      "cliente_id", "proveedor_id", "estado"], chq),
    ] + [comun.reset_secuencia(t) for t in ("facturas", "factura_items", "remitos", "remito_items", "notas", "nota_items",
                                           "recibos", "recibo_facturas", "recibo_medios", "cheques")]
    comun.escribir_sql("20_ventas.sql", partes)
    return {"facturas": len(fac), "factura_items": len(fac_its), "notas": len(nts), "nota_items": len(nts_its),
            "recibos": len(recs), "recibo_facturas": len(rfac), "recibo_medios": len(rmed), "cheques": len(chq),
            "remitos": len(rem), "remito_items": len(rem_its)}


if __name__ == "__main__":
    print(generar())
    comun.escribir_anomalias()
