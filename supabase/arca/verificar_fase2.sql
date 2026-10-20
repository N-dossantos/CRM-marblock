-- =============================================================
-- PLAN_ARCA — verificación de la Fase 2 (esquema, clientes y RPCs arca_*) en HOMOLOGACIÓN.
--
-- Uso (nunca contra prod):
--   psql "$(cat ~/.arca/marblock/homo_db_url)" -X -f supabase/arca/verificar_fase2.sql
--
-- Corre todo en una transacción y termina con ROLLBACK: no deja nada en la base. Cada control
-- imprime "OK …"; el primero que falla corta con "FALLA …".
--
-- Espera los datos sintéticos con que se armó homologación el 15/10/2026 (nada real), cargados en
-- el formato previo a 20261015120001 para que esa migración probara su backfill:
--   PRUEBA Responsable Inscripto SA  30-71000001-4  Resp. Inscripto   (+ una FAC A histórica sin CAE
--                                                                      y otra con CAE)
--   PRUEBA Monotributista            20-30000001-1  Monotributista
--   PRUEBA Asociación Exenta         30-71000002-2  Exento
--   PRUEBA Consumidor con DNI        28123456       Consumidor Final  (+ una FAC B histórica)
--   PRUEBA Consumidor Final genérico 00-00000000-0  Consumidor Final
--   PRUEBA RI con CUIT repetido      99-00000123-0  Resp. Inscripto
--
-- Refleja el estado de la Fase 2: los "borradores" se arman con la crear_factura de entonces
-- (numera por contadores) y se les quita el número. Cuando la Fase 3 convierta crear_factura en
-- borrador, este script deja de aplicar tal cual.
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

-- Borrador como lo va a crear la Fase 3: crear_factura actual + sin número fiscal.
CREATE FUNCTION pg_temp.borrador(p_cli int, p_items jsonb, p_tipo text, p_desc numeric DEFAULT 0,
                                 p_perc jsonb DEFAULT NULL) RETURNS int LANGUAGE plpgsql AS $$
DECLARE f facturas;
BEGIN
  SELECT * INTO f FROM crear_factura(p_cli, p_items, p_tipo, p_desc, NULL, NULL, NULL, p_perc);
  UPDATE facturas SET numero = NULL, punto_venta = NULL, numero_comp = NULL, estado_fiscal = 'borrador'
  WHERE id = f.id;
  RETURN f.id;
END $$;

CREATE FUNCTION pg_temp.cli(p_nro text) RETURNS int LANGUAGE sql AS $$
  SELECT id FROM clientes WHERE doc_nro = p_nro $$;

-- La FAC A histórica sin CAE y la que tiene CAE del cliente RI (las primeras que se cargaron).
CREATE FUNCTION pg_temp.fac_hist() RETURNS int LANGUAGE sql AS $$
  SELECT min(f.id) FROM facturas f JOIN clientes c ON c.id = f.cliente_id
  WHERE c.doc_nro = '30710000014' AND f.tipo = 'A' AND f.estado_fiscal = 'historico' $$;
CREATE FUNCTION pg_temp.fac_cae() RETURNS int LANGUAGE sql AS $$
  SELECT min(id) FROM facturas WHERE estado_fiscal = 'autorizado' AND cae IS NOT NULL $$;

