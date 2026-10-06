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
-- Secciones: 1 conteos · 2 numeración · 3/3b integridad · 3c contabilidad · 4 secuencias
--            · 5/5b totales (Ventas / Compras) · 6 seguridad · 9 recordatorio manual.
-- =============================================================
WITH rc(t, n) AS (
  -- Dinámico a propósito: la lista a mano cubría sólo Ventas (era todo lo que existía en julio) y
  -- una tabla de Compras / Tesorería / Contabilidad que quedara vacía no se notaba. query_to_xml es
  -- la única forma de contar N tablas dentro de un SELECT sin PL/pgSQL.
  SELECT t.table_name,
         (xpath('/row/c/text()', query_to_xml(
            format('SELECT count(*) AS c FROM public.%I', t.table_name), false, true, '')))[1]::text::bigint
  FROM information_schema.tables t
  WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
),
-- seq last_value vs MAX(id): if seq < MAX the next INSERT collides -> re-run
-- PLAN_MAESTRO.md §3.2.5 paso 2. Se resuelven por pg_depend, igual que sql_reset_secuencias.sql:
-- la lista a mano cubría 15 y hoy hay una por cada SERIAL de los cuatro módulos.
seqs(tbl, col, mx, sq) AS (
  SELECT t.relname, a.attname,
         (xpath('/row/c/text()', query_to_xml(
            format('SELECT COALESCE(MAX(%I),0) AS c FROM public.%I', a.attname, t.relname),
            false, true, '')))[1]::text::bigint,
         COALESCE((SELECT sq2.last_value FROM pg_sequences sq2
                    WHERE sq2.schemaname='public' AND sq2.sequencename=s.relname), 0)
  FROM pg_class s
  JOIN pg_depend d    ON d.objid = s.oid AND d.deptype='a'
  JOIN pg_class t     ON t.oid = d.refobjid
  JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
  WHERE s.relkind='S' AND t.relnamespace='public'::regnamespace
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

  -- 3b) INTEGRIDAD — Compras / Tesorería / Contabilidad. §3 cubría sólo Ventas, que era todo lo que
  -- existía en julio. Durante la carga las FK no se validan (session_replication_role = replica),
  -- así que estos checks son la única red: sin ellos el huérfano entra en silencio.
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'facturas_compra_items->facturas_compra', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM facturas_compra_items i LEFT JOIN facturas_compra f ON f.id=i.factura_compra_id WHERE f.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'factura_compra_iva_detalle->facturas_compra', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM factura_compra_iva_detalle d LEFT JOIN facturas_compra f ON f.id=d.factura_compra_id WHERE f.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'nota_compra_items->notas_compra', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM nota_compra_items i LEFT JOIN notas_compra n ON n.id=i.nota_compra_id WHERE n.id IS NULL
  -- Igual que notas->facturas: 20261006130000 dejó factura_compra_id nullable para 3 ND "a cuenta".
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'notas_compra->facturas_compra', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM notas_compra n LEFT JOIN facturas_compra f ON f.id=n.factura_compra_id
            WHERE n.factura_compra_id IS NOT NULL AND f.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'pago_proveedor_facturas->pagos_proveedor', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM pago_proveedor_facturas pf LEFT JOIN pagos_proveedor p ON p.id=pf.pago_proveedor_id WHERE p.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'pago_proveedor_facturas->facturas_compra', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM pago_proveedor_facturas pf LEFT JOIN facturas_compra f ON f.id=pf.factura_compra_id WHERE f.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'pago_proveedor_medios->pagos_proveedor', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM pago_proveedor_medios m LEFT JOIN pagos_proveedor p ON p.id=m.pago_proveedor_id WHERE p.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'pago_proveedor_medios->cheques (terceros)', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM pago_proveedor_medios m LEFT JOIN cheques c ON c.id=m.cheque_id WHERE m.cheque_id IS NOT NULL AND c.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'pago_proveedor_medios->cheques_propios', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM pago_proveedor_medios m LEFT JOIN cheques_propios cp ON cp.id=m.cheque_propio_id WHERE m.cheque_propio_id IS NOT NULL AND cp.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'percepciones_compra->comprobante (XOR)', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM percepciones_compra pc
            LEFT JOIN facturas_compra f ON f.id=pc.factura_compra_id
            LEFT JOIN notas_compra    n ON n.id=pc.nota_compra_id
            WHERE COALESCE(f.id, n.id) IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'comprobantes_compra->proveedores', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM ( SELECT proveedor_id FROM facturas_compra UNION ALL SELECT proveedor_id FROM notas_compra
                   UNION ALL SELECT proveedor_id FROM pagos_proveedor
                 ) q LEFT JOIN proveedores p ON p.id=q.proveedor_id WHERE p.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'movimientos_tesoreria->cuentas_bancarias', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM movimientos_tesoreria m LEFT JOIN cuentas_bancarias cb ON cb.id=m.cuenta_bancaria_id WHERE cb.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'movimientos_tesoreria->tipos_comprobante', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM movimientos_tesoreria m LEFT JOIN tipos_comprobante_tesoreria t ON t.id=m.tipo_comprobante_tesoreria_id
            WHERE m.tipo_comprobante_tesoreria_id IS NOT NULL AND t.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'cheques_propios->cuentas_bancarias', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM cheques_propios cp LEFT JOIN cuentas_bancarias cb ON cb.id=cp.cuenta_bancaria_id WHERE cb.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'asiento_items->asientos_contables', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM asiento_items i LEFT JOIN asientos_contables a ON a.id=i.asiento_id WHERE a.id IS NULL
  UNION ALL SELECT 31, '3b·INTEGRIDAD', 'asiento_items->plan_de_cuentas', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' huérfanos'
            FROM asiento_items i LEFT JOIN plan_de_cuentas c ON c.id=i.cuenta_id WHERE c.id IS NULL

  -- 3c) CONTABILIDAD — ningún asiento descuadrado (H10: Debe = Haber al centavo)
  UNION ALL SELECT 32, '3c·CONTABILIDAD', 'asientos descuadrados', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' asientos'
            FROM ( SELECT asiento_id FROM asiento_items
                   GROUP BY asiento_id HAVING round(SUM(debe)-SUM(haber),2) <> 0 ) q
  UNION ALL SELECT 32, '3c·CONTABILIDAD', 'asientos sin renglones', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE 'ⓘ revisar' END, COUNT(*)::text||' asientos'
            FROM asientos_contables a WHERE NOT EXISTS (SELECT 1 FROM asiento_items i WHERE i.asiento_id = a.id)

  -- 4) SECUENCIAS — cada SERIAL >= MAX(id) o la próxima alta colisiona
  UNION ALL SELECT 40, '4·SECUENCIAS', tbl||'.'||col, CASE WHEN sq < mx THEN '⚠ REVISAR' ELSE 'OK' END,
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

  -- 5b) TOTALES DE COMPRAS — invariantes exactas de la carga de Tango.
  -- 30_compras.sql carga `total` = CPA04.IMPORTE_TO (ya incluye las percepciones) y recién
  -- 31_percepciones_compra.sql reparte ese total en `percepciones_monto`: estos checks cierran con
  -- los dos .sql cargados, en ese orden. Si 31_ no corrió, el primero da ⚠ y esa es la señal.
  UNION ALL SELECT 51, '5b·TOTALES COMPRAS', 'facturas_compra total = neto+iva+percep', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM facturas_compra WHERE round(neto_gravado+iva_monto+COALESCE(percepciones_monto,0),2) <> total
  UNION ALL SELECT 51, '5b·TOTALES COMPRAS', 'notas_compra total = neto+iva+percep', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM notas_compra WHERE round(neto_gravado+iva_monto+COALESCE(percepciones_monto,0),2) <> total
  UNION ALL SELECT 51, '5b·TOTALES COMPRAS', 'facturas_compra percep = suma detalle', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM facturas_compra fc WHERE COALESCE(fc.percepciones_monto,0)
                 <> COALESCE((SELECT round(SUM(pc.monto),2) FROM percepciones_compra pc WHERE pc.factura_compra_id=fc.id),0)
  UNION ALL SELECT 51, '5b·TOTALES COMPRAS', 'notas_compra percep = suma detalle', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM notas_compra nc WHERE COALESCE(nc.percepciones_monto,0)
                 <> COALESCE((SELECT round(SUM(pc.monto),2) FROM percepciones_compra pc WHERE pc.nota_compra_id=nc.id),0)
  -- Exactas por construcción del ETL: desglose() ajusta la alícuota mayor para que los netos del
  -- detalle sumen IMPORTE_NE + IMPORTE_EX, y el iva_monto de la cabecera ES la suma del detalle.
  UNION ALL SELECT 51, '5b·TOTALES COMPRAS', 'facturas_compra neto = suma iva_detalle', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM facturas_compra fc WHERE fc.neto_gravado
                 <> COALESCE((SELECT round(SUM(d.neto_gravado),2) FROM factura_compra_iva_detalle d WHERE d.factura_compra_id=fc.id),0)
  UNION ALL SELECT 51, '5b·TOTALES COMPRAS', 'facturas_compra iva = suma iva_detalle', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM facturas_compra fc WHERE fc.iva_monto
                 <> COALESCE((SELECT round(SUM(d.iva_monto),2) FROM factura_compra_iva_detalle d WHERE d.factura_compra_id=fc.id),0)
  -- H13: el crédito fiscal no puede traer percepción adentro. Un slot COD_IVA 3 / 4 que se colara en
  -- factura_compra_iva_detalle infla el IVA por encima del 27% y se delata acá.
  UNION ALL SELECT 51, '5b·TOTALES COMPRAS', 'facturas_compra IVA en banda 0-27%', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM facturas_compra WHERE iva_monto < 0 OR iva_monto > round(neto_gravado*0.27,2)+0.01
  -- Control de aceptación de la Tarea 7 (etl/controles_compras.py: 0 diferencias sobre el .bak del 25/09).
  UNION ALL SELECT 51, '5b·TOTALES COMPRAS', 'pagos_proveedor total = suma medios', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)::text||' filas mal'
            FROM pagos_proveedor pp WHERE pp.total
                 <> COALESCE((SELECT round(SUM(m.monto),2) FROM pago_proveedor_medios m WHERE m.pago_proveedor_id=pp.id),0)
  UNION ALL SELECT 51, '5b·TOTALES COMPRAS', 'percepciones_compra con monto 0', CASE WHEN COUNT(*)=0 THEN 'OK' ELSE 'ⓘ revisar' END, COUNT(*)::text||' filas'
            FROM percepciones_compra WHERE monto = 0
  UNION ALL SELECT 51, '5b·TOTALES COMPRAS', 'percepciones por tipo (info)', 'INFO',
                   COALESCE(string_agg(t.tipo||': '||t.n::text, ' · ' ORDER BY t.tipo), 'sin percepciones')
            FROM (SELECT tipo, COUNT(*) AS n FROM percepciones_compra GROUP BY tipo) t

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
