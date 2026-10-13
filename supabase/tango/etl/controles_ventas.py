"""Controles de aceptacion de Ventas (Tarea 6). Uso: python3 -m etl.controles_ventas"""
import collections
from decimal import Decimal as D

from etl import comun, ventas
from etl.comun import dec, q2


def main():
    gva12 = comun.leer("GVA12")
    cli = {r["COD_CLIENT"]: r for r in comun.leer("GVA14")}
    # 1) saldo de cuenta corriente por cliente: FAC + ND - NC - REC contra GVA14.SALDO_CC
    saldo = collections.defaultdict(D)
    for r in gva12:
        sg = {"FAC": 1, "N/D": 1, "N/C": -1, "REC": -1}.get(r["T_COMP"])
        if sg and r["ESTADO"] != "ANU":
            saldo[r["COD_CLIENT"]] += sg * dec(r["IMPORTE"])
    malos = [(c, q2(saldo.get(c, D(0))), q2(dec(r["SALDO_CC"]))) for c, r in cli.items()
             if abs(saldo.get(c, D(0)) - dec(r["SALDO_CC"])) > D("0.05")]
    print("clientes con saldo CC distinto de GVA14.SALDO_CC: %d de %d" % (len(malos), len(cli)))
    for m in malos[:10]:
        print("  ", m, cli[m[0]]["RAZON_SOCI"].strip())
    # 2) suma de medios = total del recibo
    recs = {r["N_COMP"]: r for r in gva12 if r["T_COMP"] == "REC"}
    med = collections.defaultdict(D)
    ids = {n: int(r["ID_GVA12"]) for n, r in recs.items() if r["ESTADO"] != "ANU"}
    bancos = {r["ID_BANCO"]: r["DESC_BANCO"].strip() for r in comun.leer("BANCO")}
    cuentas = {r["COD_CTA"]: r for r in comun.leer("SBA01")}
    inv = {v: n for n, v in ids.items()}
    for m in ventas.recibo_medios(comun.leer("SBA05"), comun.leer("SBA14"), ids, cuentas, bancos, {}):
        med[inv[m[1]]] += m[-1]
    dif = [(n, recs[n]["ESTADO"], q2(dec(recs[n]["IMPORTE"])), q2(med.get(n, D(0)))) for n in recs
           if abs(dec(recs[n]["IMPORTE"]) - med.get(n, D(0))) > D("0.01")]
    print("recibos con suma de medios != total: %d" % len(dif), collections.Counter(d[1] for d in dif))
    for d in dif[:8]:
        print("  ", d)
    # 3) estado de facturas cobradas vs imputado (con importe)
    cob = collections.defaultdict(D)
    for r in comun.leer("GVA07"):
        if r["T_COMP"] == "FAC":
            cob[r["N_COMP"]] += dec(r["IMPORT_CAN"])
    mal = 0
    for r in gva12:
        if r["T_COMP"] == "FAC" and r["ESTADO"] == "CAN" and cob[r["N_COMP"]] < dec(r["IMPORTE"]) - D("0.05"):
            mal += 1
    print("facturas CAN con imputado < total: %d" % mal)


if __name__ == "__main__":
    main()
