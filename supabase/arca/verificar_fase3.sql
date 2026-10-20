-- =============================================================
-- PLAN_ARCA — verificación de la Fase 3 en la base (borradores, efectos al autorizar, saldos e
-- informes, reconciliación) en HOMOLOGACIÓN. La parte contra ARCA (CAE reales) se prueba aparte,
-- llamando a la Edge Function.
--
-- Uso (nunca contra prod), con 20261015130000 y 20261015140000 ya aplicadas:
--   psql "$(cat ~/.arca/marblock/homo_db_url)" -X -f supabase/arca/verificar_fase3.sql
--
-- Corre todo en una transacción y termina con ROLLBACK: no deja nada en la base. Cada control
-- imprime "OK …"; el primero que falla corta con "FALLA …". Usa los datos sintéticos de
-- homologación (ver verificar_fase2.sql): el cliente RI 30710000014 con su FAC A histórica sin CAE
-- y la que tiene CAE, y el consumidor con DNI 28123456.
-- =============================================================
\set ON_ERROR_STOP 1
\set QUIET 1
SET client_min_messages = notice;
BEGIN;

CREATE FUNCTION pg_temp.ok(c boolean, m text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF c IS TRUE THEN RAISE NOTICE 'OK    %', m; ELSE RAISE EXCEPTION 'FALLA %', m; END IF;
END $$;

-- Ejecuta p_sql (un SELECT que devuelve un valor jsonb) con el rol dado.
CREATE FUNCTION pg_temp.como(p_rol text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  EXECUTE p_sql INTO r;
  RESET ROLE;
  RETURN r;
END $$;

CREATE FUNCTION pg_temp.falla(p_rol text, p_sql text, p_patron text, m text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    PERFORM pg_temp.como(p_rol, p_sql);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ~* p_patron THEN
      RAISE NOTICE 'OK    % → %', m, SQLERRM;
      RETURN;
    END IF;
    RAISE EXCEPTION 'FALLA % — error inesperado: %', m, SQLERRM;
  END;
  RAISE EXCEPTION 'FALLA % — no falló', m;
END $$;

CREATE FUNCTION pg_temp.cli(p_nro text) RETURNS int LANGUAGE sql AS $$
  SELECT id FROM clientes WHERE doc_nro = p_nro $$;
CREATE FUNCTION pg_temp.fac_hist() RETURNS int LANGUAGE sql AS $$
  SELECT min(f.id) FROM facturas f JOIN clientes c ON c.id = f.cliente_id
  WHERE c.doc_nro = '30710000014' AND f.tipo = 'A' AND f.estado_fiscal = 'historico' $$;
CREATE FUNCTION pg_temp.fac_cae() RETURNS int LANGUAGE sql AS $$
  SELECT min(id) FROM facturas WHERE estado_fiscal = 'autorizado' AND cae IS NOT NULL $$;
CREATE FUNCTION pg_temp.hoy() RETURNS date LANGUAGE sql AS $$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date $$;

-- Factura nueva por la RPC, como la llama el frontend (authenticated).
CREATE FUNCTION pg_temp.factura(p_cli int, p_items text, p_tipo text,
                                p_remitos int[] DEFAULT NULL, p_presupuesto int DEFAULT NULL) RETURNS int
LANGUAGE plpgsql AS $$
BEGIN
  RETURN (pg_temp.como('authenticated', format(
    $q$SELECT to_jsonb(crear_factura(%s, %L::jsonb, %L, 0, %L::int[], %s))$q$,
    p_cli, p_items, p_tipo, p_remitos, COALESCE(p_presupuesto::text, 'NULL')))->>'id')::int;
END $$;

-- Todo lo que suma facturas para el cliente: un borrador no tiene que mover nada de esto. Las listas
-- se comparan por id: varios informes ordenan sólo por fecha y el orden entre facturas del mismo día
-- no es fijo.
CREATE FUNCTION pg_temp.foto(p_cli int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'saldo_cli',     (SELECT x->'saldo_pendiente' FROM clientes_list() x WHERE (x->>'id')::int = p_cli),
    'facturado_cli', (SELECT x->'total_facturado' FROM clientes_list() x WHERE (x->>'id')::int = p_cli),
    'cta_cte',       informe_cta_cte(p_cli)->'saldo_total',
    'cta_cte_movs',  jsonb_array_length(informe_cta_cte(p_cli)->'movimientos'),
    'por_cobrar',    informe_dashboard()->'kpis'->'total_por_cobrar',
    'ultimas',       informe_dashboard()->'ultimas_facturas',
    'ventas',        informe_ventas(pg_temp.hoy() - 30, pg_temp.hoy() + 1)->'totales',
    'libro_iva',     informe_libro_iva_ventas(pg_temp.hoy() - 30, pg_temp.hoy() + 1)->'totales',
    'deudores',      (SELECT jsonb_agg(x ORDER BY (x->>'id')::int) FROM informe_ranking_deudores() x),
    'ranking',       (SELECT jsonb_agg(x ORDER BY (x->>'id')::int) FROM informe_ranking_clientes() x),
    'pend_remitir',  (SELECT jsonb_agg(x->'id' ORDER BY (x->>'id')::int) FROM informe_facturas_pendientes_remitir() x),
    'sin_remito',    (SELECT jsonb_agg(x->'id' ORDER BY (x->>'id')::int) FROM facturas_list(p_solo_sin_remito => true) x),
    'pendientes',    (SELECT jsonb_agg(x->'id' ORDER BY (x->>'id')::int) FROM facturas_list(p_estado => 'pendiente', p_cliente_id => p_cli) x)
  ) $$;

-- Claves de la foto que cambiaron (vacío si ninguna): para que una falla diga qué se movió.
CREATE FUNCTION pg_temp.cambios(a jsonb, b jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(k, ', ' ORDER BY k), '') FROM jsonb_object_keys(a) k
  WHERE a->k IS DISTINCT FROM b->k $$;

CREATE TEMP TABLE ids (nombre text PRIMARY KEY, id int);

\echo '── 1) Totales: neto = suma de las bases por alícuota'
DO $$
DECLARE
  t    jsonb;
  v105 int := (SELECT id FROM alicuotas_iva WHERE porcentaje = 10.5);
BEGIN
  t := crm_calc_totales_multi_alicuota(format(
    '[{"cantidad":1,"precio_unitario":10.005},{"cantidad":1,"precio_unitario":10.005,"alicuota_iva_id":%s}]', v105)::jsonb, 0);
  PERFORM pg_temp.ok((t->>'neto_gravado')::numeric = 20.02 AND (t->>'iva_monto')::numeric = 3.15
    AND (t->>'total')::numeric = 23.17
    AND (SELECT sum((d->>'neto_gravado')::numeric) FROM jsonb_array_elements(t->'detalle') d) = 20.02,
    'dos alícuotas: neto 20,02 = suma de las bases redondeadas (antes 20,01) y total = neto + IVA');

  t := crm_calc_totales_multi_alicuota('[{"cantidad":3,"precio_unitario":1234.567}]', 7.5);
  PERFORM pg_temp.ok((t->>'subtotal')::numeric = 3703.70 AND (t->>'descuento_monto')::numeric = 277.78
    AND (t->>'neto_gravado')::numeric = 3425.92 AND (t->>'iva_monto')::numeric = 719.44
    AND (t->>'total')::numeric = 4145.36,
    'una alícuota con descuento: mismos importes que antes (neto 3425,92, IVA 719,44, total 4145,36)');
END $$;

\echo '── 2) crear_factura → borrador, fuera de saldos e informes'
DO $$
DECLARE
  cli  int := pg_temp.cli('30710000014');
  base jsonb := pg_temp.foto(cli);
  ctr  int  := (SELECT ultimo_numero FROM contadores WHERE tipo = 'factura_a');
  b    int;
  f    jsonb;
BEGIN
  b := pg_temp.factura(cli, '[{"descripcion":"bloque","cantidad":10,"precio_unitario":1000}]', 'A');
  INSERT INTO ids VALUES ('borrador', b);
  f := pg_temp.como('authenticated', format('SELECT x FROM facturas_list(p_id => %s) x', b));
  PERFORM pg_temp.ok(f->>'estado_fiscal' = 'borrador' AND f->>'numero' IS NULL AND f->>'punto_venta' IS NULL
    AND f->>'numero_comp' IS NULL AND f->>'estado' = 'pendiente' AND (f->>'fecha')::date = pg_temp.hoy()
    AND (f->>'total')::numeric = 12100,
    'nace borrador, sin número, con la fecha de hoy en Argentina y total 12.100');
  PERFORM pg_temp.ok((SELECT ultimo_numero FROM contadores WHERE tipo = 'factura_a') = ctr,
    'no consume el contador factura_a');
  PERFORM pg_temp.ok(pg_temp.cambios(pg_temp.foto(cli), base) = '',
    'no cambia saldo ni facturado del cliente, cta. cte., dashboard, informe de ventas, libro IVA, rankings ni pendientes'
    || COALESCE(NULLIF(' [cambió: ' || pg_temp.cambios(pg_temp.foto(cli), base) || ']', ' [cambió: ]'), ''));
  PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM facturas_list(p_cliente_id => cli) x WHERE (x->>'id')::int = b),
    'facturas_list sin filtro de estado sí lo muestra');
END $$;

\echo '── 3) Cobros: sólo sobre facturas fiscales'
DO $$
DECLARE
  cli int := pg_temp.cli('30710000014');
  b   int := (SELECT ids.id FROM ids WHERE nombre = 'borrador');
BEGIN
  PERFORM pg_temp.falla('authenticated', format(
    $q$SELECT to_jsonb(crear_recibo(%s, '[{"tipo":"efectivo","monto":100}]', '[%s]'))$q$, cli, b),
    'todavía no tiene CAE', 'un recibo no imputa un borrador');
  PERFORM pg_temp.como('authenticated', format(
    $q$SELECT to_jsonb(crear_recibo(%s, '[{"tipo":"efectivo","monto":100}]', '[%s]'))$q$, cli, pg_temp.fac_hist()));
  PERFORM pg_temp.ok((SELECT estado = 'parcial' FROM facturas WHERE id = pg_temp.fac_hist()),
    'un recibo sí imputa una factura histórica (queda parcial)');
END $$;

\echo '── 4) Edición, anulación y descarte según el estado fiscal'
DO $$
DECLARE
  cli int := pg_temp.cli('30710000014');
  b   int := (SELECT ids.id FROM ids WHERE nombre = 'borrador');
  f   jsonb;
  items text := '[{"descripcion":"bloque","cantidad":5,"precio_unitario":1000}]';
BEGIN
  f := pg_temp.como('authenticated', format($q$SELECT to_jsonb(actualizar_factura(%s, %s, %L))$q$, b, cli, items));
  PERFORM pg_temp.ok(f->>'estado_fiscal' = 'borrador' AND (f->>'total')::numeric = 6050, 'un borrador se edita');

  UPDATE facturas SET estado_fiscal = 'rechazado' WHERE id = b;
  f := pg_temp.como('authenticated', format($q$SELECT to_jsonb(actualizar_factura(%s, %s, %L))$q$, b, cli, items));
  PERFORM pg_temp.ok(f->>'estado_fiscal' = 'borrador', 'un rechazado se edita y vuelve a borrador');

  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, b));
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(actualizar_factura(%s, %s, %L))$q$, b, cli, items),
    'se está emitiendo', 'no se edita en emisión');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT null::jsonb FROM factura_borrador_descartar(%s)$q$, b),
    'se está emitiendo', 'no se descarta en emisión');
  PERFORM pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_error_previo('facturas', %s, 'prueba'))$q$, b));

  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(actualizar_factura(%s, %s, %L))$q$, pg_temp.fac_cae(), cli, items),
    'ya tiene CAE', 'una factura autorizada no se edita');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(actualizar_factura(%s, %s, %L))$q$, pg_temp.fac_hist(), cli, items),
    'histórico', 'una factura histórica no se edita');

  PERFORM pg_temp.falla('authenticated', format('SELECT to_jsonb(factura_anular(%s))', b),
    'descartá el borrador', 'un borrador no se anula');
  PERFORM pg_temp.falla('authenticated', format('SELECT to_jsonb(factura_anular(%s))', pg_temp.fac_cae()),
    'Nota de Crédito', 'una factura autorizada no se anula');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT null::jsonb FROM factura_borrador_descartar(%s)$q$, pg_temp.fac_cae()),
    'ya tiene CAE', 'una factura autorizada no se descarta');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT null::jsonb FROM factura_borrador_descartar(%s)$q$, pg_temp.fac_hist()),
    'histórico', 'una factura histórica no se descarta');