\echo '── 1) Backfill de clientes y estado fiscal'
DO $$ BEGIN
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'clientes' AND column_name IN ('cuit','condicion_iva')),
    'clientes.cuit y clientes.condicion_iva ya no existen');
  PERFORM pg_temp.ok((SELECT doc_tipo = 80 AND doc_nro = '30710000014' AND condicion_iva_afip_id = 1
    FROM clientes WHERE razon_social = 'PRUEBA Responsable Inscripto SA'), 'RI → 80 / 30710000014 / Id 1');
  PERFORM pg_temp.ok((SELECT condicion_iva_afip_id = 6 FROM clientes WHERE razon_social = 'PRUEBA Monotributista'),
    'Monotributista → Id 6');
  PERFORM pg_temp.ok((SELECT condicion_iva_afip_id = 4 FROM clientes WHERE razon_social = 'PRUEBA Asociación Exenta'),
    'Exento → Id 4');
  PERFORM pg_temp.ok((SELECT doc_tipo = 96 AND doc_nro = '28123456' AND condicion_iva_afip_id = 5
    FROM clientes WHERE razon_social = 'PRUEBA Consumidor con DNI'), 'DNI en el campo CUIT → 96 / Consumidor Final Id 5');
  PERFORM pg_temp.ok((SELECT doc_tipo = 80 AND doc_nro = '00000000000'
    FROM clientes WHERE razon_social = 'PRUEBA Consumidor Final genérico'), 'CUIT de relleno 00-00000000-0 → 80 / 00000000000');
  PERFORM pg_temp.ok(pg_temp.fac_cae() IS NOT NULL AND NOT EXISTS (SELECT 1 FROM facturas
    WHERE (cae IS NOT NULL) <> (estado_fiscal = 'autorizado') OR estado_fiscal NOT IN ('historico','autorizado')),
    'facturas: sin CAE → historico, con CAE → autorizado');
  PERFORM pg_temp.ok((SELECT count(*) FROM condiciones_iva_afip) = 11
    AND (SELECT string_agg(id::text, ',' ORDER BY id) FROM condiciones_iva_afip WHERE clase = 'A') = '1,6,13,16',
    'catálogo: 11 condiciones, clase A = 1, 6, 13, 16');
END $$;

