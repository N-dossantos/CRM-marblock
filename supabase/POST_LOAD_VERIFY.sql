-- =============================================================
-- CRM Ventas — POST-LOAD VERIFICATION (run AFTER the load + sequence reset — PLAN_MAESTRO.md §3.2.5)
-- Where: Supabase SQL Editor, or  psql "$SUPABASE_DB_URL" -f supabase/POST_LOAD_VERIFY.sql
-- Read-only. Every check prints a `check` label + a `status` (OK / ⚠ REVISAR) where it can
-- self-judge; the row-count block you compare by eye against the LAN DB.
-- =============================================================

\echo '=== 1) ROW COUNTS (compara cada número contra la LAN: corré el mismo SELECT allá) ==='
SELECT 'clientes'          AS tabla, COUNT(*) AS filas FROM clientes
UNION ALL SELECT 'productos',          COUNT(*) FROM productos
UNION ALL SELECT 'presupuestos',       COUNT(*) FROM presupuestos
UNION ALL SELECT 'presupuesto_items',  COUNT(*) FROM presupuesto_items
UNION ALL SELECT 'remitos',            COUNT(*) FROM remitos
UNION ALL SELECT 'remito_items',       COUNT(*) FROM remito_items
UNION ALL SELECT 'facturas',           COUNT(*) FROM facturas
UNION ALL SELECT 'factura_items',      COUNT(*) FROM factura_items
UNION ALL SELECT 'notas',              COUNT(*) FROM notas
UNION ALL SELECT 'nota_items',         COUNT(*) FROM nota_items
UNION ALL SELECT 'recibos',            COUNT(*) FROM recibos
UNION ALL SELECT 'recibo_medios',      COUNT(*) FROM recibo_medios
UNION ALL SELECT 'recibo_facturas',    COUNT(*) FROM recibo_facturas
UNION ALL SELECT 'cheques',            COUNT(*) FROM cheques
UNION ALL SELECT 'config_empresa',     COUNT(*) FROM config_empresa
UNION ALL SELECT 'contadores',         COUNT(*) FROM contadores
UNION ALL SELECT 'cuentas_bancarias',  COUNT(*) FROM cuentas_bancarias
ORDER BY tabla;

\echo ''
\echo '=== 2) NUMERACIÓN — contadores cruzaron intactos (la próxima emisión sigue de acá) ==='
SELECT tipo, punto_venta, ultimo_numero, descripcion
FROM contadores ORDER BY tipo;
-- Sanidad manual: para cada tipo, contadores.ultimo_numero debe ser >= al máximo ya emitido abajo.
SELECT 'presupuestos'     AS comprobante, COALESCE(MAX(numero_comp),0) AS max_emitido FROM presupuestos
UNION ALL SELECT 'remitos',            COALESCE(MAX(numero_comp),0) FROM remitos
UNION ALL SELECT 'facturas (A y B)',   COALESCE(MAX(numero_comp),0) FROM facturas
UNION ALL SELECT 'notas (NC y ND)',    COALESCE(MAX(numero_comp),0) FROM notas
UNION ALL SELECT 'recibos',            COALESCE(MAX(numero_comp),0) FROM recibos
ORDER BY comprobante;

\echo ''
\echo '=== 3) INTEGRIDAD REFERENCIAL — 0 huérfanos esperado en cada check ==='
SELECT 'presupuesto_items->presupuestos' AS check,
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END AS status, COUNT(*) AS huerfanos
  FROM presupuesto_items i LEFT JOIN presupuestos p ON p.id=i.presupuesto_id WHERE p.id IS NULL
UNION ALL SELECT 'remito_items->remitos',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM remito_items i LEFT JOIN remitos r ON r.id=i.remito_id WHERE r.id IS NULL
UNION ALL SELECT 'factura_items->facturas',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM factura_items i LEFT JOIN facturas f ON f.id=i.factura_id WHERE f.id IS NULL
UNION ALL SELECT 'nota_items->notas',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM nota_items i LEFT JOIN notas n ON n.id=i.nota_id WHERE n.id IS NULL
UNION ALL SELECT 'notas->facturas',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM notas n LEFT JOIN facturas f ON f.id=n.factura_id WHERE f.id IS NULL
UNION ALL SELECT 'recibo_medios->recibos',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM recibo_medios m LEFT JOIN recibos r ON r.id=m.recibo_id WHERE r.id IS NULL
UNION ALL SELECT 'recibo_facturas->recibos',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM recibo_facturas rf LEFT JOIN recibos r ON r.id=rf.recibo_id WHERE r.id IS NULL
UNION ALL SELECT 'recibo_facturas->facturas',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM recibo_facturas rf LEFT JOIN facturas f ON f.id=rf.factura_id WHERE f.id IS NULL
UNION ALL SELECT 'remitos.factura_id->facturas',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM remitos r LEFT JOIN facturas f ON f.id=r.factura_id WHERE r.factura_id IS NOT NULL AND f.id IS NULL
UNION ALL SELECT 'facturas.remito_id->remitos',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM facturas f LEFT JOIN remitos r ON r.id=f.remito_id WHERE f.remito_id IS NOT NULL AND r.id IS NULL
UNION ALL SELECT 'comprobantes->clientes',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM (
    SELECT cliente_id FROM presupuestos UNION ALL SELECT cliente_id FROM remitos
    UNION ALL SELECT cliente_id FROM facturas UNION ALL SELECT cliente_id FROM recibos
  ) q LEFT JOIN clientes c ON c.id=q.cliente_id WHERE c.id IS NULL