END $$;

\echo '── 5) Remito y presupuesto tomados por un borrador'
DO $$
DECLARE
  cli   int := pg_temp.cli('30710000014');
  items text := '[{"descripcion":"bloque","cantidad":2,"precio_unitario":1000}]';
  r     int;
  p     int;
  f     int;
BEGIN
  r := (pg_temp.como('authenticated', format($q$SELECT to_jsonb(crear_remito(%s, '00009-00000001', %L))$q$, cli, items))->>'id')::int;
  p := (pg_temp.como('authenticated', format($q$SELECT to_jsonb(crear_presupuesto(%s, %L))$q$, cli, items))->>'id')::int;
  f := pg_temp.factura(cli, items, 'A', ARRAY[r], p);
  INSERT INTO ids VALUES ('con_remito', f), ('remito', r), ('presupuesto', p);

  PERFORM pg_temp.ok((SELECT estado = 'pendiente' AND factura_id = f FROM remitos WHERE id = r),
    'el remito queda pendiente, vinculado al borrador');
  PERFORM pg_temp.ok((SELECT estado <> 'convertido' FROM presupuestos WHERE id = p),
    'el presupuesto no pasa a convertido');
  PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM informe_remitos_pendientes_facturar() x WHERE (x->>'id')::int = r),
    'el remito sigue en "pendientes de facturar" hasta el CAE');

  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_factura(%s, %L, 'A', 0, ARRAY[%s]))$q$, cli, items, r),
    'ya está en otra factura sin emitir', 'el mismo remito no entra en otro borrador');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_factura(%s, %L, 'A', 0, NULL, %s))$q$, cli, items, p),
    'presupuesto ya está en otra factura sin emitir', 'el mismo presupuesto no entra en otro borrador');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(actualizar_remito(%s, %s, %L))$q$, r, cli, items),
    'factura sin emitir', 'un remito tomado por un borrador no se edita');
  PERFORM pg_temp.falla('authenticated', format('SELECT to_jsonb(remito_anular(%s))', r),
    'factura sin emitir', 'un remito tomado por un borrador no se anula');
