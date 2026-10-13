-- =============================================================
-- CRM Ventas — POST-LOAD VERIFICATION (run AFTER the load + sequence reset — PLAN_MAESTRO.md §3.2.5)
-- Where: Supabase SQL Editor, or  psql "$SUPABASE_DB_URL" -f supabase/POST_LOAD_VERIFY.sql
-- Read-only. Every check prints a `check` label + a `status` (OK / ⚠ REVISAR) where it can
-- self-judge; the row-count block you compare by eye against the LAN DB.
-- =============================================================

\echo '=== 1) ROW COUNTS — todas las tablas de public (compará contra la LAN; si la carga vino de Tango, contra supabase/tango/sql_conteos.sql, que trae el esperado al lado) ==='
-- Dinámico a propósito: la lista a mano cubría sólo Ventas (era todo lo que existía en julio) y una
-- tabla de Compras / Tesorería / Contabilidad que quedara vacía no se notaba. query_to_xml es la
-- única forma de contar N tablas dentro de un SELECT sin PL/pgSQL, así que esto corre igual acá y
-- en la edición MCP.
SELECT t.table_name AS tabla,
       (xpath('/row/c/text()', query_to_xml(
          format('SELECT count(*) AS c FROM public.%I', t.table_name), false, true, '')))[1]::text::bigint AS filas
FROM information_schema.tables t
WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
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
-- `factura_id IS NOT NULL AND` es obligatorio: D2 (20261006120000) dejó `notas.factura_id` nullable
-- para las 30 NC/ND que Tango tiene "a cuenta" o anuladas sin imputar. Sin ese filtro, esas 30 se
-- contaban como huérfanas y el check daba ⚠ sobre datos correctos.
UNION ALL SELECT 'notas->facturas',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM notas n LEFT JOIN facturas f ON f.id=n.factura_id
  WHERE n.factura_id IS NOT NULL AND f.id IS NULL
UNION ALL SELECT 'notas->clientes (H22: toda nota tiene cliente)',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM notas n LEFT JOIN clientes c ON c.id=n.cliente_id WHERE c.id IS NULL
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
\echo '=== 3b) INTEGRIDAD REFERENCIAL — Compras / Tesorería / Contabilidad (0 huérfanos esperado) ==='
-- Agregado para la Tarea 10 del cutover: §3 sólo cubría Ventas, que era todo lo que existía en
-- julio. Las FK no se validan durante la carga (session_replication_role = replica), así que estos
-- checks son la única red: si falta uno, el huérfano entra en silencio.
SELECT 'facturas_compra_items->facturas_compra' AS check,
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END AS status, COUNT(*) AS huerfanos
  FROM facturas_compra_items i LEFT JOIN facturas_compra f ON f.id=i.factura_compra_id WHERE f.id IS NULL
UNION ALL SELECT 'factura_compra_iva_detalle->facturas_compra',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM factura_compra_iva_detalle d LEFT JOIN facturas_compra f ON f.id=d.factura_compra_id WHERE f.id IS NULL
UNION ALL SELECT 'nota_compra_items->notas_compra',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM nota_compra_items i LEFT JOIN notas_compra n ON n.id=i.nota_compra_id WHERE n.id IS NULL
-- Igual que notas->facturas: 20261006130000 dejó factura_compra_id nullable para 3 ND "a cuenta".
UNION ALL SELECT 'notas_compra->facturas_compra',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM notas_compra n LEFT JOIN facturas_compra f ON f.id=n.factura_compra_id
  WHERE n.factura_compra_id IS NOT NULL AND f.id IS NULL
UNION ALL SELECT 'pago_proveedor_facturas->pagos_proveedor',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM pago_proveedor_facturas pf LEFT JOIN pagos_proveedor p ON p.id=pf.pago_proveedor_id WHERE p.id IS NULL
UNION ALL SELECT 'pago_proveedor_facturas->facturas_compra',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM pago_proveedor_facturas pf LEFT JOIN facturas_compra f ON f.id=pf.factura_compra_id WHERE f.id IS NULL
UNION ALL SELECT 'pago_proveedor_medios->pagos_proveedor',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM pago_proveedor_medios m LEFT JOIN pagos_proveedor p ON p.id=m.pago_proveedor_id WHERE p.id IS NULL
UNION ALL SELECT 'pago_proveedor_medios->cheques (terceros)',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM pago_proveedor_medios m LEFT JOIN cheques c ON c.id=m.cheque_id
  WHERE m.cheque_id IS NOT NULL AND c.id IS NULL
