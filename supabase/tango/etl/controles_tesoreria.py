"""Control de aceptacion de Tesoreria (Tarea 8): saldo final de cada cuenta cargada = SALDO_ACT de SBA01."""
import collections
from decimal import Decimal as D

from etl import comun, maestros, tesoreria
from etl.comun import dec, q2


def main():
    cuentas = {r["COD_CTA"]: r for r in comun.leer("SBA01")}
    cab = {(r["COD_COMP"], r["N_COMP"]): r for r in comun.leer("SBA04")}
    mov = tesoreria.movimientos(comun.leer("SBA05"), cab, cuentas, {}, None)
    saldo = collections.defaultdict(D)
    for m in mov:
        saldo[m[3]] += m[5] * m[6]
    malos = 0
    for cod, c in sorted(cuentas.items(), key=lambda kv: int(kv[1]["ID_SBA01"])):
        if cod in maestros.CTA_CONTRAPARTIDA:
            continue
        ok = abs(saldo[int(c["ID_SBA01"])] - dec(c["SALDO_ACT"])) <= D("0.01")
        malos += not ok
        print("%-36s %18s %18s %s" % (c["DESCRIPCIO"].strip(), q2(saldo[int(c["ID_SBA01"])]), q2(dec(c["SALDO_ACT"])), "OK" if ok else "DIFERENCIA"))
    print("cuentas con diferencia: %d" % malos)


if __name__ == "__main__":
    main()