END $$;

\echo '── 6) Al autorizar, los efectos se aplican una sola vez'
DO $$
DECLARE
  cli  int := pg_temp.cli('30710000014');
  f    int := (SELECT id FROM ids WHERE nombre = 'con_remito');
  r    int := (SELECT id FROM ids WHERE nombre = 'remito');
  p    int := (SELECT id FROM ids WHERE nombre = 'presupuesto');
  base jsonb := pg_temp.foto(cli);
  tot  numeric := (SELECT total FROM facturas WHERE id = f);
  req  jsonb := '{"FeCabReq":{"CantReg":1},"FECAEDetRequest":{}}';
  v    jsonb;
  -- Un número que no usó ninguna emisión real de homologación.
  nro  int := (SELECT COALESCE(max(numero_comp), 0) + 1000 FROM facturas WHERE tipo = 'A' AND punto_venta = '00001');
  num  text := '00001-' || lpad(((SELECT COALESCE(max(numero_comp), 0) + 1000 FROM facturas WHERE tipo = 'A' AND punto_venta = '00001'))::text, 8, '0');
BEGIN
  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, f));
  PERFORM pg_temp.como('service_role', format($q$SELECT null::jsonb FROM arca_reservar_numero('facturas', %s, %s)$q$, f, nro));
  v := pg_temp.como('service_role', format(
    $q$SELECT arca_registrar_cae('facturas', %s, %s, '75000000000001', CURRENT_DATE + 10, 1, 80, '30710000014', %L, '{"Resultado":"A"}')$q$, f, nro, req));
  PERFORM pg_temp.ok((v->>'registrado')::boolean
    AND (SELECT estado_fiscal = 'autorizado' AND numero = num FROM facturas WHERE id = f),
    'autorizada con el número que dio ARCA');
  PERFORM pg_temp.ok((SELECT estado = 'facturado' FROM remitos WHERE id = r)
    AND (SELECT estado = 'convertido' FROM presupuestos WHERE id = p),
    'el remito pasa a facturado y el presupuesto a convertido');
  PERFORM pg_temp.ok(
    (pg_temp.foto(cli)->>'saldo_cli')::numeric = (base->>'saldo_cli')::numeric + tot
    AND (pg_temp.foto(cli)->>'cta_cte')::numeric = (base->>'cta_cte')::numeric + tot
    AND (pg_temp.foto(cli)->>'por_cobrar')::numeric = (base->>'por_cobrar')::numeric + tot
    AND (pg_temp.foto(cli)->'libro_iva'->>'cantidad')::int = (base->'libro_iva'->>'cantidad')::int + 1,
    'recién ahora suma al saldo del cliente, la cta. cte., el dashboard y el libro IVA');

  v := pg_temp.como('service_role', format(
    $q$SELECT arca_registrar_cae('facturas', %s, %s, '75000000000001', CURRENT_DATE + 10, 1, 80, '30710000014', %L, '{"Resultado":"A"}')$q$, f, nro, req));
  PERFORM pg_temp.ok((v->>'registrado')::boolean
    AND (pg_temp.foto(cli)->>'saldo_cli')::numeric = (base->>'saldo_cli')::numeric + tot,
    'registrar el mismo CAE otra vez no duplica nada');
