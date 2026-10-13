"""
etl/maestros.py - Tarea 5: maestros (clientes, proveedores, cuentas, plan de cuentas, materiales).

Todos los ids son los ids sustitutos de Tango (ID_GVA14, ID_CPA01, ID_SBA01, ID_CUENTA, ID_CPA45):
la carga es determinista y los demas modulos no necesitan mapas COD -> id generados por la base.
Los 'seed' de prueba que hay hoy en Supabase (Marblock SA, Acapulco, Galicia, Combustible...) se
reemplazan: 05_cargar.sh trunca estas tablas antes de cargar.

Uso:  python3 -m etl.maestros   (desde supabase/tango/)  ->  sql/10_maestros.sql
"""
import re
from decimal import Decimal

from etl import comun

CUIT_CONSUMIDOR_FINAL = "00-00000000-0"
DESCUENTOS_PERMITIDOS = (0, 10, 15, 20)       # CHECK de clientes.descuento_porcentaje (D3 = b)
CONDICION = {"RI": "Resp. Inscripto", "CF": "Consumidor Final", "EX": "Exento"}


def condicion_iva(cat):
    if cat not in CONDICION:
        raise ValueError("CAT_IVA desconocida: %r" % cat)
    return CONDICION[cat]


def descuento_permitido(p):
    """Valor permitido mas cercano; en empate (5 %) se sube."""
    return min(DESCUENTOS_PERMITIDOS, key=lambda v: (abs(Decimal(v) - p), -v))


def cuit_valido(c):
    return bool(re.fullmatch(r"\d{2}-?\d{8}-?\d", c or ""))


def formatear_cuit(c):
    c = (c or "").strip()
    if re.fullmatch(r"\d{11}", c):
        return "%s-%s-%s" % (c[:2], c[2:10], c[10])
    return c


def recortar(v, n, ctx):
    if v is not None and len(v) > n:
        comun.anomalia("texto recortado a %d caracteres en %s: %r" % (n, ctx, v))
        return v[:n]
    return v


def ultima_cat_iva(gva12):
    """COD_CLIENT -> CAT_IVA del ultimo comprobante (por fecha, luego id) que la tenga informada."""
    ult = {}
    for r in gva12:
        if not r["CAT_IVA"].strip():
            continue
        k = (r["FECHA_EMIS"], int(r["ID_GVA12"]))
        if r["COD_CLIENT"] not in ult or k > ult[r["COD_CLIENT"]][0]:
            ult[r["COD_CLIENT"]] = (k, r["CAT_IVA"].strip())
    return {c: v[1] for c, v in ult.items()}


def clientes(gva14, cat_iva, provincias):
    """-> filas (id, razon_social, cuit, condicion_iva, direccion, localidad, provincia, telefono, email,
    descuento_porcentaje, activo)."""
    usados, out = set(), []
    for r in sorted(gva14, key=lambda r: int(r["ID_GVA14"])):
        ctx = "GVA14 %s" % r["COD_CLIENT"]
        cuit = formatear_cuit(r["CUIT"])
        if not cuit:
            cuit = CUIT_CONSUMIDOR_FINAL
        if cuit in usados:
            nuevo = "99-%08d-0" % int(r["COD_CLIENT"])
            comun.anomalia("%s (%s): CUIT %s repetido; se carga como %s" % (ctx, r["RAZON_SOCI"].strip(), cuit, nuevo))
            cuit = nuevo
        usados.add(cuit)
        cat = cat_iva.get(r["COD_CLIENT"])
        if cat:
            cond = condicion_iva(cat)
        else:
            cond = "Resp. Inscripto" if cuit_valido(cuit) and cuit != CUIT_CONSUMIDOR_FINAL else "Consumidor Final"
        dto = Decimal(r["PORC_DESC"] or 0)
        dto_ok = descuento_permitido(dto)
        if dto != dto_ok:
            comun.anomalia("%s (%s): descuento %s%% redondeado a %s%% (D3)" % (ctx, r["RAZON_SOCI"].strip(), dto, dto_ok))
        out.append((
            int(r["ID_GVA14"]), recortar(comun.texto(r["RAZON_SOCI"]), 200, ctx), cuit, cond,
            recortar(comun.texto(r["DOMICILIO"]), 300, ctx), recortar(comun.texto(r["LOCALIDAD"]), 100, ctx),
            provincias.get(r["COD_PROVIN"]), recortar(comun.texto(r["TELEFONO_1"]), 50, ctx),
            recortar(comun.texto(r["E_MAIL"]), 150, ctx), dto_ok, comun.fecha(r["FECHA_INHA"]) is None))
    return out


def proveedores(cpa01, provincias):
    out = []
    for r in sorted(cpa01, key=lambda r: int(r["ID_CPA01"])):
        ctx = "CPA01 %s" % r["COD_PROVEE"]
        out.append((
            int(r["ID_CPA01"]), recortar(comun.texto(r["NOM_PROVEE"]), 200, ctx), formatear_cuit(r["N_CUIT"]),
            condicion_iva(r["COND_IVA"].strip()), recortar(comun.texto(r["N_ING_BRUT"]), 30, ctx),
            comun.fecha(r["FECHA_ALTA"], ctx), recortar(comun.texto(r["DOMICILIO"]), 300, ctx),
            recortar(comun.texto(r["LOCALIDAD"]), 100, ctx), provincias.get(r["PROVINCIA"]),
            recortar(comun.texto(r["TELEFONO_1"]), 50, ctx), recortar(comun.texto(r["E_MAIL"]), 150, ctx),
            comun.fecha(r["FECHA_INHA"]) is None))
    return out


