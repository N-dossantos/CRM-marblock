#!/usr/bin/env bash
#
# 05_cargar.sh — carga en Supabase los .sql que generó el ETL (sql/*.sql), en una sola transacción.
# Tarea 10 de PLAN_MIGRACION_TANGO.md · mecánica de PLAN_MAESTRO.md §3.2.5.
#
# Es IDEMPOTENTE: el TRUNCATE va dentro de la misma transacción que la carga, así que correrlo dos
# veces seguidas tiene que dar exactamente los mismos conteos (punto 5 de Review Focus). Si algo
# falla, ON_ERROR_STOP + la transacción única dejan la base como estaba.
#
# Uso:
#   export SUPABASE_DB_URL="$(cat ../../.db_url)"     # archivo gitignoreado, la pass no va por chat
#   ./05_cargar.sh                 carga y muestra los conteos
#   ./05_cargar.sh --conteos       sólo muestra los conteos actuales, no carga nada
#   ./05_cargar.sh --vaciar        sólo trunca (paso 5 de la Tarea 10: dejar la base limpia)
#
# Requisitos: psql (/opt/homebrew/bin/psql), los .sql ya generados (`python3 -m etl`) y las
# migraciones 20261006120000 … 20261006140002 aplicadas (lo están desde el 2026-10-06). El script
# verifica las dos cosas.
#
# IMPORTANTE: SUPABASE_DB_URL tiene que ser el connection string DIRECTO (usuario postgres). El
# pooler no deja hacer SET session_replication_role y el chequeo previo aborta.

set -euo pipefail
cd "$(dirname "$0")"

if [[ -z "${SUPABASE_DB_URL:-}" ]]; then
  echo "ERROR: falta SUPABASE_DB_URL (connection string directo de Supabase)." >&2
  echo "       Dashboard → Project Settings → Database → Connection string → URI." >&2
  echo "       Dejalo en un archivo gitignoreado y exportalo: export SUPABASE_DB_URL=\"\$(cat ../../.db_url)\"" >&2
  exit 2
fi

PSQL=(psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -X -q)

# Las 6 partes, en orden de dependencia. 31_ va después de 30_ porque reparte el total de las
# facturas de compra en percepciones_monto (ver etl/compras.py).
PARTES=(sql/10_maestros.sql sql/20_ventas.sql sql/30_compras.sql sql/31_percepciones_compra.sql
        sql/40_tesoreria.sql sql/50_contabilidad.sql)

# Todo lo que se vacía antes de cargar. Son las 42 tablas transaccionales + los maestros que vienen
# de Tango + los datos de prueba de cuenta2. NO están acá, a propósito:
#   productos (los 25 sembrados se conservan: decisión de §5.1 del plan maestro y de D-productos),
#   alicuotas_iva, tipos_comprobante_tesoreria, agrupaciones_tesoreria (catálogos del sistema que el
#   ETL referencia por id), config_empresa, tablas_generales, contadores (se hace UPSERT abajo) y
#   audit_log (es una bitácora: si querés limpiarla, `TRUNCATE audit_log;` a mano).
# Verificado contra pg_constraint: ninguna de esas 8 tiene hijos fuera de esta lista, así que el
# CASCADE no arrastra nada que no esté nombrado acá.
TABLAS="
  asiento_items, asientos_contables,
  cheques, cheques_propios, clientes, clientes_cuenta2, conciliaciones_bancarias,
  cuenta2_cheques, cuenta2_movimientos, cuenta2_remito_items, cuenta2_remitos, cuentas_bancarias,
  factura_compra_iva_detalle, factura_items, facturas, facturas_compra, facturas_compra_items,
  materiales, movimientos_tesoreria,
  nota_compra_items, nota_items, notas, notas_compra,
  pago_proveedor_facturas, pago_proveedor_medios, pagos_proveedor,
  percepciones, percepciones_compra, plan_de_cuentas, presupuesto_items, presupuestos,
  proveedor_alicuotas, proveedores, proveedores_cuenta2,
  recibo_facturas, recibo_medios, recibos,
  remito_compra_items, remito_items, remitos, remitos_compra, retenciones"