END $$;

\echo '── 7) Descartar un borrador libera su remito'
DO $$
DECLARE
  cli   int := pg_temp.cli('30710000014');
  items text := '[{"descripcion":"bloque","cantidad":1,"precio_unitario":1000}]';
  r     int;
  f     int;
BEGIN
  r := (pg_temp.como('authenticated', format($q$SELECT to_jsonb(crear_remito(%s, '00009-00000002', %L))$q$, cli, items))->>'id')::int;
  f := pg_temp.factura(cli, items, 'A', ARRAY[r]);
  UPDATE facturas SET estado_fiscal = 'rechazado' WHERE id = f;
  PERFORM pg_temp.como('authenticated', format($q$SELECT null::jsonb FROM factura_borrador_descartar(%s)$q$, f));
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM facturas WHERE id = f)
    AND NOT EXISTS (SELECT 1 FROM factura_items WHERE factura_id = f)
    AND (SELECT estado = 'pendiente' AND factura_id IS NULL FROM remitos WHERE id = r),
    'un rechazado se descarta: se borra con sus ítems y el remito queda libre');
  PERFORM pg_temp.como('authenticated', format($q$SELECT to_jsonb(actualizar_remito(%s, %s, %L))$q$, r, cli, items));
  PERFORM pg_temp.ok(true, 'el remito liberado se vuelve a editar');