def clase_cuenta(r):
    """SBA01 -> (clase, agrupacion_id). B = banco, C = valores a depositar, el resto (caja y cuentas
    'O' de retenciones/contrapartida) se tratan como caja."""
    if r["TIPO"] == "B":
        return "banco", 1
    if r["TIPO"] == "C":
        return "valores", 3
    return "caja", 2


# Contrapartidas de Tango (no son plata): se cargan inactivas y sin movimientos (ver tesoreria.py).
CTA_CONTRAPARTIDA = ("2.0", "5.0")


def cuentas_bancarias(sba01, bancos):
    out = []
    for r in sorted(sba01, key=lambda r: int(r["ID_SBA01"])):
        clase, agr = clase_cuenta(r)
        banco = bancos.get(r["ID_BANCO"]) if r["ID_BANCO"].strip() else None
        out.append((int(r["ID_SBA01"]), recortar(comun.texto(r["DESCRIPCIO"]), 200, "SBA01"),
                    recortar(banco, 100, "SBA01"), recortar(comun.texto(r["NRO_CTA_BANCARIA"]), 50, "SBA01"),
                    clase, agr, r["COD_CTA"] not in CTA_CONTRAPARTIDA))
    return out


def tipo_cuenta(id_clase):
    return {"1": "Activo", "2": "Pasivo", "3": "Patrimonio", "4": "Ingreso", "5": "Egreso",
            "6": "Patrimonio", "7": "Patrimonio"}[id_clase]


def plan_de_cuentas(cuenta):
    """CUENTA no trae el rubro (CUENTA <-> RUBRO_CN no esta en las 57 tablas): se cargan las 152 cuentas
    hoja, sin padre, nivel 1, con el tipo derivado de ID_CLASE_CUENTA."""
    return [(int(r["ID_CUENTA"]), r["COD_CUENTA"].strip(), recortar(comun.texto(r["DESC_CUENTA"]), 200, "CUENTA"),
             tipo_cuenta(r["ID_CLASE_CUENTA"]), 1, True, r["HABILITADO"] == "S")
            for r in sorted(cuenta, key=lambda r: int(r["ID_CUENTA"]))]


def materiales(cpa45):
    return [(int(r["ID_CPA45"]), r["COD_CONCEP"].strip(), recortar(comun.texto(r["DESC_CONCE"]), 300, "CPA45"), True)
            for r in sorted(cpa45, key=lambda r: int(r["ID_CPA45"]))]


def generar():
    prov_gva = {r["COD_PROVIN"]: r["NOMBRE_PRO"].strip() for r in comun.leer("GVA18")}
    prov_cpa = {r["COD_PROVIN"]: r["NOM_PROVIN"].strip() for r in comun.leer("CPA57")}
    prov_cpa.setdefault("00", prov_gva["00"])
    bancos = {r["ID_BANCO"]: r["DESC_BANCO"].strip() for r in comun.leer("BANCO")}
    cli = clientes(comun.leer("GVA14"), ultima_cat_iva(comun.leer("GVA12")), prov_gva)
    prv = proveedores(comun.leer("CPA01"), prov_cpa)
    cb = cuentas_bancarias(comun.leer("SBA01"), bancos)
    pc = plan_de_cuentas(comun.leer("CUENTA"))
    mat = materiales(comun.leer("CPA45"))
    partes = [
        "-- Maestros de Tango (etl/maestros.py). Ids = ids sustitutos de Tango.\n",
        comun.escribir_copy("clientes", ["id", "razon_social", "cuit", "condicion_iva", "direccion", "localidad",
                                         "provincia", "telefono", "email", "descuento_porcentaje", "activo"], cli),
        comun.escribir_copy("proveedores", ["id", "razon_social", "cuit", "condicion_iva", "numero_ingresos_brutos",
                                            "fecha_alta", "direccion", "localidad", "provincia", "telefono", "email",
                                            "activo"], prv),
        comun.escribir_copy("cuentas_bancarias", ["id", "descripcion", "banco", "numero", "clase", "agrupacion_id",
                                                  "activo"], cb),
        comun.escribir_copy("plan_de_cuentas", ["id", "codigo", "descripcion", "tipo_cuenta", "nivel", "imputable",
                                                "activo"], pc),
        comun.escribir_copy("materiales", ["id", "codigo", "descripcion", "activo"], mat),
    ]
    comun.escribir_sql("10_maestros.sql", partes)
    return {"clientes": len(cli), "proveedores": len(prv), "cuentas_bancarias": len(cb),
            "plan_de_cuentas": len(pc), "materiales": len(mat)}


if __name__ == "__main__":
    print(generar())
    comun.escribir_anomalias()