\echo '── 2) Restricciones de la base'
DO $$ BEGIN
  INSERT INTO facturas (tipo, fecha, cliente_id, estado_fiscal) VALUES ('A', CURRENT_DATE, pg_temp.cli('30710000014'), 'borrador');
  PERFORM pg_temp.ok(true, 'un borrador se inserta sin número fiscal');
  PERFORM pg_temp.falla('postgres', $q$WITH x AS (INSERT INTO facturas (tipo, fecha, cliente_id) VALUES ('A', CURRENT_DATE, (SELECT id FROM clientes WHERE doc_nro = '30710000014')) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$,
    'chk_fac_numero_fiscal', 'un histórico sin número');
  PERFORM pg_temp.falla('postgres', format($q$WITH x AS (UPDATE facturas SET estado_fiscal = 'autorizado' WHERE id = %s RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$, pg_temp.fac_hist()),
    'chk_fac_cae', 'autorizado sin CAE');
  PERFORM pg_temp.falla('postgres', $q$WITH x AS (INSERT INTO facturas (tipo, fecha, cliente_id, estado_fiscal, numero, punto_venta, numero_comp) VALUES ('A', CURRENT_DATE, (SELECT id FROM clientes WHERE doc_nro = '30710000014'), 'borrador', '00009-00000001', '00009', 1) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$,
    'chk_fac_numero_fiscal', 'un borrador con número fiscal');
  PERFORM pg_temp.falla('postgres', $q$WITH x AS (INSERT INTO clientes (razon_social, doc_tipo, doc_nro, condicion_iva_afip_id) VALUES ('X', 80, '123', 1) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$,
    'chk_cli_doc_nro', 'un CUIT de 3 dígitos');
  PERFORM pg_temp.falla('postgres', $q$WITH x AS (INSERT INTO clientes (razon_social, doc_tipo, doc_nro, condicion_iva_afip_id) VALUES ('X', 80, '30710000014', 1) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$,
    'clientes_doc_key', 'un documento repetido');
END $$;

\echo '── 3) Permisos'
DO $$ BEGIN
  PERFORM pg_temp.falla('authenticated', 'SELECT to_jsonb(count(*)) FROM arca_tokens', 'permission denied', 'authenticated no lee arca_tokens');
  PERFORM pg_temp.falla('authenticated', 'SELECT to_jsonb(count(*)) FROM arca_solicitudes', 'permission denied', 'authenticated no lee arca_solicitudes');
  PERFORM pg_temp.falla('authenticated', 'SELECT to_jsonb(count(*)) FROM arca_series_en_curso', 'permission denied', 'authenticated no lee arca_series_en_curso');
  PERFORM pg_temp.falla('service_role', 'SELECT to_jsonb(count(*)) FROM arca_tokens', 'permission denied', 'service_role tampoco lee arca_tokens directo');
  PERFORM pg_temp.falla('anon', 'SELECT to_jsonb(count(*)) FROM condiciones_iva_afip', 'permission denied', 'anon no lee el catálogo');
  PERFORM pg_temp.ok((pg_temp.como('authenticated', 'SELECT to_jsonb(count(*)) FROM condiciones_iva_afip'))::int = 11,
    'authenticated lee el catálogo');
  PERFORM pg_temp.falla('authenticated', $q$WITH x AS (INSERT INTO condiciones_iva_afip VALUES (99, 'X', 'A') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$,
    'permission denied', 'authenticated no escribe el catálogo');
  PERFORM pg_temp.falla('authenticated', $q$SELECT arca_comprobante_para_emitir('facturas', 1)$q$, 'permission denied', 'authenticated no llama arca_comprobante_para_emitir');
  PERFORM pg_temp.falla('authenticated', $q$SELECT arca_token_get('wsfe', 60)$q$, 'permission denied', 'authenticated no llama arca_token_get');
  PERFORM pg_temp.falla('anon', $q$SELECT arca_solicitud_ultimo('facturas', 1)$q$, 'permission denied', 'anon no llama arca_solicitud_ultimo');
  PERFORM pg_temp.falla('authenticated', $q$SELECT to_jsonb(crm_cuit_valido('30710000014'))$q$, 'permission denied', 'authenticated no llama helpers internos');
END $$;

\echo '── 4) Letra = clase (crear_factura / actualizar_factura)'
DO $$ BEGIN
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_factura(%s, '[{"descripcion":"x","cantidad":1,"precio_unitario":10}]', 'B'))$q$, pg_temp.cli('20300000011')),
    'le corresponde comprobante A', 'Factura B a un monotributista');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(crear_factura(%s, '[{"descripcion":"x","cantidad":1,"precio_unitario":10}]', 'A'))$q$, pg_temp.cli('28123456')),
    'le corresponde comprobante B', 'Factura A a un consumidor final');
  PERFORM pg_temp.falla('authenticated', format($q$SELECT to_jsonb(actualizar_factura(%s, %s, '[{"descripcion":"x","cantidad":1,"precio_unitario":10}]'))$q$, pg_temp.fac_hist(), pg_temp.cli('28123456')),
    'le corresponde comprobante B', 'cambiar una Factura A a un cliente de clase B');
  PERFORM pg_temp.ok((pg_temp.como('authenticated', format($q$SELECT to_jsonb(crear_factura(%s, '[{"descripcion":"x","cantidad":1,"precio_unitario":10}]', 'A'))$q$, pg_temp.cli('20300000011')))->>'tipo') = 'A',
    'Factura A a un monotributista');
END $$;

\echo '── 5) arca_comprobante_para_emitir'
DO $$
DECLARE
  v jsonb; id1 int; id2 int; id3 int; id4 int; id5 int; id6 int; id7 int; id8 int; id9 int;
  v_ex int := (SELECT id FROM alicuotas_iva WHERE porcentaje = 0);
  v_105 int := (SELECT id FROM alicuotas_iva WHERE porcentaje = 10.5);
BEGIN
  id1 := pg_temp.borrador(pg_temp.cli('30710000014'), '[{"descripcion":"bloque","cantidad":10,"precio_unitario":1000}]', 'A');
  v := pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id1));
  RAISE NOTICE '      FAC A, un ítem 21%%: %', v->'det';
  PERFORM pg_temp.ok(v->>'cbte_tipo' = '1' AND v->'det'->>'DocTipo' = '80' AND v->'det'->>'DocNro' = '30710000014'
    AND (v->'det'->>'ImpNeto')::numeric = 10000 AND (v->'det'->>'ImpIVA')::numeric = 2100
    AND (v->'det'->>'ImpTotal')::numeric = 12100 AND (v->'det'->>'ImpOpEx')::numeric = 0
    AND v->'det'->'Iva' = '[{"Id": 5, "BaseImp": 10000.00, "Importe": 2100.00}]'::jsonb
    AND v->'det'->>'CondicionIVAReceptorId' = '1' AND NOT v->'det' ? 'CbtesAsoc',
    'FAC A a RI: tipo 1, DocTipo 80, Iva [Id 5], totales cuadran');

  id2 := pg_temp.borrador(pg_temp.cli('28123456'), '[{"descripcion":"bloque","cantidad":2,"precio_unitario":500}]', 'B');
  v := pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id2));
  PERFORM pg_temp.ok(v->>'cbte_tipo' = '6' AND v->'det'->>'DocTipo' = '96' AND v->'det'->>'CondicionIVAReceptorId' = '5',
    'FAC B a consumidor con DNI: tipo 6, DocTipo 96, condición 5');

  id3 := pg_temp.borrador(pg_temp.cli('30710000014'), format('[{"descripcion":"a","cantidad":1,"precio_unitario":1000},{"descripcion":"b","cantidad":1,"precio_unitario":1000,"alicuota_iva_id":%s}]', v_105)::jsonb, 'A');
  v := pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id3));
  RAISE NOTICE '      FAC A 21%% + 10,5%%: %', v->'det'->'Iva';
  PERFORM pg_temp.ok(jsonb_array_length(v->'det'->'Iva') = 2 AND (v->'det'->>'ImpIVA')::numeric = 315
    AND (v->'det'->>'ImpNeto')::numeric = 2000, 'dos alícuotas: Iva con dos entradas (4 y 5), ImpIVA 315');

  id4 := pg_temp.borrador(pg_temp.cli('30710000014'), format('[{"descripcion":"gravado","cantidad":1,"precio_unitario":1000},{"descripcion":"exento","cantidad":1,"precio_unitario":500,"alicuota_iva_id":%s}]', v_ex)::jsonb, 'A');
  v := pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id4));
  RAISE NOTICE '      FAC A gravado + exento: %', v->'det';
  PERFORM pg_temp.ok(jsonb_array_length(v->'det'->'Iva') = 1 AND v->'det'->'Iva'->0->>'Id' = '5'
    AND (v->'det'->>'ImpNeto')::numeric = 1000 AND (v->'det'->>'ImpOpEx')::numeric = 500
    AND (v->'det'->>'ImpTotal')::numeric = 1710, 'exento + 21%: exento a ImpOpEx, Iva con una sola entrada (Id 5)');

  id5 := pg_temp.borrador(pg_temp.cli('30710000014'), format('[{"descripcion":"exento","cantidad":2,"precio_unitario":500,"alicuota_iva_id":%s}]', v_ex)::jsonb, 'A');
  v := pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id5));
  PERFORM pg_temp.ok(NOT v->'det' ? 'Iva' AND (v->'det'->>'ImpIVA')::numeric = 0 AND (v->'det'->>'ImpNeto')::numeric = 0
    AND (v->'det'->>'ImpOpEx')::numeric = 1000, 'todo exento: sin Iva, ImpNeto 0, ImpOpEx = total');

  id6 := pg_temp.borrador(pg_temp.cli('30710000014'), '[{"descripcion":"bloque","cantidad":3,"precio_unitario":333.33}]', 'A', 15);
  v := pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id6));
  PERFORM pg_temp.ok((v->'det'->>'ImpNeto')::numeric = (SELECT neto_gravado FROM facturas WHERE id = id6),
    format('descuento general 15%%: ImpNeto %s = neto_gravado de la base', v->'det'->>'ImpNeto'));

  id7 := pg_temp.borrador(pg_temp.cli('30710000014'), '[{"descripcion":"bloque","cantidad":1,"precio_unitario":1000}]', 'A', 0,
    '[{"tipo_percepcion":"iibb","jurisdiccion":"Buenos Aires","alicuota":3}]');
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id7),
    'percepciones', 'con percepciones: bloqueada antes de ARCA');

  id8 := pg_temp.borrador(pg_temp.cli('99000001230'), '[{"descripcion":"bloque","cantidad":1,"precio_unitario":1000}]', 'A');
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id8),
    'CUIT del cliente .* no es válido', 'CUIT de relleno 99-…: bloqueada');
  id9 := pg_temp.borrador(pg_temp.cli('00000000000'), '[{"descripcion":"bloque","cantidad":1,"precio_unitario":1000}]', 'B');
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id9),
    'CUIT del cliente .* no es válido', 'consumidor final genérico 00000000000: bloqueada');

  -- Cliente que cambia de condición después de cargado el borrador.
  id9 := pg_temp.borrador(pg_temp.cli('20300000011'), '[{"descripcion":"bloque","cantidad":1,"precio_unitario":1000}]', 'A');
  UPDATE clientes SET condicion_iva_afip_id = 5 WHERE id = pg_temp.cli('20300000011');
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id9),
    'le corresponde comprobante B', 'letra distinta de la clase actual del cliente');
  UPDATE clientes SET condicion_iva_afip_id = 6 WHERE id = pg_temp.cli('20300000011');

  UPDATE facturas SET total = total + 1 WHERE id = id2;
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id2),
    'no coinciden con los ítems', 'total editado a mano: bloqueada');
  UPDATE facturas SET total = total - 1, fecha = CURRENT_DATE - 10 WHERE id = id2;
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, id2),
    'fuera de la ventana', 'fecha de hace 10 días: bloqueada');

  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, pg_temp.fac_hist()), 'histórico', 'histórico: no se emite');
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, pg_temp.fac_cae()), 'ya tiene CAE', 'autorizado: no se reemite');
END $$;

