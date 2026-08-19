-- =============================================================
-- CRM — corrective migration: restore alicuota_iva_id handling dropped by the pallets migration.
--
-- 20260819120001_rpc_productos_pallets_items.sql (productos.md — pallets/unidades_por_pallet
-- feature) was drafted from a stale snapshot of these 8 functions that predated the already-shipped
-- multi-alícuota IVA feature (20260802120001_rpc_ventas_multialicuota.sql +
-- 20260802120002_rpc_ventas_reads_alicuota.sql). Applying it silently DELETED the alicuota_iva_id
-- read/write logic from:
--   * crm_insert_presupuesto_items, crm_insert_remito_items, crm_insert_factura_items,
--     crm_insert_nota_items — lost writing alicuota_iva_id into their INSERT.
--   * presupuestos_list, remitos_list, facturas_list, notas_list — lost the
--     LEFT JOIN alicuotas_iva and the 'alicuota_iva_id'/'iva_porcentaje' json_build_object keys.
-- while correctly adding pallets/unidades_por_pallet to those same 8 functions.
--
-- This migration re-creates all 8 functions with BOTH the multi-alícuota logic AND the pallets
-- logic present (a merge, not a revert — reverting would re-drop pallets). It also restores
-- `SET search_path = public, pg_temp` on crm_insert_presupuesto_items, which 20260819120001 also
-- dropped (its own prior version, and all 4 sibling write-helpers, carry it) — flagged live by the
-- Supabase security advisor (function_search_path_mutable).
--
-- `crm_insert_cuenta2_remito_items` and `remitos_cuenta2_list` are NOT touched here: Cuenta 2 has no
-- IVA and never had alicuota_iva_id — they are correct as-is (pallets-only, by design).
--
-- presupuestos/remitos/facturas/notas are all empty (0 rows) in this project at the time of this
-- migration (pre-cutover) — no backfill of existing rows is needed or performed.
-- =============================================================

-- ── Helpers de escritura (alicuota_iva_id + pallets/unidades_por_pallet) ──────────

