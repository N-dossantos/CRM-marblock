"""Corre todo el ETL en orden y deja sql/_anomalias.txt unificado.  Uso: python3 -m etl   (desde supabase/tango/)"""
from etl import comun, compras, contabilidad, maestros, tesoreria, ventas


def main():
    resumen = {}
    for nombre, mod in (("maestros", maestros), ("ventas", ventas), ("compras", compras),
                        ("tesoreria", tesoreria), ("contabilidad", contabilidad)):
        resumen[nombre] = mod.generar()
        print(nombre, resumen[nombre])
    comun.escribir_anomalias()
    print("anomalias: %d lineas distintas -> sql/_anomalias.txt" % len(dict.fromkeys(comun.ANOMALIAS)))


if __name__ == "__main__":
    main()
