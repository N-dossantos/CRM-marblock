"""Controles de aceptacion de Compras (Tarea 7). Uso: python3 -m etl.controles_compras"""
import collections
from decimal import Decimal as D

from etl import comun, compras
from etl.comun import dec, q2


def main():
    cpa04 = comun.leer("CPA04")
    prov = {r["COD_PROVEE"]: r for r in comun.leer("CPA01")}
    # saldo de cuenta corriente (lo que se le debe al proveedor): FAC + ND - NC - O/P  contra -CPA01.SALDO_CC
    # (Tango guarda la deuda con proveedores como saldo negativo)
    saldo = collections.defaultdict(D)
    for r in cpa04:
        sg = {"FAC": 1, "N/D": 1, "N/C": -1, "O/P": -1}.get(r["T_COMP"])
        if sg and r["ESTADO"] != "ANU":
            saldo[r["COD_PROVEE"]] += sg * dec(r["IMPORTE_TO"])
    malos = [(c, q2(saldo.get(c, D(0))), -q2(dec(r["SALDO_CC"]))) for c, r in prov.items()
             if abs(saldo.get(c, D(0)) + dec(r["SALDO_CC"])) > D("0.05")]
    print("proveedores con saldo CC distinto de CPA01.SALDO_CC: %d de %d" % (len(malos), len(prov)))
    for m in malos[:8]:
        print("  ", m, prov[m[0]]["NOM_PROVEE"].strip())
    # suma de medios = total de la orden de pago
    ops = {r["N_COMP"]: r for r in cpa04 if r["T_COMP"] == "O/P" and r["ESTADO"] != "ANU"}
    ids = {n: int(r["ID_CPA04"]) for n, r in ops.items()}
    inv = {v: n for n, v in ids.items()}
    cuentas = {r["COD_CTA"]: r for r in comun.leer("SBA01")}
    med = collections.defaultdict(D)
    for m in compras.pago_medios(comun.leer("SBA05"), comun.leer("SBA14"), comun.leer("SBA15"), ids, cuentas):
        med[inv[m[1]]] += m[-1]
    dif = [(n, ops[n]["ESTADO"], q2(dec(ops[n]["IMPORTE_TO"])), q2(med.get(n, D(0)))) for n in ops
           if abs(dec(ops[n]["IMPORTE_TO"]) - med.get(n, D(0))) > D("0.01")]
    print("ordenes de pago con suma de medios != total: %d" % len(dif), collections.Counter(d[1] for d in dif))
    for d in dif[:8]:
        print("  ", d)


if __name__ == "__main__":
    main()