\echo '── 6) Ciclo de emisión'
DO $$
DECLARE
  v jsonb; fa int; fb int; fc int;
  hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  req jsonb := '{"FeCabReq":{"CantReg":1},"FeDetReq":{}}';
BEGIN
  fa := pg_temp.borrador(pg_temp.cli('30710000014'), '[{"descripcion":"bloque","cantidad":1,"precio_unitario":100}]', 'A');
  fb := pg_temp.borrador(pg_temp.cli('30710000014'), '[{"descripcion":"bloque","cantidad":1,"precio_unitario":200}]', 'A');
  UPDATE facturas SET fecha = hoy - 3 WHERE id = fa;

  v := pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, fa));
  PERFORM pg_temp.ok(v->>'estado_fiscal' = 'en_proceso' AND v->>'punto_venta' = '1'
    AND (SELECT estado_fiscal = 'en_proceso' AND fecha = hoy FROM facturas WHERE id = fa),
    'reclamar: borrador → en_proceso y la fecha pasa a hoy (Argentina)');
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, fa), 'ya se está emitiendo', 'reclamar dos veces el mismo comprobante');
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, fb), 'otra emisión en curso', 'reclamar otra FAC A de la misma serie');
  PERFORM pg_temp.falla('service_role', format($q$SELECT null::jsonb FROM arca_reservar_numero('facturas', %s, 1)$q$, fb), 'no está en emisión', 'reservar número sin tener la serie');
  PERFORM pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_error_previo('facturas', %s, 'fin de la prueba'))$q$, fa));
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM arca_series_en_curso), 'serie liberada para las pruebas siguientes');
END $$;