# Contadores: el último número emitido por serie, POR FECHA (no el máximo: H4, el recibo 00041189 es
# un error de carga de Tango). Los valores son del .bak del 25/09 y los recalcula
# `python3 -m etl.contadores`; el día del cutover hay que reconfirmarlos contra ARCA (facturas y
# notas) y contra el talonario físico (remitos) — D5.
#   * NC/ND tienen un contador por letra (H16): la serie B es fiscalmente independiente de la A.
#   * pago_proveedor va en el punto de venta 00000, que es el que usa toda la historia de Tango
#     (las O/P no tienen punto de venta fiscal); el seed lo tenía en 00002.
#   * asiento lo setea sql/50_contabilidad.sql con la cantidad de asientos cargados.
#   * La serie FAC A 00003 ("Factura de Crédito Electrónica MiPyME", última 2023-05-24, 4
#     comprobantes) no tiene contador: `contadores` tiene un punto de venta por tipo. Si se vuelve a
#     usar, hay que modelarla aparte.
CONTADORES="
  INSERT INTO contadores (tipo, punto_venta, ultimo_numero, descripcion) VALUES
    ('factura_a',      '00002',  2321, 'Factura A'),
    ('factura_b',      '00002',    63, 'Factura B'),
    ('nota_credito',   '00002',   165, 'Nota de crédito A'),
    ('nota_credito_b', '00002',     1, 'Nota de crédito B'),
    ('nota_debito',    '00002',    41, 'Nota de débito A'),
    ('nota_debito_b',  '00002',     0, 'Nota de débito B'),
    ('recibo',         '00001',  4288, 'Recibo'),
    ('presupuesto',    '00002',     0, 'Presupuesto'),
    ('remito',         '00001', 10366, 'Remitos de venta — numeración del talonario preimpreso'),
    ('pago_proveedor', '00000',  3358, 'Pago a Proveedor')
  ON CONFLICT (tipo) DO UPDATE
    SET punto_venta = EXCLUDED.punto_venta, ultimo_numero = EXCLUDED.ultimo_numero;"

conteos() {
  "${PSQL[@]}" -f sql_conteos.sql
}

# ── 0) Chequeos previos, fuera de la transacción ───────────────────────────────
for f in "${PARTES[@]}" sql_conteos.sql sql_reset_secuencias.sql; do
  [[ -f "$f" ]] || { echo "ERROR: falta $f. Corré 'python3 -m etl' primero." >&2; exit 1; }
done

if [[ "${1:-}" == "--conteos" ]]; then
  conteos
  exit 0
fi

echo "== Verificando la base =="
"${PSQL[@]}" <<'SQL'
DO $$
DECLARE v_faltan text;
BEGIN
  -- Las migraciones del 2026-10-06 tienen que estar aplicadas o el COPY falla por columnas que no existen.
  SELECT string_agg(x, ', ') INTO v_faltan FROM (
    SELECT 'recibo_facturas.importe (20261006120000)' AS x
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_name='recibo_facturas' AND column_name='importe')
    UNION ALL SELECT 'notas.factura_id nullable (20261006120000)'
     WHERE EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name='notas' AND column_name='factura_id' AND is_nullable='NO')
    UNION ALL SELECT 'facturas_tipo_numero_key (20261006130000)'
     WHERE NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='facturas_tipo_numero_key')
    UNION ALL SELECT 'percepciones_compra (20261006140000)'
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.tables
                       WHERE table_schema='public' AND table_name='percepciones_compra')
    UNION ALL SELECT 'notas.cliente_id (20261006140002)'
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_name='notas' AND column_name='cliente_id')
  ) t;
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION E'Faltan migraciones por aplicar: %\nAplicá supabase/migrations/20261006* antes de cargar.', v_faltan;
  END IF;

  -- La carga masiva necesita diferir FKs y triggers. Si el rol no puede, mejor enterarse acá.
  BEGIN
    SET LOCAL session_replication_role = replica;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'El rol no puede hacer SET session_replication_role: usá el usuario postgres del connection string directo.';
  END;
END $$;
SQL
echo "   OK: migraciones aplicadas y el rol puede diferir FKs."

# ── 1) Vaciar y cargar, todo en una transacción ────────────────────────────────
if [[ "${1:-}" == "--vaciar" ]]; then
  echo "== Vaciando (sin cargar) =="
  "${PSQL[@]}" <<SQL
BEGIN;
SET session_replication_role = replica;
TRUNCATE $TABLAS RESTART IDENTITY CASCADE;
SET session_replication_role = origin;
COMMIT;
SQL
  echo "   OK: vaciado."
  conteos
  exit 0
fi

echo "== Cargando =="
{
  echo "BEGIN;"
  echo "SET session_replication_role = replica;"
  echo "TRUNCATE $TABLAS RESTART IDENTITY CASCADE;"
  for f in "${PARTES[@]}"; do
    echo "\\echo '   -> $f'"
    echo "\\i $f"
  done
  echo "$CONTADORES"
  echo "SET session_replication_role = origin;"
  echo "COMMIT;"
  echo "\\i sql_reset_secuencias.sql"
} | "${PSQL[@]}"

echo "   OK: carga completa."
conteos

cat <<'FIN'

Siguiente (Tarea 10 pasos 3 y 4):
  psql "$SUPABASE_DB_URL" -f ../POST_LOAD_VERIFY.sql
  python3 -m etl.controles_ventas ; python3 -m etl.controles_compras ; python3 -m etl.controles_tesoreria
  Revisar sql/_anomalias.txt y después entrar a la app (3 clientes + un comprobante de prueba).
Para dejar la base limpia hasta el cutover (paso 5):  ./05_cargar.sh --vaciar
FIN