UNION ALL SELECT 'pago_proveedor_medios->cheques_propios',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM pago_proveedor_medios m LEFT JOIN cheques_propios cp ON cp.id=m.cheque_propio_id
  WHERE m.cheque_propio_id IS NOT NULL AND cp.id IS NULL
UNION ALL SELECT 'percepciones_compra->comprobante (XOR)',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM percepciones_compra pc
  LEFT JOIN facturas_compra f ON f.id=pc.factura_compra_id
  LEFT JOIN notas_compra    n ON n.id=pc.nota_compra_id
  WHERE COALESCE(f.id, n.id) IS NULL
UNION ALL SELECT 'comprobantes_compra->proveedores',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM (SELECT proveedor_id FROM facturas_compra UNION ALL SELECT proveedor_id FROM notas_compra
        UNION ALL SELECT proveedor_id FROM pagos_proveedor) q
  LEFT JOIN proveedores p ON p.id=q.proveedor_id WHERE p.id IS NULL
UNION ALL SELECT 'movimientos_tesoreria->cuentas_bancarias',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM movimientos_tesoreria m LEFT JOIN cuentas_bancarias cb ON cb.id=m.cuenta_bancaria_id WHERE cb.id IS NULL
UNION ALL SELECT 'movimientos_tesoreria->tipos_comprobante',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM movimientos_tesoreria m
  LEFT JOIN tipos_comprobante_tesoreria t ON t.id=m.tipo_comprobante_tesoreria_id
  WHERE m.tipo_comprobante_tesoreria_id IS NOT NULL AND t.id IS NULL
UNION ALL SELECT 'cheques_propios->cuentas_bancarias',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM cheques_propios cp LEFT JOIN cuentas_bancarias cb ON cb.id=cp.cuenta_bancaria_id WHERE cb.id IS NULL
UNION ALL SELECT 'asiento_items->asientos_contables',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM asiento_items i LEFT JOIN asientos_contables a ON a.id=i.asiento_id WHERE a.id IS NULL
UNION ALL SELECT 'asiento_items->plan_de_cuentas',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM asiento_items i LEFT JOIN plan_de_cuentas c ON c.id=i.cuenta_id WHERE c.id IS NULL
ORDER BY check;

\echo ''
\echo '=== 3c) CONTABILIDAD — ningún asiento descuadrado (H10: Debe = Haber al centavo) ==='
SELECT 'asientos_descuadrados' AS check,
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END AS status, COUNT(*) AS asientos
  FROM (SELECT asiento_id FROM asiento_items
        GROUP BY asiento_id HAVING round(SUM(debe)-SUM(haber),2) <> 0) q
UNION ALL
SELECT 'asientos_sin_renglones',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE 'ⓘ revisar' END, COUNT(*)
  FROM asientos_contables a
  WHERE NOT EXISTS (SELECT 1 FROM asiento_items i WHERE i.asiento_id = a.id);

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
\echo '=== 5) TOTALES — invariantes exactas de importación (multi-alícuota + percepciones) ==='
-- Ya no se valida "IVA = 21%" (multi-alícuota 20260802120000 admite 0/10,5/21/27%) ni se re-deriva
-- el IVA desde los ítems (habría que replicar crm_calc_totales_multi_alicuota y desincronizarse).
-- Mismos checks que POST_LOAD_VERIFY_MCP.sql §5 y §5b — mantener las dos ediciones en sync.
SELECT 'facturas_total_neto_iva_percep' AS check,
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END AS status, COUNT(*) AS filas_mal
  FROM facturas WHERE round(neto_gravado+iva_monto+COALESCE(percepciones_monto,0),2) <> total
UNION ALL
SELECT 'notas_total_neto_iva_percep',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM notas WHERE round(neto_gravado+iva_monto+COALESCE(percepciones_monto,0),2) <> total
UNION ALL
SELECT 'facturas_percep_vs_detalle',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM facturas f WHERE COALESCE(f.percepciones_monto,0)
       <> COALESCE((SELECT round(SUM(p.monto),2) FROM percepciones p WHERE p.factura_id=f.id),0)
