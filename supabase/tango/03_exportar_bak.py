#!/usr/bin/env python3
"""
03_exportar_bak.py - Exporta las tablas de tablas.txt desde el .bak de Tango a CSV.

Es la unica via de extraccion (no hay red ni SQL Server): lee el .bak con
bak_reader.py y deja en la carpeta de salida el mismo formato que espera
02_verificar_export.py (separador |~|, terminador @#@\\n, UTF-8, NULL = vacio,
bit 0/1, fechas ISO con milisegundos, decimales con punto).

_filas_origen.csv sale de sysrowsets.rcrows (el conteo que mantiene el motor), que
es independiente del decodificador de filas: si ambos coinciden, la lectura esta completa.

Uso:  python3 03_exportar_bak.py RUTA.bak [carpeta_salida]   (por defecto ./csv)
"""
import datetime
import decimal
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bak_reader import Bak  # noqa: E402

FS, RS = "|~|", "@#@\n"
AQUI = os.path.dirname(os.path.abspath(__file__))


def canon(v):
    if v is None:
        return ""
    if isinstance(v, datetime.datetime):
        return v.strftime("%Y-%m-%d %H:%M:%S.") + "%03d" % (v.microsecond // 1000)
    if isinstance(v, decimal.Decimal):
        return format(v, "f")
    s = str(v)
    if FS in s or "@#@" in s:
        raise ValueError("el valor contiene el separador o el terminador: %r" % s[:80])
    return s


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    bak_path = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(AQUI, "csv")
    os.makedirs(out, exist_ok=True)
    tablas = open(os.path.join(AQUI, "tablas.txt")).read().split()

    bak = Bak(bak_path)
    origen, total = [], 0
    for t in tablas:
        n = 0
        with open(os.path.join(out, t + ".csv"), "w", encoding="utf-8", newline="") as f:
            for row in bak.rows(t):
                f.write(FS.join(canon(v) for v in row) + RS)
                n += 1
        meta = bak.meta_rowcount(t)
        origen.append((t, meta))
        total += n
        print("%-28s %8d filas%s" % (t, n, "" if n == meta else "   <-- rcrows=%d" % meta))

    with open(os.path.join(out, "_filas_origen.csv"), "w", encoding="utf-8", newline="") as f:
        for t, meta in origen:
            f.write("%s%s%d%s" % (t, FS, meta, RS))
        f.write("_FIN_%s0%s" % (FS, RS))
    with open(os.path.join(out, "_manifiesto.txt"), "w", encoding="utf-8") as f:
        f.write("archivo=%s\nsha256=%s\nfecha_backup=%s\nversion_base=%d\npaginas=%d\n"
                "tablas=%d\nfilas=%d\nexportado=%s\n" % (
                    os.path.basename(bak_path), sha256(bak_path), bak.backup_date.isoformat(),
                    bak.db_version, bak.npages, len(tablas), total,
                    datetime.datetime.now().isoformat(timespec="seconds")))
    print("\n%d tablas, %d filas -> %s  (backup del %s)" % (len(tablas), total, out, bak.backup_date))
    return 0


if __name__ == "__main__":
    sys.exit(main())
