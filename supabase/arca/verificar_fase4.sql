-- =============================================================
-- PLAN_ARCA — verificación de la Fase 4 en la base (notas de crédito y débito: borrador, letra,
-- payload de ARCA, edición, descarte y efectos al autorizar) en HOMOLOGACIÓN. La parte contra ARCA
-- (CAE reales) se prueba aparte, llamando a la Edge Function.
--
-- Uso (nunca contra prod), con 20261015150000 ya aplicada:
--   psql "$(cat ~/.arca/marblock/homo_db_url)" -X -f supabase/arca/verificar_fase4.sql
--
-- Corre todo en una transacción y termina con ROLLBACK: no deja nada en la base. Cada control
-- imprime "OK …"; el primero que falla corta con "FALLA …". Usa los datos sintéticos de
-- homologación (ver verificar_fase2.sql): el cliente RI 30710000014 con su FAC A histórica (PV
-- 00002) y la que tiene CAE, y el consumidor con DNI 28123456 con su FAC B histórica y la emitida
-- en la Fase 3.
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
  SELECT min(id) FROM facturas WHERE tipo = 'A' AND estado_fiscal = 'autorizado' AND cae IS NOT NULL $$;
CREATE FUNCTION pg_temp.fac_b_hist() RETURNS int LANGUAGE sql AS $$
  SELECT min(id) FROM facturas WHERE tipo = 'B' AND estado_fiscal = 'historico' $$;
CREATE FUNCTION pg_temp.fac_b_cae() RETURNS int LANGUAGE sql AS $$
  SELECT min(id) FROM facturas WHERE tipo = 'B' AND estado_fiscal = 'autorizado' AND cae IS NOT NULL $$;
CREATE FUNCTION pg_temp.hoy() RETURNS date LANGUAGE sql AS $$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date $$;
CREATE FUNCTION pg_temp.exento() RETURNS int LANGUAGE sql AS $$
  SELECT id FROM alicuotas_iva WHERE porcentaje = 0 $$;

-- Nota nueva por la RPC, como la llama el frontend (authenticated).
CREATE FUNCTION pg_temp.nota(p_fac int, p_tipo text, p_items text, p_perc text DEFAULT NULL) RETURNS int
LANGUAGE plpgsql AS $$
BEGIN
  RETURN (pg_temp.como('authenticated', format(
    $q$SELECT to_jsonb(crear_nota(%s, %L, %L::jsonb, 'prueba', NULL, %L::jsonb))$q$,
    p_fac, p_tipo, p_items, p_perc))->>'id')::int;
END $$;

CREATE FUNCTION pg_temp.factura(p_cli int, p_items text, p_tipo text) RETURNS int
LANGUAGE plpgsql AS $$
BEGIN
  RETURN (pg_temp.como('authenticated', format(
    $q$SELECT to_jsonb(crear_factura(%s, %L::jsonb, %L))$q$, p_cli, p_items, p_tipo))->>'id')::int;
END $$;

CREATE FUNCTION pg_temp.payload(p_nota int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('notas', %s)$q$, p_nota)) $$;

-- Lo que una nota mueve para el cliente: un borrador no tiene que cambiar nada de esto.
CREATE FUNCTION pg_temp.foto(p_cli int) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'saldo_cli',    (SELECT x->'saldo_pendiente' FROM clientes_list() x WHERE (x->>'id')::int = p_cli),
    'cta_cte',      informe_cta_cte(p_cli)->'saldo_total',
    'cta_cte_movs', jsonb_array_length(informe_cta_cte(p_cli)->'movimientos'),
    'por_cobrar',   informe_dashboard()->'kpis'->'total_por_cobrar',
    'deudores',     (SELECT jsonb_agg(x ORDER BY (x->>'id')::int) FROM informe_ranking_deudores() x),
    'libro_iva',    informe_libro_iva_ventas(pg_temp.hoy() - 30, pg_temp.hoy() + 1)->'totales',
    'estados',      (SELECT jsonb_object_agg(id, estado) FROM facturas WHERE cliente_id = p_cli)
  ) $$;

CREATE FUNCTION pg_temp.cambios(a jsonb, b jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(k, ', ' ORDER BY k), '') FROM jsonb_object_keys(a) k
  WHERE a->k IS DISTINCT FROM b->k $$;