DO $$
DECLARE
  v jsonb; fa int; fb int; fc int; vs text;
  req jsonb := '{"FeCabReq":{"CantReg":1},"FeDetReq":{}}';
BEGIN
  fa := pg_temp.borrador(pg_temp.cli('30710000014'), '[{"descripcion":"bloque","cantidad":1,"precio_unitario":100}]', 'A');
  fb := pg_temp.borrador(pg_temp.cli('30710000014'), '[{"descripcion":"bloque","cantidad":1,"precio_unitario":200}]', 'A');
  fc := pg_temp.borrador(pg_temp.cli('28123456'),   '[{"descripcion":"bloque","cantidad":1,"precio_unitario":300}]', 'B');

  -- Autorizado
  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, fa));
  PERFORM pg_temp.como('service_role', format($q$SELECT null::jsonb FROM arca_reservar_numero('facturas', %s, 1)$q$, fa));
  v := pg_temp.como('service_role', format($q$SELECT arca_registrar_cae('facturas', %s, 1, '75000000000001', CURRENT_DATE + 10, 1, 80, '30710000014', %L, '{"Resultado":"A"}')$q$, fa, req));
  PERFORM pg_temp.ok((v->>'registrado')::boolean AND v->>'numero' = '00001-00000001'
    AND (SELECT estado_fiscal = 'autorizado' AND numero = '00001-00000001' AND punto_venta = '00001' AND numero_comp = 1
         AND cae = '75000000000001' AND afip_tipo_comprobante = '001' AND afip_doc_tipo = '80' AND arca_nro_tentativo IS NULL
         FROM facturas WHERE id = fa)
    AND NOT EXISTS (SELECT 1 FROM arca_series_en_curso), 'registrar_cae: número 00001-00000001, CAE, afip_*, serie liberada');
  v := pg_temp.como('service_role', format($q$SELECT arca_registrar_cae('facturas', %s, 1, '75000000000001', CURRENT_DATE + 10, 1, 80, '30710000014', %L, '{}')$q$, fa, req));
  PERFORM pg_temp.ok((v->>'registrado')::boolean AND (SELECT count(*) FROM arca_solicitudes WHERE comprobante_id = fa) = 1,
    'el mismo CAE registrado dos veces: idempotente, sin segunda auditoría');
  vs := (pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_rechazo('facturas', %s, '[{"Code":1,"Msg":"x"}]', NULL, %L, '{}'))$q$, fa, req)))#>>'{}';
  PERFORM pg_temp.ok(vs = 'autorizado', 'un rechazo tardío no pisa un autorizado');

  -- Resultado incierto → reconciliación que confirma que no se autorizó
  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, fb));
  PERFORM pg_temp.como('service_role', format($q$SELECT null::jsonb FROM arca_reservar_numero('facturas', %s, 2)$q$, fb));
  vs := (pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_incierto('facturas', %s, %L, NULL, 'timeout'))$q$, fb, req)))#>>'{}';
  PERFORM pg_temp.ok(vs = 'resultado_incierto' AND EXISTS (SELECT 1 FROM arca_series_en_curso WHERE comprobante_id = fb),
    'timeout: resultado_incierto, conserva número tentativo y serie');
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, fb), 'consultá el estado', 'reintentar un incierto sin reconciliar');
  PERFORM pg_temp.falla('service_role', format($q$SELECT null::jsonb FROM arca_confirmar_no_autorizado('facturas', %s, 2, %L, '{}')$q$, fb, req),
    'pudo haberse usado', 'no se libera si ARCA ya llegó al tentativo');
  PERFORM pg_temp.como('service_role', format($q$SELECT null::jsonb FROM arca_confirmar_no_autorizado('facturas', %s, 1, %L, '{}')$q$, fb, req));
  PERFORM pg_temp.ok((SELECT estado_fiscal = 'borrador' AND arca_nro_tentativo IS NULL FROM facturas WHERE id = fb)
    AND NOT EXISTS (SELECT 1 FROM arca_series_en_curso), 'confirmar_no_autorizado: vuelve a borrador y libera la serie');

  -- Incierto que en realidad se autorizó: la reconciliación recupera el CAE
  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, fb));
  PERFORM pg_temp.como('service_role', format($q$SELECT null::jsonb FROM arca_reservar_numero('facturas', %s, 2)$q$, fb));
  PERFORM pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_incierto('facturas', %s, %L, NULL, 'timeout'))$q$, fb, req));
  v := pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('facturas', %s)$q$, fb));
  PERFORM pg_temp.ok(v->>'nro_tentativo' = '2' AND v->>'punto_venta' = '1', 'para_emitir en incierto: devuelve PV y tentativo para FECompConsultar');
  v := pg_temp.como('service_role', format($q$SELECT arca_registrar_cae('facturas', %s, 2, '75000000000002', CURRENT_DATE + 10, 1, 80, '30710000014', NULL, '{"via":"FECompConsultar"}')$q$, fb));
  PERFORM pg_temp.ok((v->>'registrado')::boolean AND v->>'numero' = '00001-00000002', 'reconciliación: incierto → autorizado con el CAE recuperado');

  -- Error previo y rechazo
  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, fc));
  vs := (pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_error_previo('facturas', %s, 'WSAA no respondió'))$q$, fc)))#>>'{}';
  PERFORM pg_temp.ok(vs = 'borrador' AND NOT EXISTS (SELECT 1 FROM arca_series_en_curso), 'error antes de enviar: vuelve a borrador y libera la serie');
  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, fc));
  PERFORM pg_temp.como('service_role', format($q$SELECT null::jsonb FROM arca_reservar_numero('facturas', %s, 1)$q$, fc));
  vs := (pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_rechazo('facturas', %s, '[{"Code":10016,"Msg":"Fecha invalida"}]', '[{"Code":10063,"Msg":"obs"}]', %L, '{"Resultado":"R"}'))$q$, fc, req)))#>>'{}';
  PERFORM pg_temp.ok(vs = 'rechazado' AND NOT EXISTS (SELECT 1 FROM arca_series_en_curso), 'Resultado R: rechazado y serie liberada');
  v := pg_temp.como('authenticated', format($q$SELECT arca_solicitud_ultimo('facturas', %s)$q$, fc));
  RAISE NOTICE '      arca_solicitud_ultimo (authenticated): %', v;
  PERFORM pg_temp.ok(v->>'estado_fiscal' = 'rechazado' AND v->'ultimo'->'errores'->0->>'Code' = '10016'
    AND NOT v ? 'request' AND NOT v->'ultimo' ? 'request', 'la UI ve estado y errores de ARCA, sin request/response');
  v := pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, fc));
  PERFORM pg_temp.ok(v->>'estado_fiscal' = 'en_proceso', 'un rechazado se puede volver a emitir');

  -- CAE que no coincide con el tentativo: se audita, no se registra, la serie queda bloqueada
  PERFORM pg_temp.como('service_role', format($q$SELECT null::jsonb FROM arca_reservar_numero('facturas', %s, 1)$q$, fc));
  v := pg_temp.como('service_role', format($q$SELECT arca_registrar_cae('facturas', %s, 7, '75000000000007', CURRENT_DATE + 10, 6, 96, '28123456', %L, '{}')$q$, fc, req));
  PERFORM pg_temp.ok(NOT (v->>'registrado')::boolean AND v->>'motivo' LIKE '%tentativo%'
    AND (SELECT estado_fiscal = 'en_proceso' FROM facturas WHERE id = fc)
    AND EXISTS (SELECT 1 FROM arca_series_en_curso WHERE comprobante_id = fc)
    AND (SELECT errores->0->>'Msg' LIKE '%75000000000007%' FROM arca_solicitudes WHERE comprobante_id = fc ORDER BY id DESC LIMIT 1),
    'CAE con número inesperado: no se registra, queda auditado y la serie bloqueada');

  PERFORM pg_temp.ok((SELECT count(*) FROM arca_solicitudes WHERE request ? 'Auth') = 0, 'ninguna auditoría guarda el bloque Auth');
  PERFORM pg_temp.falla('postgres', $q$WITH x AS (INSERT INTO arca_solicitudes (tabla, comprobante_id, resultado, request) VALUES ('facturas', 1, 'rechazado', '{"Auth":{"Token":"x"}}') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$,
    'chk_arca_sol_sin_credenciales', 'la base rechaza auditar credenciales');
END $$;

\echo '── 7) Nota de crédito (CbtesAsoc)'
DO $$
DECLARE v jsonb; n notas;
BEGIN
  -- La FAC A con CAE local (autorizada por el backfill) recibe una NC A con la RPC actual.
  SELECT * INTO n FROM crear_nota(pg_temp.fac_cae(), 'NC', '[{"descripcion":"devolución","cantidad":1,"precio_unitario":50}]');
  UPDATE notas SET numero = NULL, punto_venta = NULL, numero_comp = NULL, estado_fiscal = 'borrador' WHERE id = n.id;
  v := pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('notas', %s)$q$, n.id));
  RAISE NOTICE '      NC A: cbte_tipo %, CbtesAsoc %', v->'cbte_tipo', v->'det'->'CbtesAsoc';
  PERFORM pg_temp.ok(v->>'cbte_tipo' = '3' AND v->'det'->'CbtesAsoc'->0->>'Tipo' = '1'
    AND (v->'det'->'CbtesAsoc'->0->>'PtoVta', v->'det'->'CbtesAsoc'->0->>'Nro')
        = (SELECT punto_venta::int::text, numero_comp::text FROM facturas WHERE id = pg_temp.fac_cae())
    AND NOT (v->>'verificar_asociado')::boolean, 'NC A sobre FAC A autorizada: tipo 3, CbtesAsoc con tipo 1, su PV y su número');
  SELECT * INTO n FROM crear_nota(pg_temp.fac_hist(), 'NC', '[{"descripcion":"devolución","cantidad":1,"precio_unitario":50}]');
  UPDATE notas SET numero = NULL, punto_venta = NULL, numero_comp = NULL, estado_fiscal = 'borrador' WHERE id = n.id;
  v := pg_temp.como('service_role', format($q$SELECT arca_comprobante_para_emitir('notas', %s)$q$, n.id));
  PERFORM pg_temp.ok((v->>'verificar_asociado')::boolean, 'NC sobre factura histórica sin CAE: verificar_asociado = true');
  UPDATE notas SET tipo_letra = 'B' WHERE id = n.id;
  PERFORM pg_temp.falla('service_role', format($q$SELECT arca_comprobante_para_emitir('notas', %s)$q$, n.id), 'no puede asociarse|le corresponde', 'NC B sobre una Factura A: bloqueada');
