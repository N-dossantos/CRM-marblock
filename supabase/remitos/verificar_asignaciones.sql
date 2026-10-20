-- =============================================================
-- PLAN_REMITOS_PENDIENTES — verificación en la base de las asignaciones remito–factura y del
-- cálculo de lo pendiente de remitir (PLAN_MAESTRO §3.11), en HOMOLOGACIÓN.
--
-- No se corre suelto: lo incluyen los envoltorios, que ponen el BEGIN y el ROLLBACK.
--   ensayo.sql    con las migraciones todavía sin aplicar (las aplica dentro de la transacción);
--   verificar.sql con las migraciones ya aplicadas.
--   psql "$(cat ~/.arca/marblock/homo_db_url)" -X -f supabase/remitos/ensayo.sql
--
-- ⚠ Crea clientes, facturas, notas y remitos de prueba: NUNCA contra producción. En prod sólo
-- corre verificar_backfill.sql (sólo lectura), dentro de ensayo_prod.sql.
--
-- Cada control imprime "OK …"; el primero que falla corta con "FALLA …". La fixture de arriba
-- (dos clientes y las facturas F1–F9) la usan todas las secciones; cada sección arma sus propios
-- remitos, salvo donde dice lo contrario.
-- =============================================================
\set ON_ERROR_STOP 1
\set QUIET 1
SET client_min_messages = notice;

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

-- ── Fixture ──────────────────────────────────────────────────────
-- ids: clientes, productos (por marca), facturas y remitos de la prueba, por nombre.
CREATE TEMP TABLE ids (nombre text PRIMARY KEY, id int);

CREATE FUNCTION pg_temp.id(p_nombre text) RETURNS int LANGUAGE sql AS $$
  SELECT id FROM ids WHERE nombre = p_nombre $$;

-- Clave de emparejamiento de un producto de la fixture ('bloque', 'pallet', 'transp').
CREATE FUNCTION pg_temp.k(p_nombre text) RETURNS text LANGUAGE sql AS $$
  SELECT 'p' || pg_temp.id(p_nombre) $$;

-- Renglones como jsonb: [{"p": "bloque", "c": 100, "precio": 2}] o, sin producto,
-- [{"d": "Bloque Hueco 12", "c": 100}]. Devuelve (producto_id, descripcion, cantidad, precio).
CREATE FUNCTION pg_temp.renglones(p_items jsonb)
RETURNS TABLE (orden int, producto_id int, descripcion text, cantidad numeric, precio numeric)
LANGUAGE sql AS $$
  SELECT x.n::int, pg_temp.id(x.it->>'p'),
         COALESCE(x.it->>'d', (SELECT pr.descripcion FROM productos pr WHERE pr.id = pg_temp.id(x.it->>'p'))),
         (x.it->>'c')::numeric, COALESCE((x.it->>'precio')::numeric, 1000)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY x(it, n) $$;

-- Factura A del PV 09999, con estado de cobranza 'pendiente'. Un borrador no tiene número.
CREATE FUNCTION pg_temp.factura(p_cliente int, p_comp int, p_estado_fiscal text, p_items jsonb)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_borrador boolean := p_estado_fiscal = 'borrador';
  v_id int;
BEGIN
  INSERT INTO facturas (numero, punto_venta, numero_comp, tipo, fecha, cliente_id, estado, estado_fiscal)
  VALUES (CASE WHEN NOT v_borrador THEN '09999-' || lpad(p_comp::text, 8, '0') END,
          CASE WHEN NOT v_borrador THEN '09999' END,
          CASE WHEN NOT v_borrador THEN p_comp END,
          'A', CURRENT_DATE, p_cliente, 'pendiente', p_estado_fiscal)
  RETURNING id INTO v_id;
  INSERT INTO factura_items (factura_id, producto_id, descripcion, cantidad, precio_unitario, subtotal, orden)
  SELECT v_id, r.producto_id, r.descripcion, r.cantidad, r.precio, r.cantidad * r.precio, r.orden
  FROM pg_temp.renglones(p_items) r;
  RETURN v_id;
END $$;