CREATE TEMP TABLE ids (nombre text PRIMARY KEY, id int);

\echo '── 1) crear_nota → borrador, fuera de saldos e informes'
DO $$
DECLARE
  cli  int := pg_temp.cli('30710000014');
  fc   int := pg_temp.fac_cae();
  base jsonb := pg_temp.foto(cli);
  ctr  jsonb := (SELECT jsonb_object_agg(tipo, ultimo_numero) FROM contadores WHERE tipo LIKE 'nota%');
  n    int;
  v    jsonb;
BEGIN
  n := pg_temp.nota(fc, 'NC', '[{"descripcion":"devolución","cantidad":1,"precio_unitario":100}]');
  INSERT INTO ids VALUES ('nc_a', n);
  v := pg_temp.como('authenticated', format('SELECT x FROM notas_list(p_id => %s) x', n));
  PERFORM pg_temp.ok(v->>'estado_fiscal' = 'borrador' AND v->>'numero' IS NULL AND v->>'punto_venta' IS NULL
    AND v->>'numero_comp' IS NULL AND v->>'tipo_letra' = 'A' AND (v->>'fecha')::date = pg_temp.hoy()
    AND (v->>'cliente_id')::int = cli AND (v->>'total')::numeric = 121,
    'nace borrador, sin número, con la letra de la factura, fecha de hoy en Argentina y total 121');
  PERFORM pg_temp.ok((SELECT jsonb_object_agg(tipo, ultimo_numero) FROM contadores WHERE tipo LIKE 'nota%') IS NOT DISTINCT FROM ctr,
    'no consume los contadores de notas');
  PERFORM pg_temp.ok(pg_temp.cambios(pg_temp.foto(cli), base) = '',
    'no cambia el estado de la factura, saldo, cta. cte., dashboard, deudores ni libro IVA'
    || COALESCE(NULLIF(' [cambió: ' || pg_temp.cambios(pg_temp.foto(cli), base) || ']', ' [cambió: ]'), ''));

  n := pg_temp.nota(pg_temp.fac_b_cae(), 'NC', '[{"descripcion":"devolución","cantidad":1,"precio_unitario":100}]');
  INSERT INTO ids VALUES ('nc_b', n);
  PERFORM pg_temp.ok((SELECT tipo_letra = 'B' AND cliente_id = pg_temp.cli('28123456') FROM notas WHERE id = n),
    'sobre una Factura B nace NC B, con el cliente de la factura');

  n := pg_temp.nota(pg_temp.fac_hist(), 'ND', format(
    '[{"descripcion":"intereses","cantidad":1,"precio_unitario":500,"alicuota_iva_id":%s}]', pg_temp.exento()));
  INSERT INTO ids VALUES ('nd_exenta', n);
  PERFORM pg_temp.ok((SELECT estado_fiscal = 'borrador' AND total = 500 AND iva_monto = 0 FROM notas WHERE id = n),
    'sobre una factura histórica también se puede (ND A exenta, total 500 sin IVA)');
END $$;

\echo '── 2) Asiento automático: una nota borrador no genera asiento'
DO $$
DECLARE n int;
BEGIN
  UPDATE config_empresa SET valor = 'on' WHERE clave = 'contabilidad_auto_asientos';
  IF NOT FOUND THEN
    INSERT INTO config_empresa (clave, valor) VALUES ('contabilidad_auto_asientos', 'on');
  END IF;
  n := pg_temp.nota(pg_temp.fac_cae(), 'ND', '[{"descripcion":"flete","cantidad":1,"precio_unitario":10}]');
  SET CONSTRAINTS trg_asiento_auto_nota IMMEDIATE;
  PERFORM pg_temp.ok(NOT asiento_existe_para('notas', n), 'con el flag prendido, la nota borrador no genera asiento');
  SET CONSTRAINTS trg_asiento_auto_nota DEFERRED;
  UPDATE config_empresa SET valor = 'off' WHERE clave = 'contabilidad_auto_asientos';
  DELETE FROM notas WHERE id = n;
END $$;

\echo '── 3) Sobre qué facturas se puede hacer una nota'
DO $$
DECLARE
  cli   int := pg_temp.cli('30710000014');
  items text := '[{"descripcion":"devolución","cantidad":1,"precio_unitario":10}]';
  f     int;
