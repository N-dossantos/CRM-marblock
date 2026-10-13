"""
etl/contadores.py - El ultimo numero emitido por cada serie de Tango (D5 de PLAN_MIGRACION_TANGO.md).

Uso:  python3 -m etl.contadores        (desde supabase/tango/)

Imprime el bloque CONTADORES listo para pegar en 05_cargar.sh y, aparte, las series de Tango que
quedan SIN contador. Hay que volver a correrlo con el .bak del dia del cutover: los numeros que hoy
estan en 05_cargar.sh son los del .bak del 2026-09-25 y la serie sigue avanzando hasta que se congela
Tango (Tarea 11, paso 4).

Tres reglas que no son obvias:
  * el ultimo numero es el de la fila mas RECIENTE, no el MAXIMO (H4: el recibo 00041189 del 03/03
    es un error de carga y la serie real va por 4288);
  * cada letra es una serie fiscal propia (H16: la N/C B no hereda el numero de la N/C A);
  * un tipo puede tener varios puntos de venta y `contadores` admite uno solo: gana el de actividad
    mas reciente y el resto se reporta como serie sin contador (H21, la FAC A 0003 "MiPyME").
"""
import collections

from etl import comun

Fila = collections.namedtuple("Fila", "tipo punto_venta ultimo_numero descripcion fecha")

# tipo -> (descripcion, punto de venta por defecto). El default se usa cuando Tango no tiene la
# serie: la fila igual tiene que existir o `crear_*` falla con "Contador no encontrado"
# (PLAN_MAESTRO.md §3.2.8). pago_proveedor va en 00000 porque las O/P no tienen punto de venta
# fiscal y es el que usa toda la historia (H20); el seed lo tenia en 00002.
TIPOS = collections.OrderedDict([
    ("factura_a",      ("Factura A", "00002")),
    ("factura_b",      ("Factura B", "00002")),
    ("nota_credito",   ("Nota de crédito A", "00002")),
    ("nota_credito_b", ("Nota de crédito B", "00002")),
    ("nota_debito",    ("Nota de débito A", "00002")),
    ("nota_debito_b",  ("Nota de débito B", "00002")),
    ("recibo",         ("Recibo", "00001")),
    ("presupuesto",    ("Presupuesto", "00002")),
    ("remito",         ("Remitos de venta — numeración del talonario preimpreso", "00001")),
    ("pago_proveedor", ("Pago a Proveedor", "00000")),
])

# (T_COMP de Tango, letra) -> tipo del CRM. La letra de REM ('R') y la de REC (vacia) no discriminan
# serie, asi que esos dos se resuelven por T_COMP solo.
_POR_LETRA = {"FAC": {"A": "factura_a", "B": "factura_b"},
              "N/C": {"A": "nota_credito", "B": "nota_credito_b"},
              "N/D": {"A": "nota_debito", "B": "nota_debito_b"}}
_POR_COMP = {"REC": "recibo", "REM": "remito", "O/P": "pago_proveedor"}


def _acumular(series, t_comp, n_comp, f, ctx):
    """Se queda con la fila de fecha mas reciente de cada (T_COMP, letra, punto de venta)."""
    letra, pv, num, _ = comun.n_comp(n_comp)
    fec = comun.fecha(f, ctx)
    clave = (t_comp, letra, pv)
    previo = series.get(clave)
    # Sin fecha (centinela 1800-01-01, H8) no puede ganarle a una fila fechada, pero si es la unica
    # de la serie hay que quedarse con ella igual.
    if previo is None or (fec or "") > (previo[1] or ""):
        series[clave] = (num, fec)
    return series


def series_ventas(gva12):
    """GVA12 -> {(T_COMP, letra, punto_venta): (ultimo numero, fecha)} para FAC / N/C / N/D / REC."""
    series = {}
    for r in gva12:
        if r["T_COMP"] not in ("FAC", "N/C", "N/D", "REC"):
            continue
        _acumular(series, r["T_COMP"], r["N_COMP"], r["FECHA_EMIS"], "%s %s" % (r["T_COMP"], r["N_COMP"]))
    return series


