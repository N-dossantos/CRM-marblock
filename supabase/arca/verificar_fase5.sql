-- =============================================================
-- PLAN_ARCA — verificación de la Fase 5 en la base (bandeja fiscal: filtro por estado fiscal en
-- facturas_list, estado de la factura asociada en notas_list y contadores de arca_bandeja) en
-- HOMOLOGACIÓN. La UI (emitir, rechazo, incierto, banner) se prueba aparte, en el navegador.
--
-- Uso (nunca contra prod), con 20261015160000 ya aplicada:
--   psql "$(cat ~/.arca/marblock/homo_db_url)" -X -f supabase/arca/verificar_fase5.sql
--
-- Corre todo en una transacción y termina con ROLLBACK: no deja nada en la base. Cada control
-- imprime "OK …"; el primero que falla corta con "FALLA …". Usa los datos sintéticos de
-- homologación (ver verificar_fase2.sql): el cliente RI 30710000014 y sus facturas.
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

-- Cantidad de filas y estados fiscales distintos que devuelve facturas_list con un filtro, como
-- la llama el frontend (authenticated).
CREATE FUNCTION pg_temp.lista(p_args text) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  RETURN pg_temp.como('authenticated', format(
    $q$SELECT jsonb_build_object('n', count(*),
         'estados', COALESCE(jsonb_agg(DISTINCT x->>'estado_fiscal'), '[]'),
         'total_filas', max((x->>'total_filas')::int))
       FROM facturas_list(%s) x$q$, p_args));
END $$;

CREATE FUNCTION pg_temp.bandeja() RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.como('authenticated', 'SELECT arca_bandeja()') $$;

\echo '── 1) Firma y permisos'
DO $$
BEGIN
  PERFORM pg_temp.ok((SELECT count(*) FROM pg_proc WHERE proname = 'facturas_list'
                        AND pronamespace = 'public'::regnamespace) = 1,
    'facturas_list tiene una sola versión (la anterior se borró)');
  PERFORM pg_temp.ok(has_function_privilege('authenticated',
      'facturas_list(integer, text, text, text, integer, date, date, boolean, integer, integer, text[])', 'EXECUTE')
    AND NOT has_function_privilege('anon',
      'facturas_list(integer, text, text, text, integer, date, date, boolean, integer, integer, text[])', 'EXECUTE'),
    'facturas_list: authenticated sí, anon no');
  PERFORM pg_temp.ok(has_function_privilege('authenticated', 'arca_bandeja()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'arca_bandeja()', 'EXECUTE'),
    'arca_bandeja: authenticated sí, anon no');
  PERFORM pg_temp.ok(has_function_privilege('authenticated', 'notas_list(integer, text, text, integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'notas_list(integer, text, text, integer)', 'EXECUTE'),
    'notas_list conserva sus permisos');
END $$;

\echo '── 2) Un borrador nuevo entra en la bandeja'
CREATE TEMP TABLE antes AS SELECT pg_temp.bandeja() AS b;
CREATE TEMP TABLE ids (nombre text PRIMARY KEY, id int);
DO $$
DECLARE
  cli int := (SELECT id FROM clientes WHERE doc_nro = '30710000014');
  f   int;
  b0  jsonb := (SELECT b FROM antes);
  b1  jsonb;
BEGIN
  f := (pg_temp.como('authenticated', format(
    $q$SELECT to_jsonb(crear_factura(%s, '[{"descripcion":"bandeja","cantidad":1,"precio_unitario":100}]'::jsonb, 'A'))$q$,
    cli))->>'id')::int;
  INSERT INTO ids VALUES ('fac', f);
  b1 := pg_temp.bandeja();
  PERFORM pg_temp.ok((b1->'facturas'->>'borrador')::int = (b0->'facturas'->>'borrador')::int + 1,
    'crear_factura suma un borrador en arca_bandeja');
  PERFORM pg_temp.ok((SELECT bool_or((x->>'id')::int = f) FROM jsonb_array_elements(
      pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM facturas_list(p_estado_fiscal => '{borrador}') x$q$)) x),
    'el borrador aparece filtrando por borrador');
  PERFORM pg_temp.ok(NOT COALESCE((SELECT bool_or((x->>'id')::int = f) FROM jsonb_array_elements(
      pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM facturas_list(p_estado_fiscal => '{autorizado,historico}') x$q$)) x), false),
    'y no filtrando por autorizado/histórico (selector de factura de las NC/ND)');
END $$;