BEGIN
  f := pg_temp.factura(cli, items, 'A');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_nota(%s, 'NC', %L))$q$, f, items),
    'todavía no se emitió', 'no sobre una factura borrador');
  UPDATE facturas SET estado_fiscal = 'rechazado' WHERE id = f;
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_nota(%s, 'NC', %L))$q$, f, items),
    'rechazó la factura', 'no sobre una factura rechazada');
  UPDATE facturas SET estado_fiscal = 'en_proceso' WHERE id = f;
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_nota(%s, 'NC', %L))$q$, f, items),
    'se está emitiendo', 'no sobre una factura en emisión');
  UPDATE facturas SET estado_fiscal = 'resultado_incierto', arca_nro_tentativo = 99999 WHERE id = f;
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_nota(%s, 'NC', %L))$q$, f, items),
    'resultado incierto', 'no sobre una factura con resultado incierto');

  UPDATE facturas SET estado = 'anulada' WHERE id = pg_temp.fac_b_hist();
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_nota(%s, 'NC', %L))$q$, pg_temp.fac_b_hist(), items),
    'anulada', 'no sobre una factura histórica anulada');
  UPDATE facturas SET estado = 'pendiente' WHERE id = pg_temp.fac_b_hist();

  -- El cliente RI pasa a Consumidor Final: su Factura A ya no admite una nota A.
  UPDATE clientes SET condicion_iva_afip_id = 5 WHERE id = cli;
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_nota(%s, 'NC', %L))$q$, pg_temp.fac_cae(), items),
    'ARCA rechazaría', 'no si la condición IVA de hoy no es de la clase de la factura');
  UPDATE clientes SET condicion_iva_afip_id = 1 WHERE id = cli;

  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_nota(%s, 'XX', %L))$q$, pg_temp.fac_cae(), items),
    'Tipo inválido', 'sólo NC o ND');
  PERFORM pg_temp.falla('anon', format($q$SELECT to_jsonb(crear_nota(%s, 'NC', %L))$q$, pg_temp.fac_cae(), items),
    'permission denied', 'anon no crea notas');
  PERFORM pg_temp.falla('anon', format($q$SELECT to_jsonb(actualizar_nota(1, %L))$q$, items),
    'permission denied', 'anon no edita notas');
  PERFORM pg_temp.falla('anon', $q$SELECT null::jsonb FROM nota_borrador_descartar(1)$q$,
    'permission denied', 'anon no descarta notas');
  PERFORM pg_temp.falla('authenticated', $q$SELECT null::jsonb FROM crm_validar_letra_nota(1, 'A')$q$,
    'permission denied', 'authenticated no llama al helper de letra');
END $$;

\echo '── 4) Payload de ARCA'
DO $$
DECLARE
  nc_a int := (SELECT id FROM ids WHERE nombre = 'nc_a');
  nc_b int := (SELECT id FROM ids WHERE nombre = 'nc_b');
  nd   int := (SELECT id FROM ids WHERE nombre = 'nd_exenta');
  fc   facturas;
  fh   facturas;
  fb   facturas;
  v    jsonb;
  n    int;