END $$;

\echo '── 8) Una NC sin CAE no resta del saldo'
DO $$
DECLARE
  cli  int := pg_temp.cli('30710000014');
  fh   int := pg_temp.fac_hist();
  base jsonb;
  est  text;
  nc   int;
BEGIN
  PERFORM recalcular_estado_factura(fh);
  base := pg_temp.foto(cli);
  est  := (SELECT estado FROM facturas WHERE id = fh);
  INSERT INTO notas (tipo, tipo_letra, fecha, factura_id, cliente_id, neto_gravado, iva_monto, total, estado_fiscal)
  VALUES ('NC', 'A', pg_temp.hoy(), fh, cli, 100000, 21000, 121000, 'borrador')
  RETURNING id INTO nc;
  PERFORM recalcular_estado_factura(fh);
  PERFORM pg_temp.ok((SELECT estado FROM facturas WHERE id = fh) = est AND pg_temp.cambios(pg_temp.foto(cli), base) = '',
    'una NC borrador por el total no cobra la factura ni cambia saldos, cta. cte., dashboard ni libro IVA'
    || COALESCE(NULLIF(' [cambió: ' || pg_temp.cambios(pg_temp.foto(cli), base) || ']', ' [cambió: ]'), ''));
  -- Desde la Fase 4, factura_anular no anula una factura con notas sin CAE (sección 11).
  DELETE FROM notas WHERE id = nc;
END $$;