\echo '── 3) facturas_list: filtro por estado fiscal'
DO $$
DECLARE v jsonb;
BEGIN
  v := pg_temp.lista('p_estado_fiscal => NULL');
  PERFORM pg_temp.ok((v->>'n')::int = (SELECT count(*) FROM facturas), 'sin filtro devuelve todas');

  v := pg_temp.lista($a$p_estado_fiscal => '{borrador}'$a$);
  PERFORM pg_temp.ok(v->'estados' = '["borrador"]' AND (v->>'n')::int = (SELECT count(*) FROM facturas WHERE estado_fiscal = 'borrador'),
    format('sólo borradores (%s)', v->>'n'));

  v := pg_temp.lista($a$p_estado_fiscal => '{borrador,rechazado,resultado_incierto,en_proceso}'$a$);
  PERFORM pg_temp.ok((v->>'n')::int = (SELECT count(*) FROM facturas WHERE estado_fiscal NOT IN ('historico','autorizado'))
    AND NOT v->'estados' ?| ARRAY['historico','autorizado'],
    format('sin CAE: los cuatro estados, ni histórico ni autorizado (%s)', v->>'n'));

  v := pg_temp.lista($a$p_estado_fiscal => '{autorizado,historico}'$a$);
  PERFORM pg_temp.ok((v->>'n')::int = (SELECT count(*) FROM facturas WHERE estado_fiscal IN ('historico','autorizado'))
    AND v->'estados' <@ '["autorizado","historico"]',
    format('fiscales: autorizadas e históricas (%s)', v->>'n'));

  v := pg_temp.lista($a$p_estado_fiscal => '{borrador}', p_limit => 1$a$);
  PERFORM pg_temp.ok((v->>'n')::int = 1
    AND (v->>'total_filas')::int = (SELECT count(*) FROM facturas WHERE estado_fiscal = 'borrador'),
    'paginado: total_filas cuenta el filtro, no la página');

  v := pg_temp.lista($a$p_estado => 'pendiente', p_estado_fiscal => '{borrador}'$a$);
  PERFORM pg_temp.ok((v->>'n')::int = 0, 'el estado de cobranza sigue siendo sólo de lo fiscal');
END $$;

\echo '── 4) arca_bandeja coincide con la tabla'
DO $$
DECLARE
  b jsonb := pg_temp.bandeja();
  e text;
BEGIN
  FOREACH e IN ARRAY ARRAY['borrador','rechazado','resultado_incierto','en_proceso'] LOOP
    PERFORM pg_temp.ok((b->'facturas'->>e)::int = (SELECT count(*) FROM facturas WHERE estado_fiscal = e)
      AND (b->'notas'->>e)::int = (SELECT count(*) FROM notas WHERE estado_fiscal = e),
      format('%s: facturas %s, notas %s', e, b->'facturas'->>e, b->'notas'->>e));
  END LOOP;
END $$;

\echo '── 5) Rechazado e incierto, por las RPCs de la Edge Function'
DO $$
DECLARE
  f  int := (SELECT id FROM ids WHERE nombre = 'fac');
  b0 jsonb := pg_temp.bandeja();
  b1 jsonb;
BEGIN
  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, f));
  b1 := pg_temp.bandeja();
  PERFORM pg_temp.ok((b1->'facturas'->>'en_proceso')::int = (b0->'facturas'->>'en_proceso')::int + 1
    AND (b1->'facturas'->>'borrador')::int = (b0->'facturas'->>'borrador')::int - 1,
    'reclamada: pasa de borrador a en emisión');

  PERFORM pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_rechazo('facturas', %s,
    '[{"Code":10243,"Msg":"prueba"}]'::jsonb, NULL, NULL, NULL))$q$, f));
  b1 := pg_temp.bandeja();
  PERFORM pg_temp.ok((b1->'facturas'->>'rechazado')::int = (b0->'facturas'->>'rechazado')::int + 1,
    'rechazada: cuenta como rechazado');
  PERFORM pg_temp.ok((SELECT bool_or((x->>'id')::int = f) FROM jsonb_array_elements(
      pg_temp.como('authenticated', $q$SELECT jsonb_agg(x) FROM facturas_list(p_estado_fiscal => '{rechazado}') x$q$)) x),
    'y aparece filtrando por rechazado');

  PERFORM pg_temp.como('service_role', format($q$SELECT arca_reclamar_serie('facturas', %s, 1)$q$, f));
  PERFORM pg_temp.como('service_role', format($q$SELECT null::jsonb FROM arca_reservar_numero('facturas', %s, 999)$q$, f));
  PERFORM pg_temp.como('service_role', format($q$SELECT to_jsonb(arca_registrar_incierto('facturas', %s, NULL, NULL, 'prueba'))$q$, f));
  b1 := pg_temp.bandeja();
  PERFORM pg_temp.ok((b1->'facturas'->>'resultado_incierto')::int = (b0->'facturas'->>'resultado_incierto')::int + 1,
    'incierta: cuenta como resultado incierto');
END $$;

\echo '── 6) notas_list: estado fiscal de la factura asociada'
DO $$
DECLARE v jsonb;
BEGIN
  v := pg_temp.como('authenticated', 'SELECT jsonb_agg(x) FROM notas_list() x');
  PERFORM pg_temp.ok(jsonb_array_length(v) = (SELECT count(*) FROM notas), 'notas_list devuelve todas las notas');
  PERFORM pg_temp.ok(NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v) x
      LEFT JOIN facturas f ON f.id = (x->>'factura_id')::int
      WHERE (x->>'factura_estado_fiscal') IS DISTINCT FROM f.estado_fiscal::text),
    'factura_estado_fiscal coincide con el de la factura en cada nota');
  PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE x->>'factura_estado_fiscal' = 'historico')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE x->>'factura_estado_fiscal' = 'autorizado'),
    'hay notas sobre facturas históricas y sobre autorizadas (datos de la Fase 4)');
END $$;

ROLLBACK;
\echo '── Fin: ROLLBACK (homologación queda con los datos sintéticos de base)'