BEGIN
  SELECT * INTO fc FROM facturas WHERE id = pg_temp.fac_cae();
  SELECT * INTO fh FROM facturas WHERE id = pg_temp.fac_hist();
  SELECT * INTO fb FROM facturas WHERE id = pg_temp.fac_b_cae();

  v := pg_temp.payload(nc_a);
  PERFORM pg_temp.ok((v->>'cbte_tipo')::int = 3 AND NOT (v->>'verificar_asociado')::boolean
    AND v->'det'->'CbtesAsoc' = jsonb_build_array(jsonb_build_object('Tipo', 1, 'PtoVta', fc.punto_venta::int,
          'Nro', fc.numero_comp, 'CbteFch', to_char(fc.fecha, 'YYYYMMDD')))
    AND v->'det'->'Iva' = '[{"Id":5,"BaseImp":100.00,"Importe":21.00}]'::jsonb
    AND (v->'det'->>'ImpNeto')::numeric = 100 AND (v->'det'->>'ImpOpEx')::numeric = 0
    AND (v->'det'->>'ImpTotal')::numeric = 121 AND (v->'det'->>'DocTipo')::int = 80
    AND (v->'det'->>'CondicionIVAReceptorId')::int = 1,
    'NC A: tipo 3, CbtesAsoc con la FAC A (tipo 1, PV, número, fecha), Iva 21 %, receptor RI');

  v := pg_temp.payload(nc_b);
  PERFORM pg_temp.ok((v->>'cbte_tipo')::int = 8
    AND v->'det'->'CbtesAsoc'->0->>'Tipo' = '6' AND (v->'det'->'CbtesAsoc'->0->>'Nro')::int = fb.numero_comp
    AND (v->'det'->>'DocTipo')::int = 96 AND v->'det'->>'DocNro' = '28123456'
    AND (v->'det'->>'CondicionIVAReceptorId')::int = 5,
    'NC B: tipo 8, CbtesAsoc con la FAC B (tipo 6), receptor con DNI y condición 5');

  v := pg_temp.payload(nd);
  PERFORM pg_temp.ok((v->>'cbte_tipo')::int = 2 AND (v->>'verificar_asociado')::boolean
    AND (v->'det'->>'ImpOpEx')::numeric = 500 AND (v->'det'->>'ImpNeto')::numeric = 0
    AND (v->'det'->>'ImpIVA')::numeric = 0 AND (v->'det'->>'ImpTotal')::numeric = 500
    AND NOT (v->'det' ? 'Iva')
    AND (v->'det'->'CbtesAsoc'->0->>'PtoVta')::int = fh.punto_venta::int
    AND (v->'det'->'CbtesAsoc'->0->>'Nro')::int = fh.numero_comp,
    'ND A exenta sobre la histórica: tipo 2, ImpOpEx = total, ImpNeto 0, sin Iva, asociado a verificar a mano');

  n := pg_temp.nota(pg_temp.fac_hist(), 'ND', format(
    '[{"descripcion":"exento","cantidad":1,"precio_unitario":100,"alicuota_iva_id":%s},{"descripcion":"gravado","cantidad":1,"precio_unitario":200}]',
    pg_temp.exento()));
  v := pg_temp.payload(n);
  PERFORM pg_temp.ok((v->'det'->>'ImpOpEx')::numeric = 100 AND (v->'det'->>'ImpNeto')::numeric = 200
    AND v->'det'->'Iva' = '[{"Id":5,"BaseImp":200.00,"Importe":42.00}]'::jsonb
    AND (v->'det'->>'ImpTotal')::numeric = 342,
    'ND A exento + 21 %: el exento va a ImpOpEx y el array Iva tiene una sola entrada');

  n := pg_temp.nota(pg_temp.fac_cae(), 'NC',
    '[{"descripcion":"a","cantidad":3,"precio_unitario":333.335},{"descripcion":"b","cantidad":1.2345,"precio_unitario":10.005,"alicuota_iva_id":2}]');
  PERFORM pg_temp.ok((SELECT bool_and(round(precio_unitario * cantidad, 2) = subtotal) FROM nota_items WHERE nota_id = n)
    AND (SELECT neto_gravado = 1000.02 + 12.36 FROM notas WHERE id = n),
    'ítems redondeados: el renglón y la cabecera salen de 333,34 × 3 y 1,235 × 10,01');
  v := pg_temp.payload(n);
  PERFORM pg_temp.ok((v->'det'->>'ImpTotal')::numeric = (SELECT total FROM notas WHERE id = n)
    AND jsonb_array_length(v->'det'->'Iva') = 2,
    'arca_comprobante_para_emitir no la bloquea por redondeo (dos alícuotas)');
END $$;

\echo '── 5) Lo que no se emite: percepciones y letra forzada'
DO $$
DECLARE
  items text := '[{"descripcion":"devolución","cantidad":1,"precio_unitario":1000}]';
  n     int;