END $$;

\echo '── 8) Ticket WSAA'
DO $$
DECLARE v jsonb;
BEGIN
  v := pg_temp.como('service_role', $q$SELECT arca_token_get('wsfe', 60)$q$);
  PERFORM pg_temp.ok((v->>'renovar')::boolean, 'sin TA: el primero recibe el turno de renovar');
  v := pg_temp.como('service_role', $q$SELECT arca_token_get('wsfe', 60)$q$);
  PERFORM pg_temp.ok((v->>'esperar')::boolean, 'mientras otro renueva: esperar');
  PERFORM pg_temp.como('service_role', $q$SELECT null::jsonb FROM arca_token_set('wsfe', 'TOKEN', 'SIGN', now() + interval '12 hours')$q$);
  v := pg_temp.como('service_role', $q$SELECT arca_token_get('wsfe', 60)$q$);
  PERFORM pg_temp.ok(v->>'token' = 'TOKEN' AND v->>'sign' = 'SIGN', 'con TA vigente: se devuelve del cache');
  PERFORM pg_temp.como('service_role', $q$SELECT null::jsonb FROM arca_token_set('wsfe', 'TOKEN', 'SIGN', now() + interval '30 seconds')$q$);
  v := pg_temp.como('service_role', $q$SELECT arca_token_get('wsfe', 60)$q$);
  PERFORM pg_temp.ok((v->>'renovar')::boolean, 'TA a punto de vencer (menos que el margen): turno de renovar');