\echo '── 9) Asiento automático: un borrador no genera asiento'
DO $$
DECLARE f int;
BEGIN
  UPDATE config_empresa SET valor = 'on' WHERE clave = 'contabilidad_auto_asientos';
  IF NOT FOUND THEN
    INSERT INTO config_empresa (clave, valor) VALUES ('contabilidad_auto_asientos', 'on');
  END IF;
  f := pg_temp.factura(pg_temp.cli('30710000014'), '[{"descripcion":"bloque","cantidad":1,"precio_unitario":10}]', 'A');
  SET CONSTRAINTS trg_asiento_auto_factura IMMEDIATE;
  PERFORM pg_temp.ok(NOT asiento_existe_para('facturas', f), 'con el flag prendido, el borrador no genera asiento');
  SET CONSTRAINTS trg_asiento_auto_factura DEFERRED;
  UPDATE config_empresa SET valor = 'off' WHERE clave = 'contabilidad_auto_asientos';
END $$;

\echo '── 10) arca_para_reconciliar'
DO $$
DECLARE
  b  int := (SELECT ids.id FROM ids WHERE nombre = 'borrador');
  v  jsonb;
BEGIN
  PERFORM pg_temp.falla('authenticated', format($q$SELECT arca_para_reconciliar('facturas', %s)$q$, b),
    'permission denied', 'authenticated no la puede llamar');
  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, b));
  v := pg_temp.como('service_role', format($q$SELECT arca_para_reconciliar('facturas', %s)$q$, b));
  PERFORM pg_temp.ok(v->>'estado_fiscal' = 'en_proceso' AND NOT (v->>'colgado')::boolean
    AND (v->>'punto_venta')::int = 1 AND (v->>'cbte_tipo')::int = 1 AND v->>'nro_tentativo' IS NULL
    AND v->>'CbteFch' = to_char(pg_temp.hoy(), 'YYYYMMDD') AND (v->>'ImpTotal')::numeric = 6050
    AND (v->>'DocTipo')::int = 80 AND v->>'DocNro' = '30710000014',
    'en_proceso recién reclamado: serie, fecha, total y documento; no está colgado');
  UPDATE arca_series_en_curso SET reclamada_en = NOW() - interval '5 minutes'
  WHERE tabla = 'facturas' AND comprobante_id = b;
  v := pg_temp.como('service_role', format($q$SELECT arca_para_reconciliar('facturas', %s)$q$, b));
  PERFORM pg_temp.ok((v->>'colgado')::boolean, 'reclamado hace 5 minutos: colgado');
  PERFORM pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_error_previo('facturas', %s, 'prueba'))$q$, b));
END $$;

\echo '── 11) La anulación de una histórica sigue igual'
DO $$
DECLARE v jsonb;
BEGIN
  UPDATE facturas SET estado = 'pendiente' WHERE id = pg_temp.fac_hist();
  v := pg_temp.como('authenticated', format('SELECT to_jsonb(factura_anular(%s))', pg_temp.fac_hist()));
  PERFORM pg_temp.ok(v->>'estado' = 'anulada', 'una factura histórica pendiente se anula');
END $$;

\echo '── 12) Precios con más decimales que la columna (20261015140000)'
DO $$
DECLARE
  cli int := pg_temp.cli('30710000014');
  f   int;
  v   jsonb;
BEGIN
  f := pg_temp.factura(cli, '[{"descripcion":"a","cantidad":3,"precio_unitario":333.335},{"descripcion":"b","cantidad":1.2345,"precio_unitario":10.005,"alicuota_iva_id":2}]', 'A');
  PERFORM pg_temp.ok((SELECT bool_and(round(precio_unitario * cantidad, 2) = subtotal) FROM factura_items WHERE factura_id = f)
    AND (SELECT neto_gravado = 1000.02 + 12.36 FROM facturas WHERE id = f),
    'el renglón y la cabecera salen de los ítems redondeados (333,34 × 3; 1,235 × 10,01)');
  v := pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, f));
  PERFORM pg_temp.ok((v->'det'->>'ImpTotal')::numeric = (SELECT total FROM facturas WHERE id = f),
    'arca_comprobante_para_emitir no la bloquea por redondeo');
END $$;

ROLLBACK;
\echo '── Fin: ROLLBACK (homologación queda con los datos sintéticos de base)'