BEGIN
  n := pg_temp.nota(pg_temp.fac_cae(), 'NC', items, '[{"tipo_percepcion":"iibb","jurisdiccion":"BA","alicuota":3}]');
  PERFORM pg_temp.ok((SELECT percepciones_monto = 30 AND total = 1240 FROM notas WHERE id = n),
    'una nota con percepciones se guarda (30 sobre 1.000)');
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_reclamar_serie('notas', %s, 1)$q$, n),
    'percepciones', 'pero no se emite');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM arca_series_en_curso WHERE tabla = 'notas' AND comprobante_id = n)
    AND (SELECT estado_fiscal = 'borrador' FROM notas WHERE id = n),
    'y no toma la serie: sigue borrador');

  n := pg_temp.nota(pg_temp.fac_cae(), 'NC', items);
  UPDATE notas SET tipo_letra = 'B' WHERE id = n;
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_reclamar_serie('notas', %s, 1)$q$, n),
    'le corresponde|no puede asociarse', 'una NC B sobre una Factura A (forzada en la base) no se emite');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM arca_series_en_curso WHERE tabla = 'notas' AND comprobante_id = n),
    'y no toma la serie');
END $$;

\echo '── 6) Edición y descarte según el estado fiscal'
DO $$
DECLARE
  cli   int := pg_temp.cli('30710000014');
  items text := '[{"descripcion":"devolución","cantidad":2,"precio_unitario":100}]';
  n     int;
  hist  int;
  v     jsonb;
BEGIN
  n := pg_temp.nota(pg_temp.fac_cae(), 'NC', '[{"descripcion":"x","cantidad":1,"precio_unitario":100}]',
                    '[{"tipo_percepcion":"iibb","alicuota":3}]');
  v := pg_temp.como('authenticated', format($q$SELECT to_jsonb(actualizar_nota(%s, %L, 'motivo nuevo'))$q$, n, items));
  PERFORM pg_temp.ok(v->>'estado_fiscal' = 'borrador' AND (v->>'total')::numeric = 242 AND v->>'motivo' = 'motivo nuevo'
    AND (v->>'percepciones_monto')::numeric = 0
    AND NOT EXISTS (SELECT 1 FROM percepciones WHERE nota_id = n)
    AND (SELECT count(*) = 1 AND sum(cantidad) = 2 FROM nota_items WHERE nota_id = n),
    'un borrador se edita: ítems, motivo y totales nuevos; sin percepciones si no se mandan');

  UPDATE notas SET estado_fiscal = 'rechazado' WHERE id = n;
  v := pg_temp.como('authenticated', format($q$SELECT to_jsonb(actualizar_nota(%s, %L))$q$, n, items));
  PERFORM pg_temp.ok(v->>'estado_fiscal' = 'borrador', 'un rechazado se edita y vuelve a borrador');

  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('notas', %s, 1)$q$, n));
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(actualizar_nota(%s, %L))$q$, n, items),
    'se está emitiendo', 'no se edita en emisión');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT null::jsonb FROM nota_borrador_descartar(%s)$q$, n),
    'se está emitiendo', 'no se descarta en emisión');
  PERFORM pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_error_previo('notas', %s, 'prueba'))$q$, n));

  UPDATE clientes SET condicion_iva_afip_id = 5 WHERE id = cli;
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(actualizar_nota(%s, %L))$q$, n, items),
    'ARCA rechazaría', 'no se edita si el cliente cambió de clase');
  UPDATE clientes SET condicion_iva_afip_id = 1 WHERE id = cli;

  PERFORM pg_temp.como('authenticated', format(
    $q$SELECT to_jsonb(actualizar_nota(%s, %L, NULL, NULL, '[{"tipo_percepcion":"iibb","alicuota":3}]'))$q$, n, items));
  PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM percepciones WHERE nota_id = n), 'editar con percepciones las guarda');
  PERFORM pg_temp.como('authenticated', format($q$SELECT null::jsonb FROM nota_borrador_descartar(%s)$q$, n));
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM notas WHERE id = n)
    AND NOT EXISTS (SELECT 1 FROM nota_items WHERE nota_id = n)
    AND NOT EXISTS (SELECT 1 FROM percepciones WHERE nota_id = n),
    'un borrador se descarta con sus ítems y percepciones');

  n := pg_temp.nota(pg_temp.fac_cae(), 'NC', items);
  UPDATE notas SET estado_fiscal = 'rechazado' WHERE id = n;
  PERFORM pg_temp.como('authenticated', format($q$SELECT null::jsonb FROM nota_borrador_descartar(%s)$q$, n));
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM notas WHERE id = n), 'un rechazado se descarta');

  INSERT INTO notas (numero, punto_venta, numero_comp, tipo, tipo_letra, fecha, factura_id, cliente_id, total, estado_fiscal)
  VALUES ('00002-00099999', '00002', 99999, 'NC', 'B', pg_temp.hoy(), pg_temp.fac_b_hist(), pg_temp.cli('28123456'), 1, 'historico')
  RETURNING id INTO hist;
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(actualizar_nota(%s, %L))$q$, hist, items),
    'histórico', 'una nota histórica no se edita');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT null::jsonb FROM nota_borrador_descartar(%s)$q$, hist),
    'histórico', 'una nota histórica no se descarta');
  DELETE FROM notas WHERE id = hist;