END $$;

\echo '── 9) Lecturas como authenticated'
DO $$
DECLARE v jsonb;
BEGIN
  v := pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM clientes_list('30-7100') x$q$);
  PERFORM pg_temp.ok(jsonb_array_length(v) = 2 AND v->0 ? 'doc_nro' AND v->0 ? 'clase' AND v->0->>'condicion_iva' IS NOT NULL
    AND NOT v->0 ? 'cuit', 'clientes_list busca por CUIT con guiones y devuelve doc + condición del catálogo + clase');
  v := pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM clientes_list('28.123') x$q$);
  PERFORM pg_temp.ok(jsonb_array_length(v) = 1, 'clientes_list busca por DNI con puntos');
  v := pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM clientes_list('PRUEBA Mono') x$q$);
  PERFORM pg_temp.ok(jsonb_array_length(v) = 1 AND v->0->>'clase' = 'A', 'clientes_list busca por nombre (sin dígitos no filtra por documento)');
  v := pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM facturas_list(p_q => '28123456') x$q$);
  PERFORM pg_temp.ok(jsonb_array_length(v) >= 1 AND v->0->>'doc_tipo' = '96' AND v->0->>'condicion_iva' = 'Consumidor Final',
    'facturas_list por documento, con doc y condición');
  v := pg_temp.como('authenticated', format($q$SELECT informe_cta_cte(%s)$q$, pg_temp.cli('30710000014')));
  PERFORM pg_temp.ok(v->'cliente'->>'condicion_iva' = 'IVA Responsable Inscripto' AND v->'cliente'->>'clase' = 'A'
    AND v->'cliente'->>'doc_nro' = '30710000014', 'informe_cta_cte: cliente con descripción del catálogo y clase');
  PERFORM pg_temp.ok(pg_temp.como('authenticated', $q$SELECT informe_libro_iva_ventas(CURRENT_DATE - 30, CURRENT_DATE + 1)$q$)->'comprobantes'->0 ? 'doc_nro',
    'informe_libro_iva_ventas devuelve doc_nro');
  PERFORM pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM notas_list() x$q$);
  PERFORM pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM remitos_list() x$q$);
  PERFORM pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM recibos_list() x$q$);
  PERFORM pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM presupuestos_list() x$q$);
  PERFORM pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM informe_ranking_clientes() x$q$);
  PERFORM pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM informe_ranking_deudores() x$q$);
  PERFORM pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM informe_remitos_pendientes_facturar() x$q$);
  PERFORM pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM informe_facturas_pendientes_remitir() x$q$);
  PERFORM pg_temp.como('authenticated', $q$SELECT informe_ventas(CURRENT_DATE - 30, CURRENT_DATE + 1)$q$);
  PERFORM pg_temp.como('authenticated', $q$SELECT informe_dashboard()$q$);
  PERFORM pg_temp.ok(true, 'notas/remitos/recibos/presupuestos_list, rankings, pendientes, informe_ventas y dashboard corren sin error');
END $$;

ROLLBACK;
\echo '── Fin: ROLLBACK (homologación queda con los datos sintéticos de base)'
