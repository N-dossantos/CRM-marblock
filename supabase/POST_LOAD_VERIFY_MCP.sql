-- =============================================================
-- CRM Ventas — POST-LOAD VERIFICATION (single-query / MCP + SQL-Editor edition)
-- Run this AFTER the load + sequence reset (PLAN_MAESTRO.md §3.2.5).
--
-- WHY a second file: POST_LOAD_VERIFY.sql is the psql edition (\echo + a RAISE
-- NOTICE DO block) and only prints under `psql -f`. This edition is ONE SELECT
-- returning ONE result set, so it runs verbatim through the Supabase MCP
-- (execute_sql) or the dashboard SQL Editor — same checks, returnable as rows.
--
-- Read-only. Each row has: seccion | item | status | detalle
--   status OK / '⚠ REVISAR'  -> self-judged (integridad, secuencias, totales, seguridad)
--   status 'ⓘ ...'           -> data to eyeball (row counts vs LAN, numeración continuidad)
-- Scan the status column for any '⚠' — none expected on a clean load.
-- =============================================================
WITH rc(t, n) AS (
  SELECT 'clientes',          COUNT(*) FROM clientes
  UNION ALL SELECT 'productos',         COUNT(*) FROM productos
  UNION ALL SELECT 'presupuestos',      COUNT(*) FROM presupuestos
  UNION ALL SELECT 'presupuesto_items', COUNT(*) FROM presupuesto_items
  UNION ALL SELECT 'remitos',           COUNT(*) FROM remitos
  UNION ALL SELECT 'remito_items',      COUNT(*) FROM remito_items
  UNION ALL SELECT 'facturas',          COUNT(*) FROM facturas
  UNION ALL SELECT 'factura_items',     COUNT(*) FROM factura_items
  UNION ALL SELECT 'notas',             COUNT(*) FROM notas
  UNION ALL SELECT 'nota_items',        COUNT(*) FROM nota_items
  UNION ALL SELECT 'recibos',           COUNT(*) FROM recibos
  UNION ALL SELECT 'recibo_medios',     COUNT(*) FROM recibo_medios
  UNION ALL SELECT 'recibo_facturas',   COUNT(*) FROM recibo_facturas
  UNION ALL SELECT 'cheques',           COUNT(*) FROM cheques
  UNION ALL SELECT 'config_empresa',    COUNT(*) FROM config_empresa
  UNION ALL SELECT 'contadores',        COUNT(*) FROM contadores
  UNION ALL SELECT 'cuentas_bancarias', COUNT(*) FROM cuentas_bancarias
),
-- seq last_value vs MAX(id): if seq < MAX the next INSERT collides -> re-run
-- PLAN_MAESTRO.md §3.2.5 paso 2. 15 serial-owned sequences (config_empresa +
-- contadores have no serial id).
seqs(tbl, mx, sq) AS (
  SELECT 'clientes',          (SELECT COALESCE(MAX(id),0) FROM clientes),          (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='clientes_id_seq')
  UNION ALL SELECT 'productos',         (SELECT COALESCE(MAX(id),0) FROM productos),         (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='productos_id_seq')
  UNION ALL SELECT 'presupuestos',      (SELECT COALESCE(MAX(id),0) FROM presupuestos),      (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='presupuestos_id_seq')
  UNION ALL SELECT 'presupuesto_items', (SELECT COALESCE(MAX(id),0) FROM presupuesto_items), (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='presupuesto_items_id_seq')
  UNION ALL SELECT 'remitos',           (SELECT COALESCE(MAX(id),0) FROM remitos),           (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='remitos_id_seq')
  UNION ALL SELECT 'remito_items',      (SELECT COALESCE(MAX(id),0) FROM remito_items),      (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='remito_items_id_seq')
  UNION ALL SELECT 'facturas',          (SELECT COALESCE(MAX(id),0) FROM facturas),          (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='facturas_id_seq')
  UNION ALL SELECT 'factura_items',     (SELECT COALESCE(MAX(id),0) FROM factura_items),     (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='factura_items_id_seq')
  UNION ALL SELECT 'notas',             (SELECT COALESCE(MAX(id),0) FROM notas),             (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='notas_id_seq')
  UNION ALL SELECT 'nota_items',        (SELECT COALESCE(MAX(id),0) FROM nota_items),        (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='nota_items_id_seq')
  UNION ALL SELECT 'recibos',           (SELECT COALESCE(MAX(id),0) FROM recibos),           (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='recibos_id_seq')
  UNION ALL SELECT 'recibo_medios',     (SELECT COALESCE(MAX(id),0) FROM recibo_medios),     (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='recibo_medios_id_seq')
  UNION ALL SELECT 'recibo_facturas',   (SELECT COALESCE(MAX(id),0) FROM recibo_facturas),   (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='recibo_facturas_id_seq')
  UNION ALL SELECT 'cheques',           (SELECT COALESCE(MAX(id),0) FROM cheques),           (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='cheques_id_seq')
  UNION ALL SELECT 'cuentas_bancarias', (SELECT COALESCE(MAX(id),0) FROM cuentas_bancarias), (SELECT COALESCE(last_value,0) FROM pg_sequences WHERE schemaname='public' AND sequencename='cuentas_bancarias_id_seq')
)
SELECT seccion, item, status, detalle
FROM (
  -- 1) ROW COUNTS — compará cada número contra la LAN (corré el mismo COUNT allá)
  SELECT 10 AS ord, '1·ROW COUNTS' AS seccion, t AS item, 'ⓘ vs LAN' AS status, n::text AS detalle FROM rc

  -- 2) NUMERACIÓN — contadores cruzaron intactos + máximo ya emitido (comparar a ojo)
  UNION ALL SELECT 20, '2·NUMERACIÓN', 'contador: '||tipo, 'ⓘ próx nº',
                   'pv='||punto_venta||'  ultimo_numero='||ultimo_numero::text FROM contadores
  UNION ALL SELECT 21, '2·NUMERACIÓN', 'max emitido: presupuestos', 'ⓘ manual', 'nº '||COALESCE(MAX(numero_comp),0)::text FROM presupuestos
  UNION ALL SELECT 21, '2·NUMERACIÓN', 'max emitido: remitos',      'ⓘ manual', 'nº '||COALESCE(MAX(numero_comp),0)::text FROM remitos
  UNION ALL SELECT 21, '2·NUMERACIÓN', 'max emitido: facturas',     'ⓘ manual', 'nº '||COALESCE(MAX(numero_comp),0)::text FROM facturas
  UNION ALL SELECT 21, '2·NUMERACIÓN', 'max emitido: notas',        'ⓘ manual', 'nº '||COALESCE(MAX(numero_comp),0)::text FROM notas
  UNION ALL SELECT 21, '2·NUMERACIÓN', 'max emitido: recibos',      'ⓘ manual', 'nº '||COALESCE(MAX(numero_comp),0)::text FROM recibos

  -- 3) INTEGRIDAD REFERENCIAL — 0 huérfanos esperado
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'presupuesto_items->presupuestos', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM presupuesto_items i LEFT JOIN presupuestos p ON p.id=i.presupuesto_id WHERE p.id IS NULL
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'remito_items->remitos', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM remito_items i LEFT JOIN remitos r ON r.id=i.remito_id WHERE r.id IS NULL
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'factura_items->facturas', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM factura_items i LEFT JOIN facturas f ON f.id=i.factura_id WHERE f.id IS NULL
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'nota_items->notas', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM nota_items i LEFT JOIN notas n ON n.id=i.nota_id WHERE n.id IS NULL
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'notas->facturas', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM notas n LEFT JOIN facturas f ON f.id=n.factura_id WHERE f.id IS NULL
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'recibo_medios->recibos', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM recibo_medios m LEFT JOIN recibos r ON r.id=m.recibo_id WHERE r.id IS NULL
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'recibo_facturas->recibos', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM recibo_facturas rf LEFT JOIN recibos r ON r.id=rf.recibo_id WHERE r.id IS NULL
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'recibo_facturas->facturas', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM recibo_facturas rf LEFT JOIN facturas f ON f.id=rf.factura_id WHERE f.id IS NULL
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'remitos.factura_id->facturas', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM remitos r LEFT JOIN facturas f ON f.id=r.factura_id WHERE r.factura_id IS NOT NULL AND f.id IS NULL
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'facturas.remito_id->remitos', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM facturas f LEFT JOIN remitos r ON r.id=f.remito_id WHERE f.remito_id IS NOT NULL AND r.id IS NULL
  UNION ALL SELECT 30, '3·INTEGRIDAD', 'comprobantes->clientes', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM ( SELECT cliente_id FROM presupuestos UNION ALL SELECT cliente_id FROM remitos
                   UNION ALL SELECT cliente_id FROM facturas UNION ALL SELECT cliente_id FROM recibos
                 ) q LEFT JOIN clientes c ON c.id=q.cliente_id WHERE c.id IS NULL

  -- 4) SECUENCIAS — cada SERIAL >= MAX(id) o la próxima alta colisiona
  UNION ALL SELECT 40, '4·SECUENCIAS', tbl||'.id', CASE WHEN sq < mx THEN '⚠ REVISAR' ELSE 'OK' END,
                   'seq='||sq::text||'  MAX(id)='||mx::text FROM seqs

  -- 5) TOTALES — coherencia de importación
  --    Ya NO se valida "IVA = 21%": desde la migración multi-alícuota (20260802120000) un
  --    comprobante puede mezclar 0 / 10,5 / 21 / 27%, así que el 21% fijo daba falsos positivos.
  --    Tampoco se re-deriva el IVA desde los ítems: el prorrateo del descuento general y la
  --    exclusión de pallet vacío / transporte (20260820120000) harían que esta query tuviera que
  --    replicar crm_calc_totales_multi_alicuota — y una copia que se desincroniza miente.
  --    Se validan invariantes EXACTAS, que es lo que detecta corrupción de importación:
  UNION ALL SELECT 50, '5·TOTALES', 'facturas total = neto+iva+percep', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM facturas WHERE round(neto_gravado+iva_monto+COALESCE(percepciones_monto,0),2) <> total
  UNION ALL SELECT 50, '5·TOTALES', 'notas total = neto+iva+percep', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM notas WHERE round(neto_gravado+iva_monto+COALESCE(percepciones_monto,0),2) <> total
  -- La cabecera denormaliza la suma del detalle: si no coinciden, la carga quedó a medias.
  UNION ALL SELECT 50, '5·TOTALES', 'facturas percep = suma detalle', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM facturas f WHERE COALESCE(f.percepciones_monto,0)
                 <> COALESCE((SELECT round(SUM(p.monto),2) FROM percepciones p WHERE p.factura_id=f.id),0)
  UNION ALL SELECT 50, '5·TOTALES', 'notas percep = suma detalle', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM notas n WHERE COALESCE(n.percepciones_monto,0)
                 <> COALESCE((SELECT round(SUM(p.monto),2) FROM percepciones p WHERE p.nota_id=n.id),0)
  -- Banda de plausibilidad: ninguna alícuota vigente supera el 27%.
  UNION ALL SELECT 50, '5·TOTALES', 'facturas IVA en banda 0-27%', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM facturas WHERE iva_monto < 0 OR iva_monto > round(neto_gravado*0.27,2)+0.01
  UNION ALL SELECT 50, '5·TOTALES', 'notas IVA en banda 0-27%', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM notas WHERE iva_monto < 0 OR iva_monto > round(neto_gravado*0.27,2)+0.01
  -- Informativo: cuántas se apartan del 21% puro. No es un error — es para que el número no sorprenda.
  UNION ALL SELECT 50, '5·TOTALES', 'facturas fuera de 21% puro (info)', 'INFO', COUNT(*)::text||' filas'
            FROM facturas WHERE round(neto_gravado*0.21,2) <> iva_monto
  UNION ALL SELECT 50, '5·TOTALES', 'facturas con percepción (info)', 'INFO', COUNT(*)::text||' filas'
            FROM facturas WHERE COALESCE(percepciones_monto,0) <> 0

  -- 6) SEGURIDAD — RLS/anon/auth listos para go-live
  -- Contar tablas CON RLS contra un número fijo se desactualiza cada vez que se agrega una
  -- (eran 17 en julio, hoy son ~49). Lo que importa es que no quede ninguna SIN RLS.
  UNION ALL SELECT 60, '6·SEGURIDAD', 'tablas sin RLS', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END,
                   COALESCE(string_agg(c.relname, ', '), '0')
            FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname='public' AND c.relkind='r' AND NOT c.relrowsecurity
  UNION ALL SELECT 60, '6·SEGURIDAD', 'anon ejecuta funciones', CASE WHEN COUNT(*)=0 THEN 'OK (0)' ELSE '⚠ REVISAR' END, COUNT(*)::text
            FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND has_function_privilege('anon', p.oid, 'EXECUTE')
  UNION ALL SELECT 60, '6·SEGURIDAD', 'anon lee tablas', CASE WHEN COUNT(*)=0 THEN 'OK (0)' ELSE '⚠ REVISAR' END, COUNT(*)::text
            FROM pg_tables t WHERE schemaname='public' AND has_table_privilege('anon', quote_ident(schemaname)||'.'||quote_ident(tablename),'SELECT')
  UNION ALL SELECT 60, '6·SEGURIDAD', 'usuarios auth (>=1 para loguear)', CASE WHEN COUNT(*)>=1 THEN 'OK' ELSE '⚠ FALTA staff (PLAN_MAESTRO.md §3.4 paso 2)' END, COUNT(*)::text
            FROM auth.users

  -- 9) RECORDATORIO manual (no verificable por SQL)
  UNION ALL SELECT 90, '9·MANUAL', 'deshabilitar signup público', 'ⓘ manual',
                   'Dashboard → Auth → deshabilitar "Allow new users to sign up" (PLAN_MAESTRO.md §3.4 paso 1)'
) x
ORDER BY ord, item;