-- Nota de crédito o de débito ('NC' / 'ND') A histórica (PV 09999) de una factura.
CREATE FUNCTION pg_temp.nota(p_tipo text, p_factura int, p_comp int, p_items jsonb)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_id int;
BEGIN
  INSERT INTO notas (numero, punto_venta, numero_comp, tipo, tipo_letra, fecha, factura_id, cliente_id, estado_fiscal)
  SELECT '09999-' || lpad(p_comp::text, 8, '0'), '09999', p_comp, p_tipo, 'A', CURRENT_DATE, f.id, f.cliente_id, 'historico'
  FROM facturas f WHERE f.id = p_factura
  RETURNING id INTO v_id;
  INSERT INTO nota_items (nota_id, producto_id, descripcion, cantidad, precio_unitario, subtotal, orden)
  SELECT v_id, r.producto_id, r.descripcion, r.cantidad, r.precio, r.cantidad * r.precio, r.orden
  FROM pg_temp.renglones(p_items) r;
  RETURN v_id;
END $$;

CREATE FUNCTION pg_temp.nc(p_factura int, p_comp int, p_items jsonb) RETURNS int LANGUAGE sql AS $$
  SELECT pg_temp.nota('NC', p_factura, p_comp, p_items) $$;

-- Remito del PV 09999 al cliente de la factura, con factura_id = esa factura y una asignación por
-- renglón (cantidad > 0) con el origen dado: INSERT directo, sin pasar por las RPC.
CREATE FUNCTION pg_temp.remito(p_factura int, p_items jsonb, p_origen text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_comp int := (SELECT count(*) + 1 FROM remitos WHERE punto_venta = '09999');
  v_id int;
BEGIN
  INSERT INTO remitos (numero, punto_venta, numero_comp, fecha, cliente_id, factura_id, estado)
  SELECT '09999-' || lpad(v_comp::text, 8, '0'), '09999', v_comp, CURRENT_DATE, f.cliente_id, f.id,
         CASE WHEN p_origen = 'tango' THEN 'facturado' ELSE 'pendiente' END
  FROM facturas f WHERE f.id = p_factura
  RETURNING id INTO v_id;
  WITH ri AS (
    INSERT INTO remito_items (remito_id, producto_id, descripcion, cantidad, orden)
    SELECT v_id, r.producto_id, r.descripcion, r.cantidad, r.orden
    FROM pg_temp.renglones(p_items) r
    RETURNING id, cantidad
  )
  INSERT INTO remito_item_facturas (remito_item_id, factura_id, cantidad, origen)
  SELECT ri.id, p_factura, ri.cantidad, p_origen FROM ri WHERE ri.cantidad > 0;
  RETURN v_id;
END $$;

-- Remito que vino de Tango: como los que asigna el backfill.
CREATE FUNCTION pg_temp.remito_tango(p_factura int, p_items jsonb) RETURNS int LANGUAGE sql AS $$
  SELECT pg_temp.remito(p_factura, p_items, 'tango') $$;

-- La fila de facturas_pendientes_remitir de una factura, como la llama el frontend
-- (authenticated, con el cliente de la factura). NULL si la factura no aparece.
CREATE FUNCTION pg_temp.fila(p_factura int, p_excluir int DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  RETURN pg_temp.como('authenticated', format(
    $q$SELECT x FROM facturas_pendientes_remitir(%s, %s) x WHERE (x->>'id')::int = %s$q$,
    (SELECT cliente_id FROM facturas WHERE id = p_factura), COALESCE(p_excluir::text, 'NULL'), p_factura));
END $$;

-- Lo pendiente de una factura como {clave: pendiente}. NULL si la factura no aparece.
CREATE FUNCTION pg_temp.pend(p_factura int, p_excluir int DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_object_agg(i->>'clave', (i->>'pendiente')::numeric)
  FROM jsonb_array_elements(pg_temp.fila(p_factura, p_excluir)->'items') i $$;

DO $$
DECLARE cli int; otro int;
BEGIN
  INSERT INTO clientes (razon_social, doc_tipo, doc_nro, condicion_iva_afip_id)
  VALUES ('PRUEBA REMITOS', 80, '20999999990', 1) RETURNING id INTO cli;
  INSERT INTO clientes (razon_social, doc_tipo, doc_nro, condicion_iva_afip_id)
  VALUES ('PRUEBA OTRO', 80, '20999999981', 1) RETURNING id INTO otro;
  INSERT INTO ids VALUES
    ('cli', cli), ('otro', otro),
    ('bloque', (SELECT id FROM productos WHERE unidades_por_pallet = 105 ORDER BY id LIMIT 1)),
    ('pallet', (SELECT id FROM productos WHERE es_pallet_vacio ORDER BY id LIMIT 1)),
    ('transp', (SELECT id FROM productos WHERE es_transporte ORDER BY id LIMIT 1));

  INSERT INTO ids VALUES
    ('f1', pg_temp.factura(cli, 1, 'historico',
       '[{"p":"bloque","c":25200},{"p":"pallet","c":240},{"p":"transp","c":10}]')),
    ('f2', pg_temp.factura(cli, 2, 'borrador',  '[{"p":"bloque","c":100}]')),
    ('f3', pg_temp.factura(cli, 3, 'historico', '[{"p":"bloque","c":100}]')),
    ('f4', pg_temp.factura(cli, 4, 'historico', '[{"p":"bloque","c":300}]')),
    ('f5', pg_temp.factura(cli, 5, 'historico',
       '[{"p":"bloque","c":100,"precio":1},{"p":"bloque","c":50,"precio":2}]')),
    ('f6', pg_temp.factura(cli, 6, 'historico', '[{"d":"Bloque Hueco 12","c":100}]')),
    ('f7', pg_temp.factura(cli, 7, 'historico', '[{"p":"bloque","c":1000}]')),
    ('f8', pg_temp.factura(cli, 8, 'historico', '[{"p":"bloque","c":500}]')),
    ('f9', pg_temp.factura(otro, 9, 'historico', '[{"p":"bloque","c":100}]'));
  UPDATE facturas SET estado = 'anulada' WHERE id = pg_temp.id('f3');
END $$;

\echo '── 1) Tabla, permisos y backfill'
DO $$
DECLARE v_esperado bigint; v_sobran bigint; v_faltan bigint;
BEGIN
  PERFORM pg_temp.ok(
    (SELECT relrowsecurity AND NOT relforcerowsecurity FROM pg_class WHERE oid = 'remito_item_facturas'::regclass)
    AND EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'remito_item_facturas' AND policyname = 'staff_all')
    AND NOT has_table_privilege('anon', 'remito_item_facturas', 'SELECT')
    AND NOT has_sequence_privilege('anon', 'remito_item_facturas_id_seq', 'USAGE'),
    '1.1 remito_item_facturas: RLS sin FORCE, policy staff_all, anon sin SELECT ni secuencia');

  PERFORM pg_temp.ok(
    has_function_privilege('authenticated', 'facturas_pendientes_remitir(integer, integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'facturas_pendientes_remitir(integer, integer)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'crm_remito_recalcular(integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'crm_remito_recalcular(integer)', 'EXECUTE'),
    '1.2 facturas_pendientes_remitir: authenticated sí, anon no; crm_remito_recalcular: ninguno de los dos');

  -- Fila por fila (EXCEPT ALL en los dos sentidos, para que también cuenten los duplicados): las
  -- asignaciones 'tango' contra los renglones > 0 de remitos no anulados con factura. Los remitos
  -- con asignaciones 'remito' o 'factura' los armaron las RPC después del backfill. En ensayo.sql
  -- la semilla (semilla_backfill.sql) pone al menos dos renglones y un remito anulado.
  CREATE TEMP TABLE esperado_tango AS
  SELECT ri.id AS remito_item_id, r.factura_id, ri.cantidad::numeric AS cantidad
  FROM remito_items ri JOIN remitos r ON r.id = ri.remito_id
  WHERE ri.cantidad > 0 AND r.estado <> 'anulado' AND r.factura_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM remito_item_facturas x JOIN remito_items xi ON xi.id = x.remito_item_id
                    WHERE xi.remito_id = r.id AND x.origen IN ('remito','factura'));
  SELECT count(*) INTO v_esperado FROM esperado_tango;
  SELECT count(*) INTO v_sobran FROM (
    SELECT remito_item_id, factura_id, cantidad FROM remito_item_facturas WHERE origen = 'tango'
    EXCEPT ALL
    SELECT remito_item_id, factura_id, cantidad FROM esperado_tango) x;
  SELECT count(*) INTO v_faltan FROM (
    SELECT remito_item_id, factura_id, cantidad FROM esperado_tango
    EXCEPT ALL
    SELECT remito_item_id, factura_id, cantidad FROM remito_item_facturas WHERE origen = 'tango') x;
  PERFORM pg_temp.ok(v_sobran = 0 AND v_faltan = 0,
    format('1.3 backfill: una asignación ''tango'' por renglón > 0 de remito no anulado con factura, '
           'con su factura y su cantidad (%s filas comparadas; sobran %s, faltan %s)', v_esperado, v_sobran, v_faltan));
END $$;

\echo '── 2) Cálculo de lo pendiente'
DO $$
DECLARE
  f1 int := pg_temp.id('f1');
  f6 int := pg_temp.id('f6');
  r22 int;
  r29 int;
  v jsonb;
BEGIN
  PERFORM pg_temp.ok(pg_temp.pend(f1) = jsonb_build_object(
      pg_temp.k('bloque'), 25200, pg_temp.k('pallet'), 240, pg_temp.k('transp'), 10),
    '2.1 F1 sin remitos: bloque 25200, pallet 240, transporte 10');

  r22 := pg_temp.remito_tango(f1, '[{"p":"bloque","c":2520},{"p":"pallet","c":24}]');
  INSERT INTO ids VALUES ('r22', r22);
  PERFORM pg_temp.ok(pg_temp.pend(f1) = jsonb_build_object(
      pg_temp.k('bloque'), 22680, pg_temp.k('pallet'), 216, pg_temp.k('transp'), 10),
    '2.2 remito de 2520 bloques y 24 pallets: quedan 22680 y 216');

  PERFORM pg_temp.nc(f1, 1, '[{"p":"bloque","c":1050}]');
  PERFORM pg_temp.ok((pg_temp.pend(f1)->>pg_temp.k('bloque'))::numeric = 21630,
    '2.3 NC de 1050 bloques: quedan 21630');
  PERFORM pg_temp.nc(f1, 2, '[{"d":"Gastos Bancarios","c":1}]');
  PERFORM pg_temp.ok(pg_temp.pend(f1) = jsonb_build_object(
      pg_temp.k('bloque'), 21630, pg_temp.k('pallet'), 216, pg_temp.k('transp'), 10),
    '2.3 NC sin producto (Gastos Bancarios): no cambia nada');
  -- Las dos de abajo tienen la clave de un renglón pendiente: si se contaran, también fallarían
  -- 2.7 y 2.9 (F6) y 2.8 (F1).
  PERFORM pg_temp.nc(f6, 3, '[{"d":"Bloque Hueco 12","c":5}]');
  PERFORM pg_temp.ok(pg_temp.pend(f6) = '{"dbloque hueco 12": 100}',
    '2.3 NC sin producto con la descripción del renglón de F6 (Bloque Hueco 12 por 5): no cambia nada');
  PERFORM pg_temp.nota('ND', f1, 1, '[{"p":"bloque","c":100}]');
  PERFORM pg_temp.ok(pg_temp.pend(f1) = jsonb_build_object(
      pg_temp.k('bloque'), 21630, pg_temp.k('pallet'), 216, pg_temp.k('transp'), 10),
    '2.3 ND con producto (100 bloques en F1): no cambia nada');

  PERFORM pg_temp.ok(pg_temp.fila(pg_temp.id('f2')) IS NULL AND pg_temp.fila(pg_temp.id('f3')) IS NULL,
    '2.4 F2 (borrador) y F3 (anulada) no aparecen');

  PERFORM pg_temp.remito_tango(pg_temp.id('f4'), '[{"p":"bloque","c":600}]');
  PERFORM pg_temp.ok(pg_temp.fila(pg_temp.id('f4')) IS NULL,
    '2.5 F4 remitida de más (600 de 300): no aparece');

  v := pg_temp.fila(pg_temp.id('f5'));
  PERFORM pg_temp.ok(jsonb_array_length(v->'items') = 1 AND (v->'items'->0->>'facturado')::numeric = 150,
    '2.6 F5 con el mismo producto en dos renglones: una sola fila, facturado 150');

  PERFORM pg_temp.remito_tango(f6, '[{"d":"  bloque hueco 12 ","c":40}]');
  PERFORM pg_temp.ok(pg_temp.pend(f6) = '{"dbloque hueco 12": 60}',
    '2.7 renglón sin producto con espacios y minúsculas: empareja, quedan 60 en "dbloque hueco 12"');

  UPDATE remitos SET estado = 'anulado' WHERE id = r22;
  PERFORM pg_temp.ok(pg_temp.pend(f1) = jsonb_build_object(
      pg_temp.k('bloque'), 24150, pg_temp.k('pallet'), 240, pg_temp.k('transp'), 10),
    '2.8 anulado el remito de 2.2: vuelve a 24150 bloques (25200 − 1050) y 240 pallets');

  r29 := pg_temp.remito(f6, '[{"d":"Bloque Hueco 12","c":10}]', 'remito');
  INSERT INTO ids VALUES ('r29', r29);
  PERFORM pg_temp.ok(pg_temp.pend(f6) = '{"dbloque hueco 12": 50}',
    '2.9 remito con asignación ''remito'' de 10: F6 queda en 50');
  PERFORM pg_temp.ok(pg_temp.pend(f6, r29) = '{"dbloque hueco 12": 60}',
    '2.9 excluyendo ese remito (edición): F6 vuelve a 60');
END $$;
