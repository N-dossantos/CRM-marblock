-- =============================================================
-- PLAN_REMITOS_PENDIENTES — control del backfill de remito_item_facturas contra los datos reales
-- de PRODUCCIÓN (PLAN_MAESTRO §3.11, "Verificación"). Sólo lectura.
--
-- Lo incluye ensayo_prod.sql, que aplica las migraciones dentro de una transacción y termina con
-- ROLLBACK. Con las migraciones ya aplicadas también se puede correr suelto:
--   psql "$(cat .db_url)" -X -f supabase/remitos/verificar_backfill.sql
--
-- Los números son los de la carga de Tango (.bak del 16/10, medidos el 20/10): las 262 facturas
-- con algo pendiente, las 26 de 2026 que revisó Nico, y la 2296 y la 2230 de Almajo. Un remito,
-- una factura o una NC cargados después los pueden mover. Contra homologación fallan: no tiene
-- esos datos.
-- =============================================================
\set ON_ERROR_STOP 1
\set QUIET 1
SET client_min_messages = notice;

CREATE FUNCTION pg_temp.ok(c boolean, m text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF c IS TRUE THEN RAISE NOTICE 'OK    %', m; ELSE RAISE EXCEPTION 'FALLA %', m; END IF;
END $$;

\echo '── Facturas pendientes de remitir'
DO $$
DECLARE
  v_total int;
  v_2026  int;
BEGIN
  SELECT count(DISTINCT p.factura_id),
         count(DISTINCT p.factura_id) FILTER (WHERE f.fecha >= '2026-01-01' AND f.fecha < '2027-01-01')
    INTO v_total, v_2026
  FROM crm_facturas_pendientes(NULL) p
  JOIN facturas f ON f.id = p.factura_id;
  PERFORM pg_temp.ok(v_total = 262, format('facturas con algo pendiente de remitir: %s (se esperan 262)', v_total));
  PERFORM pg_temp.ok(v_2026 = 26, format('de 2026: %s (se esperan 26)', v_2026));
END $$;

\echo '── Almajo: FAC A 2296 y 2230'
DO $$
DECLARE
  r record;
  v_bloques numeric;
  v_pallets numeric;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      (8699, '00002-00002296', 25200, 240),
      (8564, '00002-00002230',  4830,  46)) t(id, numero, bloques, pallets)
  LOOP
    PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM facturas WHERE id = r.id AND tipo = 'A' AND numero = r.numero),
      format('la factura %s es la A %s', r.id, r.numero));

    -- Pallets de madera por un lado; bloques y adoquines (ni pallet ni transporte) por el otro.
    SELECT COALESCE(sum(p.pendiente) FILTER (WHERE pr.es_pallet_vacio), 0),
           COALESCE(sum(p.pendiente) FILTER (WHERE NOT COALESCE(pr.es_pallet_vacio, false)
                                               AND NOT COALESCE(pr.es_transporte, false)), 0)
      INTO v_pallets, v_bloques
    FROM crm_facturas_pendientes((SELECT cliente_id FROM facturas WHERE id = r.id)) p
    LEFT JOIN productos pr ON pr.id = p.producto_id
    WHERE p.factura_id = r.id;
    PERFORM pg_temp.ok(v_bloques = r.bloques AND v_pallets = r.pallets,
      format('A %s: pendientes %s bloques y %s pallets (se esperan %s y %s)',
             r.numero, v_bloques, v_pallets, r.bloques, r.pallets));
  END LOOP;
END $$;

\echo '── Estado de los remitos (informativo, no falla)'
-- Misma regla que crm_remito_recalcular, en un SELECT para no escribir en remitos: 'facturado' si
-- cada renglón está asignado a facturas no anuladas, históricas o con CAE, por toda su cantidad.
DO $$
DECLARE v record;
BEGIN
  WITH calc AS (
    SELECT r.estado AS guardado,
      CASE WHEN NOT EXISTS (
        SELECT 1 FROM remito_items ri
        WHERE ri.remito_id = r.id
          AND ri.cantidad > COALESCE((
            SELECT sum(a.cantidad)
            FROM remito_item_facturas a JOIN facturas f ON f.id = a.factura_id
            WHERE a.remito_item_id = ri.id AND f.estado <> 'anulada'
              AND f.estado_fiscal IN ('historico','autorizado')), 0))
      THEN 'facturado' ELSE 'pendiente' END AS calculado
    FROM remitos r
    WHERE r.estado <> 'anulado'
  )
  SELECT count(*) FILTER (WHERE guardado <> calculado)                              AS distintos,
         count(*) FILTER (WHERE guardado = 'pendiente' AND calculado = 'facturado') AS a_facturado,
         count(*) FILTER (WHERE guardado = 'facturado' AND calculado = 'pendiente') AS a_pendiente
    INTO v
  FROM calc;
  RAISE NOTICE 'INFO  remitos con un estado guardado distinto del que daría crm_remito_recalcular: % (% pendiente → facturado, % facturado → pendiente)',
    v.distintos, v.a_facturado, v.a_pendiente;
END $$;