END $$;

\echo '── 7) Al autorizar, la nota ajusta el saldo una sola vez'
DO $$
DECLARE
  cli  int := pg_temp.cli('30710000014');
  fc   int := pg_temp.fac_cae();
  n    int := (SELECT id FROM ids WHERE nombre = 'nc_a');
  base jsonb;
  desp jsonb;
  req  jsonb := '{"FeCabReq":{"CantReg":1},"FECAEDetRequest":{}}';
  v    jsonb;
  -- Un número que no usó ninguna emisión real de homologación.
  nro  int := (SELECT COALESCE(max(numero_comp), 0) + 1000 FROM notas WHERE tipo = 'NC' AND tipo_letra = 'A' AND punto_venta = '00001');
BEGIN
  PERFORM recalcular_estado_factura(fc);
  base := pg_temp.foto(cli);
  PERFORM pg_temp.ok((SELECT estado = 'pendiente' AND total = 121 FROM facturas WHERE id = fc),
    'antes: la FAC A de 121 está pendiente');

  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('notas', %s, 1)$q$, n));
  PERFORM pg_temp.como('service_role', format($q$SELECT null::jsonb FROM arca_reservar_numero('notas', %s, %s)$q$, n, nro));
  v := pg_temp.como('service_role', format(
    $q$SELECT arca_registrar_cae('notas', %s, %s, '75000000000003', CURRENT_DATE + 10, 3, 80, '30710000014', %L, '{"Resultado":"A"}')$q$, n, nro, req));
  PERFORM pg_temp.ok((v->>'registrado')::boolean
    AND (SELECT estado_fiscal = 'autorizado' AND numero = '00001-' || lpad(nro::text, 8, '0')
                AND cae = '75000000000003' AND afip_tipo_comprobante = '003' FROM notas WHERE id = n),
    'autorizada con el número que dio ARCA y tipo 003');
  PERFORM pg_temp.ok((SELECT estado = 'cobrada' FROM facturas WHERE id = fc),
    'la NC por el total deja la factura cobrada');
  desp := pg_temp.foto(cli);
  PERFORM pg_temp.ok((desp->>'saldo_cli')::numeric = (base->>'saldo_cli')::numeric - 121
    AND (desp->>'cta_cte')::numeric = (base->>'cta_cte')::numeric - 121
    AND (desp->>'cta_cte_movs')::int = (base->>'cta_cte_movs')::int + 1
    AND (desp->>'por_cobrar')::numeric = (base->>'por_cobrar')::numeric - 121
    AND (desp->'libro_iva'->>'cantidad')::int = (base->'libro_iva'->>'cantidad')::int + 1
    AND (desp->'libro_iva'->>'total')::numeric = (base->'libro_iva'->>'total')::numeric - 121,
    'recién ahora resta del saldo del cliente, la cta. cte. y el dashboard, y entra al libro IVA');

  v := pg_temp.como('service_role', format(
    $q$SELECT arca_registrar_cae('notas', %s, %s, '75000000000003', CURRENT_DATE + 10, 3, 80, '30710000014', %L, '{"Resultado":"A"}')$q$, n, nro, req));
  PERFORM pg_temp.ok((v->>'registrado')::boolean AND pg_temp.cambios(pg_temp.foto(cli), desp) = '',
    'registrar el mismo CAE otra vez no duplica nada');

  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(actualizar_nota(%s, '[{"descripcion":"x","cantidad":1,"precio_unitario":1}]'))$q$, n),
    'ya tiene CAE', 'una nota autorizada no se edita');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT null::jsonb FROM nota_borrador_descartar(%s)$q$, n),
    'ya tiene CAE', 'una nota autorizada no se descarta');
