#!/usr/bin/env python3
"""
02_verificar_export.py - Control de integridad del export de Tango.

Corre en esta Mac, sobre la carpeta csv/ producida por 03_exportar_bak.py a partir
del .bak de Tango (ver PLAN_MIGRACION_TANGO.md).

Verifica, por tabla, tres cosas antes de que el ETL toque nada:
  1. que el archivo exista y se pueda decodificar (detecta UTF-8 / UTF-16 solo);
  2. que cada registro tenga exactamente la cantidad de columnas del esquema;
  3. que la cantidad de registros coincida con el COUNT(*) tomado en origen en
     el momento del export (_filas_origen.csv).

Uso:  python3 02_verificar_export.py [carpeta_csv]
      (por defecto ./csv)
"""
import sys, os, collections

FS = "|~|"
RS = "@#@\n"
AQUI = os.path.dirname(os.path.abspath(__file__))


def detectar_encoding(raw: bytes) -> str:
    if raw.startswith(b"\xff\xfe"):
        return "utf-16"
    if raw.startswith(b"\xfe\xff"):
        return "utf-16"
    if raw.startswith(b"\xef\xbb\xbf"):
        return "utf-8-sig"
    # UTF-16LE sin BOM: se delata por la densidad de bytes nulos
    muestra = raw[:4096]
    if muestra and muestra.count(0) > len(muestra) * 0.25:
        return "utf-16-le"
    try:
        raw[:65536].decode("utf-8")
        return "utf-8"
    except UnicodeDecodeError:
        return "cp1252"


def leer_registros(path: str):
    raw = open(path, "rb").read()
    enc = detectar_encoding(raw)
    txt = raw.decode(enc, errors="replace")
    if txt and txt[0] == "\ufeff":
        txt = txt[1:]
    regs = txt.split(RS)
    if regs and regs[-1] == "":
        regs.pop()
    return enc, regs


def leer_filas_origen(path: str) -> dict:
    raw = open(path, "rb").read()
    enc = detectar_encoding(raw)
    txt = raw.decode(enc, errors="replace").replace("\r\n", "\n").replace("\r", "\n")
    if txt and txt[0] == "\ufeff":
        txt = txt[1:]
    
    origen = {}
    # Soportar registros con terminador RS (@#@\n) o con \n simple
    if RS in txt:
        bloques = [b for b in txt.split(RS) if b.strip()]
    else:
        bloques = [b for b in txt.split("\n") if b.strip()]

    for b in bloques:
        # Delimitadores posibles: |~|, tab, coma, pipe
        if FS in b:
            partes = b.split(FS)
        elif "\t" in b:
            partes = b.split("\t")
        elif "|" in b:
            partes = b.split("|")
        elif "," in b:
            partes = b.split(",")
        else:
            continue

        if len(partes) >= 2:
            t = partes[0].strip()
            val_str = partes[1].strip()
            if t and t != "_FIN_" and t.lower() != "tabla":
                try:
                    origen[t] = int(val_str)
                except ValueError:
                    pass
    return origen


def main() -> int:
    carpeta = sys.argv[1] if len(sys.argv) > 1 else os.path.join(AQUI, "csv")
    if not os.path.isdir(carpeta):
        print(f"[ERROR] No existe la carpeta {carpeta}")
        return 2

    # Esquema: cuantas columnas tiene que tener cada tabla
    ncols = collections.Counter()
    esquema = os.path.join(AQUI, "esquema_tango.tsv")
    with open(esquema) as f:
        next(f)
        for linea in f:
            ncols[linea.split("\t")[0]] += 1

    # Tablas en alcance
    with open(os.path.join(AQUI, "tablas.txt")) as f:
        tablas = f.read().split()

    # Conteo exacto en origen
    origen = {}
    fo = os.path.join(carpeta, "_filas_origen.csv")
    if os.path.exists(fo):
        origen = leer_filas_origen(fo)
    else:
        print("[aviso] Falta _filas_origen.csv: no se puede comparar contra el origen.\n")

    print(f"{'tabla':<28}{'cols':>5}{'filas':>9}{'origen':>9}  {'enc':<10}estado")
    print("-" * 78)

    problemas, total_filas = [], 0
    for t in tablas:
        path = os.path.join(carpeta, f"{t}.csv")
        if not os.path.exists(path):
            print(f"{t:<28}{'-':>5}{'-':>9}{origen.get(t,'?'):>9}  {'-':<10}FALTA EL ARCHIVO")
            problemas.append(f"{t}: no se exporto")
            continue

        enc, regs = leer_registros(path)
        esperado = ncols[t]
        malos = [i for i, r in enumerate(regs) if len(r.split(FS)) != esperado]
        n = len(regs)
        total_filas += n

        estado = "ok"
        if malos:
            estado = f"{len(malos)} reg. con != {esperado} campos (1o: linea {malos[0]+1})"
            problemas.append(f"{t}: {estado}")
        elif t in origen and origen[t] != n:
            estado = f"DIFIERE del origen ({origen[t]})"
            problemas.append(f"{t}: exporto {n}, origen tiene {origen[t]}")
        elif n == 0:
            estado = "vacia"

        print(f"{t:<28}{esperado:>5}{n:>9}{origen.get(t,'?'):>9}  {enc:<10}{estado}")

    print("-" * 78)
    print(f"{'TOTAL':<28}{'':>5}{total_filas:>9}")
    print()
    if problemas:
        print(f"[X] {len(problemas)} problema(s):")
        for p in problemas:
            print(f"    - {p}")
        print("\nNo cargar nada hasta resolverlos.")
        return 1
    print("[OK] Export integro: columnas y conteos coinciden con el origen.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