CREATE OR REPLACE FUNCTION crm_insert_presupuesto_items(
  p_presupuesto_id integer,
  p_items          jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO presupuesto_items
    (presupuesto_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, alicuota_iva_id, pallets, unidades_por_pallet)
  SELECT
    p_presupuesto_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer,
    COALESCE(NULLIF(e.item->>'alicuota_iva_id', '')::int, (SELECT id FROM alicuotas_iva WHERE porcentaje = 21)),
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_remito_items(
  p_remito_id integer,
  p_items     jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO remito_items
    (remito_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, alicuota_iva_id, pallets, unidades_por_pallet)
  SELECT
    p_remito_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    COALESCE((e.item->>'precio_unitario')::numeric, 0),
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * COALESCE((e.item->>'precio_unitario')::numeric, 0)
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer,
    COALESCE(NULLIF(e.item->>'alicuota_iva_id', '')::int, (SELECT id FROM alicuotas_iva WHERE porcentaje = 21)),
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_factura_items(
  p_factura_id integer,
  p_items      jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO factura_items
    (factura_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, alicuota_iva_id, pallets, unidades_por_pallet)
  SELECT
    p_factura_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer,
    COALESCE(NULLIF(e.item->>'alicuota_iva_id', '')::int, (SELECT id FROM alicuotas_iva WHERE porcentaje = 21)),
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_nota_items(
  p_nota_id integer,
  p_items   jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO nota_items
    (nota_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, alicuota_iva_id, pallets, unidades_por_pallet)
  SELECT
    p_nota_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer,
    COALESCE(NULLIF(e.item->>'alicuota_iva_id', '')::int, (SELECT id FROM alicuotas_iva WHERE porcentaje = 21)),
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

-- ── RPC de lectura (LEFT JOIN alicuotas_iva + pallets/unidades_por_pallet) ────────

CREATE OR REPLACE FUNCTION presupuestos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE presupuestos SET estado = 'vencido', updated_at = NOW()
  WHERE estado IN ('borrador','enviado') AND fecha_vcto < CURRENT_DATE;

  RETURN QUERY
  SELECT to_jsonb(t) FROM (
    SELECT p.*,
      c.razon_social, c.cuit, c.condicion_iva, c.direccion, c.email, c.telefono,
      json_agg(json_build_object(
        'id', pi.id, 'producto_id', pi.producto_id, 'codigo', pr.codigo, 'descripcion', pi.descripcion,
        'cantidad', pi.cantidad, 'precio_unitario', pi.precio_unitario,
        'descuento_item', pi.descuento_item, 'subtotal', pi.subtotal, 'orden', pi.orden,
        'alicuota_iva_id', pi.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', pi.pallets, 'unidades_por_pallet', pi.unidades_por_pallet
      ) ORDER BY pi.orden) FILTER (WHERE pi.id IS NOT NULL) AS items
    FROM presupuestos p
    JOIN clientes c ON c.id = p.cliente_id
    LEFT JOIN presupuesto_items pi ON pi.presupuesto_id = p.id
    LEFT JOIN productos pr ON pr.id = pi.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = pi.alicuota_iva_id
    WHERE (p_id IS NULL OR p.id = p_id)
      AND (p_estado IS NULL OR p.estado = p_estado)
      AND (p_q IS NULL OR p.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    GROUP BY p.id, c.id
    ORDER BY p.fecha DESC, p.numero DESC
  ) t;
END;
$$;

CREATE OR REPLACE FUNCTION remitos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_estado text DEFAULT NULL, p_cliente_id integer DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT r.*,
      c.razon_social, c.cuit, c.condicion_iva, c.direccion, c.email, c.telefono,
      f.numero AS factura_numero,
      json_agg(json_build_object(
        'id', ri.id, 'producto_id', ri.producto_id, 'codigo', pr.codigo, 'descripcion', ri.descripcion,
        'cantidad', ri.cantidad, 'precio_unitario', ri.precio_unitario,
        'descuento_item', ri.descuento_item, 'subtotal', ri.subtotal, 'orden', ri.orden,
        'alicuota_iva_id', ri.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', ri.pallets, 'unidades_por_pallet', ri.unidades_por_pallet
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items
    FROM remitos r
    JOIN clientes c ON c.id = r.cliente_id
    LEFT JOIN facturas f ON f.id = r.factura_id
    LEFT JOIN remito_items ri ON ri.remito_id = r.id
    LEFT JOIN productos pr ON pr.id = ri.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = ri.alicuota_iva_id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_estado IS NULL OR r.estado = p_estado)
      AND (p_cliente_id IS NULL OR r.cliente_id = p_cliente_id)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    GROUP BY r.id, c.id, f.numero
    ORDER BY r.fecha DESC, r.numero DESC
  ) t;
$$;

CREATE OR REPLACE FUNCTION facturas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL,
  p_tipo text DEFAULT NULL, p_cliente_id integer DEFAULT NULL,
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_solo_sin_remito boolean DEFAULT false
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT f.*,
      c.razon_social, c.cuit, c.condicion_iva, c.direccion, c.email, c.telefono,
      r.numero AS remito_numero, p.numero AS presupuesto_numero,
      json_agg(json_build_object(
        'id', fi.id, 'producto_id', fi.producto_id, 'codigo', pr.codigo, 'descripcion', fi.descripcion,
        'cantidad', fi.cantidad, 'precio_unitario', fi.precio_unitario,
        'descuento_item', fi.descuento_item, 'subtotal', fi.subtotal, 'orden', fi.orden,
        'alicuota_iva_id', fi.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', fi.pallets, 'unidades_por_pallet', fi.unidades_por_pallet
      ) ORDER BY fi.orden) FILTER (WHERE fi.id IS NOT NULL) AS items
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    LEFT JOIN remitos r ON r.id = f.remito_id
    LEFT JOIN presupuestos p ON p.id = f.presupuesto_id
    LEFT JOIN factura_items fi ON fi.factura_id = f.id
    LEFT JOIN productos pr ON pr.id = fi.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = fi.alicuota_iva_id
    WHERE (p_id IS NULL OR f.id = p_id)
      AND (p_estado IS NULL OR f.estado = p_estado)
      AND (p_tipo IS NULL OR f.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      AND (p_desde IS NULL OR f.fecha >= p_desde)
      AND (p_hasta IS NULL OR f.fecha <= p_hasta)
      AND (NOT p_solo_sin_remito OR (f.remito_id IS NULL AND f.estado <> 'anulada'))
      AND (p_q IS NULL OR f.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR c.cuit ILIKE '%'||p_q||'%')
    GROUP BY f.id, c.id, r.numero, p.numero
    ORDER BY f.fecha DESC, f.numero DESC
  ) t;
$$;

CREATE OR REPLACE FUNCTION notas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_tipo text DEFAULT NULL, p_cliente_id integer DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT n.*,
      f.numero AS factura_numero, f.tipo AS factura_tipo,
      c.razon_social, c.cuit, c.condicion_iva, c.direccion,
      json_agg(json_build_object(
        'id', ni.id, 'producto_id', ni.producto_id, 'codigo', pr.codigo, 'descripcion', ni.descripcion,
        'cantidad', ni.cantidad, 'precio_unitario', ni.precio_unitario,
        'descuento_item', ni.descuento_item, 'subtotal', ni.subtotal, 'orden', ni.orden,
        'alicuota_iva_id', ni.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', ni.pallets, 'unidades_por_pallet', ni.unidades_por_pallet
      ) ORDER BY ni.orden) FILTER (WHERE ni.id IS NOT NULL) AS items
    FROM notas n
    JOIN facturas f ON f.id = n.factura_id
    JOIN clientes c ON c.id = f.cliente_id
    LEFT JOIN nota_items ni ON ni.nota_id = n.id
    LEFT JOIN productos pr ON pr.id = ni.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = ni.alicuota_iva_id
    WHERE (p_id IS NULL OR n.id = p_id)
      AND (p_tipo IS NULL OR n.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      AND (p_q IS NULL OR n.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR f.numero ILIKE '%'||p_q||'%')
    GROUP BY n.id, f.numero, f.tipo, c.razon_social, c.cuit, c.condicion_iva, c.direccion
    ORDER BY n.fecha DESC
  ) t;
$$;

-- ── Permisos: re-afirmados igual que lo actualmente vigente (CREATE OR REPLACE ya los preserva;
-- se restatean por la convención del proyecto, ver 20260728120012_pdf_list_fields.sql) ───────────
REVOKE ALL ON FUNCTION crm_insert_presupuesto_items(integer, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_remito_items(integer, jsonb)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_factura_items(integer, jsonb)     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_nota_items(integer, jsonb)        FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crm_insert_presupuesto_items(integer, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION crm_insert_remito_items(integer, jsonb)      TO authenticated;
GRANT EXECUTE ON FUNCTION crm_insert_factura_items(integer, jsonb)     TO authenticated;
GRANT EXECUTE ON FUNCTION crm_insert_nota_items(integer, jsonb)        TO authenticated;

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'presupuestos_list','remitos_list','facturas_list','notas_list'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated;', r.sig);
  END LOOP;
END $$;