END $$;

\echo '── 8) Una ND autorizada suma al saldo pero no cambia el estado de la factura'
DO $$
DECLARE
  cli  int := pg_temp.cli('30710000014');
  fh   int := pg_temp.fac_hist();
  n    int := (SELECT id FROM ids WHERE nombre = 'nd_exenta');
  base jsonb;
  est  text;
  nro  int := (SELECT COALESCE(max(numero_comp), 0) + 1000 FROM notas WHERE tipo = 'ND' AND tipo_letra = 'A' AND punto_venta = '00001');
  v    jsonb;
BEGIN
  PERFORM recalcular_estado_factura(fh);
  base := pg_temp.foto(cli);
  est  := (SELECT estado FROM facturas WHERE id = fh);
  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('notas', %s, 1)$q$, n));
  PERFORM pg_temp.como('service_role', format($q$SELECT null::jsonb FROM arca_reservar_numero('notas', %s, %s)$q$, n, nro));
  v := pg_temp.como('service_role', format(
    $q$SELECT arca_registrar_cae('notas', %s, %s, '75000000000004', CURRENT_DATE + 10, 2, 80, '30710000014', '{}', '{"Resultado":"A"}')$q$, n, nro));
  PERFORM pg_temp.ok((v->>'registrado')::boolean AND (SELECT estado FROM facturas WHERE id = fh) = est
    AND (pg_temp.foto(cli)->>'cta_cte')::numeric = (base->>'cta_cte')::numeric + 500,
    'la ND exenta autorizada suma 500 a la cta. cte. y la factura sigue ' || est);
END $$;

\echo '── 9) factura_anular no deja una nota sin emitir colgada de una factura anulada'
DO $$
DECLARE
  fh int := pg_temp.fac_hist();
  n  int;
  v  jsonb;
BEGIN
  UPDATE facturas SET estado = 'pendiente' WHERE id = fh;
  n := pg_temp.nota(fh, 'NC', '[{"descripcion":"devolución","cantidad":1,"precio_unitario":10}]');
  PERFORM pg_temp.falla('authenticated', format('SELECT to_jsonb(factura_anular(%s))', fh),
    'sin CAE', 'una histórica con notas borrador no se anula');
  -- La NC de recién y la ND mixta de la sección 4.
  FOR n IN SELECT id FROM notas WHERE factura_id = fh AND estado_fiscal = 'borrador' LOOP
    PERFORM pg_temp.como('authenticated', format($q$SELECT null::jsonb FROM nota_borrador_descartar(%s)$q$, n));
  END LOOP;
  v := pg_temp.como('authenticated', format('SELECT to_jsonb(factura_anular(%s))', fh));
  PERFORM pg_temp.ok(v->>'estado' = 'anulada',
    'descartadas las notas, se anula (una ND ya autorizada no lo impide)');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_nota(%s, 'NC', '[{"descripcion":"x","cantidad":1,"precio_unitario":1}]'))$q$, fh),
    'anulada', 'y ya no admite notas');
END $$;

\echo '── 10) arca_para_reconciliar con una nota'
DO $$
DECLARE
  n int := (SELECT id FROM ids WHERE nombre = 'nc_b');
  v jsonb;
BEGIN
  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('notas', %s, 1)$q$, n));
  v := pg_temp.como('service_role', format($q$SELECT arca_para_reconciliar('notas', %s)$q$, n));
  PERFORM pg_temp.ok(v->>'estado_fiscal' = 'en_proceso' AND (v->>'punto_venta')::int = 1
    AND (v->>'cbte_tipo')::int = 8 AND v->>'CbteFch' = to_char(pg_temp.hoy(), 'YYYYMMDD')
    AND (v->>'ImpTotal')::numeric = 121 AND (v->>'DocTipo')::int = 96 AND v->>'DocNro' = '28123456',
    'NC B en emisión: serie tipo 8, fecha, total y documento del cliente de la factura');
  PERFORM pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_error_previo('notas', %s, 'prueba'))$q$, n));
END $$;

ROLLBACK;
\echo '── Fin: ROLLBACK (homologación queda con los datos sintéticos de base)'