ORDER BY check;

\echo ''
\echo '=== 4) SECUENCIAS — cada SERIAL debe estar >= MAX(id) o la próxima alta colisiona (paso 2 de PLAN_MAESTRO.md §3.2.5) ==='
-- Se resuelve el MAX(id) por tabla dinámicamente (igual que el reseteo del paso 3).
DO $$
DECLARE r record; v_max bigint; v_seq bigint; v_behind int := 0;
BEGIN
  FOR r IN
    SELECT s.relname AS seq, t.relname AS tbl, a.attname AS col
    FROM pg_class s
    JOIN pg_depend d    ON d.objid = s.oid AND d.deptype='a'
    JOIN pg_class t     ON t.oid = d.refobjid
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
    WHERE s.relkind='S' AND t.relnamespace='public'::regnamespace
    ORDER BY t.relname
  LOOP
    EXECUTE format('SELECT COALESCE(MAX(%I),0) FROM %I', r.col, r.tbl) INTO v_max;
    SELECT COALESCE(last_value,0) INTO v_seq FROM pg_sequences
      WHERE schemaname='public' AND sequencename = r.seq;
    IF COALESCE(v_seq,0) < v_max THEN
      v_behind := v_behind + 1;
      RAISE NOTICE '⚠ %.% : seq=%  <  MAX=%   -> re-correr reseteo (paso 3)', r.tbl, r.col, v_seq, v_max;
    ELSE
      RAISE NOTICE 'OK %  : seq=%  >=  MAX=%', r.tbl, v_seq, v_max;
    END IF;
  END LOOP;
  IF v_behind = 0 THEN
    RAISE NOTICE 'SECUENCIAS OK: ninguna por detrás del MAX(id).';
  ELSE
    RAISE NOTICE 'SECUENCIAS ⚠: % secuencia(s) por detrás — re-corré el paso 2 de PLAN_MAESTRO.md §3.2.5', v_behind;
  END IF;
END $$;

\echo ''
\echo '=== 5) TOTALES — ninguna factura/nota con IVA fuera del 21% (anti-corrupción de importación) ==='
SELECT 'facturas_iva_21' AS check,
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END AS status, COUNT(*) AS filas_mal
  FROM facturas WHERE round(neto_gravado*0.21,2) <> iva_monto
UNION ALL
SELECT 'facturas_total_coherente',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM facturas WHERE round(neto_gravado+iva_monto,2) <> total;

\echo ''
\echo '=== 6) SEGURIDAD — RLS/anon/auth listos para go-live ==='
SELECT 'tablas_rls_habilitada' AS check,
       CASE WHEN COUNT(*)=17 THEN 'OK (17/17)' ELSE '⚠ REVISAR' END AS status, COUNT(*) AS n
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity
UNION ALL
SELECT 'anon_puede_ejecutar_funciones',
       CASE WHEN COUNT(*)=0 THEN 'OK (0)' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND has_function_privilege('anon', p.oid, 'EXECUTE')
UNION ALL
SELECT 'anon_puede_leer_tablas',
       CASE WHEN COUNT(*)=0 THEN 'OK (0)' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM pg_tables t WHERE schemaname='public'
   AND has_table_privilege('anon', quote_ident(schemaname)||'.'||quote_ident(tablename),'SELECT')
UNION ALL
SELECT 'usuarios_auth_creados (>=1 para poder loguear)',
       CASE WHEN COUNT(*)>=1 THEN 'OK' ELSE '⚠ FALTA crear staff (PLAN_MAESTRO.md §3.4 paso 2)' END, COUNT(*)
  FROM auth.users
ORDER BY check;

\echo ''
\echo '=== RECORDATORIO manual (no verificable por SQL): Dashboard → Auth → deshabilitar "Allow new users to sign up" (PLAN_MAESTRO.md §3.4 paso 1). ==='