UNION ALL
SELECT 'facturas_iva_en_banda_0_27',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM facturas WHERE iva_monto < 0 OR iva_monto > round(neto_gravado*0.27,2)+0.01;

\echo ''
\echo '=== 5b) TOTALES DE COMPRAS — invariantes exactas de la carga de Tango ==='
-- 30_compras.sql carga `total` = CPA04.IMPORTE_TO (que ya incluye las percepciones) y recién
-- 31_percepciones_compra.sql reparte ese total en `percepciones_monto`. O sea: estos checks sólo
-- cierran con los dos .sql cargados, en ese orden — si 31_ no corrió, el primero da ⚠ y esa es
-- justamente la señal. Las dos invariantes contra el detalle son exactas por construcción del ETL
-- (`desglose()` ajusta la alícuota mayor para que los netos del detalle sumen IMPORTE_NE+IMPORTE_EX).
SELECT 'facturas_compra_total_neto_iva_percep' AS check,
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END AS status, COUNT(*) AS filas_mal
  FROM facturas_compra WHERE round(neto_gravado+iva_monto+COALESCE(percepciones_monto,0),2) <> total
UNION ALL
SELECT 'notas_compra_total_neto_iva_percep',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM notas_compra WHERE round(neto_gravado+iva_monto+COALESCE(percepciones_monto,0),2) <> total
UNION ALL
SELECT 'facturas_compra_percep_vs_detalle',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM facturas_compra fc WHERE COALESCE(fc.percepciones_monto,0)
       <> COALESCE((SELECT round(SUM(pc.monto),2) FROM percepciones_compra pc
                     WHERE pc.factura_compra_id=fc.id),0)
UNION ALL
SELECT 'notas_compra_percep_vs_detalle',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM notas_compra nc WHERE COALESCE(nc.percepciones_monto,0)
       <> COALESCE((SELECT round(SUM(pc.monto),2) FROM percepciones_compra pc
                     WHERE pc.nota_compra_id=nc.id),0)
UNION ALL
SELECT 'facturas_compra_neto_vs_iva_detalle',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM facturas_compra fc WHERE fc.neto_gravado
       <> COALESCE((SELECT round(SUM(d.neto_gravado),2) FROM factura_compra_iva_detalle d
                     WHERE d.factura_compra_id=fc.id),0)
UNION ALL
SELECT 'facturas_compra_iva_vs_iva_detalle',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM facturas_compra fc WHERE fc.iva_monto
       <> COALESCE((SELECT round(SUM(d.iva_monto),2) FROM factura_compra_iva_detalle d
                     WHERE d.factura_compra_id=fc.id),0)
UNION ALL
-- H13: el crédito fiscal no puede traer percepción adentro. Un slot COD_IVA 3 / 4 que se colara en
-- factura_compra_iva_detalle infla el IVA por encima del 27 % y se delata acá.
SELECT 'facturas_compra_iva_en_banda_0_27',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM facturas_compra WHERE iva_monto < 0 OR iva_monto > round(neto_gravado*0.27,2)+0.01
UNION ALL
-- Control de aceptación de la Tarea 7 (etl/controles_compras.py: 0 diferencias sobre el .bak del 25/09).
SELECT 'pagos_proveedor_total_vs_medios',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END, COUNT(*)
  FROM pagos_proveedor pp WHERE pp.total
       <> COALESCE((SELECT round(SUM(m.monto),2) FROM pago_proveedor_medios m
                     WHERE m.pago_proveedor_id=pp.id),0)
UNION ALL
-- Una percepción sin tipo válido no entra (CHECK), pero una con monto 0 es carga a medias.
SELECT 'percepciones_compra_con_monto_0',
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE 'ⓘ revisar' END, COUNT(*)
  FROM percepciones_compra WHERE monto = 0
ORDER BY check;

\echo ''
\echo '=== 6) SEGURIDAD — RLS/anon/auth listos para go-live ==='
-- Contra un número fijo se desactualiza con cada tabla nueva (eran 17 en julio, hoy ~49);
-- lo que importa es que no quede ninguna SIN RLS.
SELECT 'tablas_sin_rls' AS check,
       CASE WHEN COUNT(*)=0 THEN 'OK' ELSE '⚠ REVISAR' END AS status, COUNT(*) AS n
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind='r' AND NOT c.relrowsecurity
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
