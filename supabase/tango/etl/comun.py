"""
etl/comun.py - Lectura y limpieza compartidas por el ETL de Tango (PLAN_MIGRACION_TANGO.md, Tarea 4).

Lee SOLO los CSV de csv/ (nunca el .bak) y escribe SQL en formato COPY para psql.
"""
import csv
import os
import re
from decimal import Decimal

FS, RS = "|~|", "@#@\n"
AQUI = os.path.dirname(os.path.abspath(__file__))
TANGO = os.path.dirname(AQUI)
CSV_DIR = os.path.join(TANGO, "csv")
SQL_DIR = os.path.join(TANGO, "sql")
ANOMALIAS = []
SENTINELA = "1800-01-01"
ANIO_MAX = 2027


def anomalia(msg):
    ANOMALIAS.append(msg)


def escribir_anomalias(sql_dir=SQL_DIR):
    os.makedirs(sql_dir, exist_ok=True)
    with open(os.path.join(sql_dir, "_anomalias.txt"), "w", encoding="utf-8") as f:
        for a in dict.fromkeys(ANOMALIAS):
            f.write(a + "\n")


def fecha(v, contexto=""):
    """'' / 1800-01-01 -> None; despues de 2027 -> None + anomalia; si no, 'YYYY-MM-DD'."""
    if not v or v.startswith(SENTINELA):
        return None
    d = v[:10]
    if int(d[:4]) > ANIO_MAX:
        anomalia("fecha absurda %s descartada (NULL) en %s" % (d, contexto or "?"))
        return None
    return d


def texto(v):
    v = (v or "").strip()
    return v or None


def dec(v):
    return Decimal(v) if v not in (None, "") else Decimal("0")


def n_comp(v):
    """'A000200002321' -> ('A', 2, 2321, '00002-00002321'); ' 000100004288' -> (None, 1, 4288, ...)."""
    if len(v) != 13 or not v[1:].isdigit():
        raise ValueError("N_COMP con formato inesperado: %r" % v)
    letra = v[0].strip() or None
    pv, num = int(v[1:5]), int(v[5:])
    return letra, pv, num, "%05d-%08d" % (pv, num)


def cargar_esquema(path=None):
    path = path or os.path.join(TANGO, "esquema_tango.tsv")
    esq = {}
    with open(path, encoding="utf-8") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            esq.setdefault(r["tabla"], []).append((int(r["ordinal"]), r["columna"]))
    return {t: [c for _, c in sorted(cs)] for t, cs in esq.items()}


_ESQUEMA = None


def leer(tabla, csv_dir=CSV_DIR, esquema=None):
    """csv/<tabla>.csv -> list[dict] con los nombres de columna de esquema_tango.tsv."""
    global _ESQUEMA
    if esquema is None:
        if _ESQUEMA is None:
            _ESQUEMA = cargar_esquema()
        esquema = _ESQUEMA
    cols = esquema[tabla]
    with open(os.path.join(csv_dir, tabla + ".csv"), encoding="utf-8", newline="") as f:
        data = f.read()
    out = []
    for rec in data.split(RS):
        if not rec:
            continue
        vals = rec.split(FS)
        if len(vals) != len(cols):
            raise ValueError("%s: registro con %d columnas, el esquema tiene %d" % (tabla, len(vals), len(cols)))
        out.append(dict(zip(cols, vals)))
    return out


def _copy_val(v):
    if v is None:
        return "\\N"
    if v is True:
        return "t"
    if v is False:
        return "f"
    s = str(v)
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


def escribir_copy(tabla, columnas, filas):
    out = ["COPY %s (%s) FROM stdin;\n" % (tabla, ", ".join(columnas))]
    for fila in filas:
        out.append("\t".join(_copy_val(v) for v in fila) + "\n")
    out.append("\\.\n")
    return "".join(out)


def escribir_sql(nombre, partes, sql_dir=SQL_DIR):
    os.makedirs(sql_dir, exist_ok=True)
    with open(os.path.join(sql_dir, nombre), "w", encoding="utf-8") as f:
        f.write("".join(partes))


def reset_secuencia(tabla):
    """Las tablas se cargan con ids explicitos: hay que subir la secuencia para que la app siga emitiendo."""
    return ("SELECT setval(pg_get_serial_sequence('%s', 'id'), GREATEST((SELECT COALESCE(MAX(id), 0) FROM %s), 1), "
            "(SELECT COUNT(*) > 0 FROM %s));\n" % (tabla, tabla, tabla))


def q2(v):
    from decimal import ROUND_HALF_UP
    return Decimal(v).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def q3(v):
    from decimal import ROUND_HALF_UP
    return Decimal(v).quantize(Decimal("0.001"), rounding=ROUND_HALF_UP)