def series_remitos(sta14):
    """STA14 -> las series de REM. La letra es 'R' (talonario preimpreso AGEE), no una letra fiscal."""
    series = {}
    for r in sta14:
        if r["T_COMP"] != "REM":
            continue
        _acumular(series, "REM", r["N_COMP"], r["FECHA_MOV"], "REM " + r["N_COMP"])
    return series


def series_pagos(cpa04):
    """CPA04 -> las series de O/P. Las anuladas no se cargan (compras.pagos_proveedor), asi que
    tampoco pueden fijar el contador."""
    series = {}
    for r in cpa04:
        if r["T_COMP"] != "O/P" or r["ESTADO"] == "ANU":
            continue
        _acumular(series, "O/P", r["N_COMP"], r["FECHA_EMIS"], "O/P " + r["N_COMP"])
    return series


def contadores(gva12, sta14, cpa04):
    """-> ([Fila] con los 10 tipos, [(T_COMP, letra, pv, numero, fecha)] de las series sin contador)."""
    series = {}
    for parcial in (series_ventas(gva12), series_remitos(sta14), series_pagos(cpa04)):
        series.update(parcial)

    por_tipo = collections.defaultdict(list)
    huerfanas = []
    for (t_comp, letra, pv), (num, fec) in series.items():
        tipo = _POR_COMP.get(t_comp) or _POR_LETRA.get(t_comp, {}).get(letra)
        if tipo is None:          # letra que el CRM no modela (p. ej. una FAC C)
            huerfanas.append((t_comp, letra, pv, num, fec))
        else:
            por_tipo[tipo].append((t_comp, letra, pv, num, fec))

    filas = []
    for tipo, (desc, pv_default) in TIPOS.items():
        candidatas = sorted(por_tipo.get(tipo, []), key=lambda c: (c[4] or "", c[3]))
        if not candidatas:
            filas.append(Fila(tipo, pv_default, 0, desc, None))
            continue
        _, _, pv, num, fec = candidatas[-1]      # la de actividad mas reciente gana el contador
        huerfanas.extend(candidatas[:-1])        # las demas no tienen donde ir (H21)
        filas.append(Fila(tipo, "%05d" % pv, num, desc, fec))
    return filas, sorted(huerfanas, key=lambda h: (h[0], h[1] or "", h[2]))


def sql(filas):
    """El mismo bloque CONTADORES que ejecuta 05_cargar.sh, dentro de la transaccion de la carga.
    Es INSERT ... ON CONFLICT y no UPDATE porque la mayoria de las filas no existen todavia."""
    cuerpo = ",\n".join(
        "    (%-18s%-8s%6d, '%s')" % ("'%s'," % f.tipo, "'%s'," % f.punto_venta,
                                      f.ultimo_numero, f.descripcion)
        for f in filas)
    return ("INSERT INTO contadores (tipo, punto_venta, ultimo_numero, descripcion) VALUES\n"
            + cuerpo + "\n  ON CONFLICT (tipo) DO UPDATE\n"
            "    SET punto_venta = EXCLUDED.punto_venta, ultimo_numero = EXCLUDED.ultimo_numero;")


def main():
    filas, huerfanas = contadores(comun.leer("GVA12"), comun.leer("STA14"), comun.leer("CPA04"))
    print(sql(filas))
    print()
    for f in filas:
        print("-- %-15s %s-%08d   ultima emision: %s"
              % (f.tipo, f.punto_venta, f.ultimo_numero, f.fecha or "(sin fuente en Tango)"))
    print()
    if huerfanas:
        print("-- Series de Tango SIN contador (H21): `contadores` admite un punto de venta por tipo.")
        for t_comp, letra, pv, num, fec in huerfanas:
            print("--   %s %s %05d  ultimo %d  (%s)" % (t_comp, letra or " ", pv, num, fec or "sin fecha"))
    else:
        print("-- Ninguna serie queda sin contador.")


if __name__ == "__main__":
    main()
