-- =============================================================
-- CRM — Cuenta 2 proveedores (sector 'compra') pasan a usar el catálogo de materiales de Compras
-- (`materiales`) en vez del catálogo de productos de Ventas (`productos`). El sector 'venta' no
-- cambia — sigue usando `productos` vía producto_id, como hasta ahora.
--
-- cuenta2_remito_items gana `material_id`, hermano nullable de `producto_id` (mismo patrón que
-- facturas_compra_items/remito_compra_items/nota_compra_items en 20260730120000_compras_schema.sql).
-- Un ítem usa uno u otro según de qué sector viene su remito — nunca ambos (CHECK). Filas existentes
-- (todas de venta, producto_id poblado) no se tocan.
--
-- crm_insert_cuenta2_remito_items y remitos_cuenta2_list (CREATE OR REPLACE, misma firma → grants
-- preservados) leen/exponen material_id igual que ya hacían con pallets/unidades_por_pallet.
-- =============================================================

ALTER TABLE public.cuenta2_remito_items
  ADD COLUMN IF NOT EXISTS material_id INTEGER REFERENCES materiales(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_c2rem_items_material ON cuenta2_remito_items(material_id);

ALTER TABLE public.cuenta2_remito_items DROP CONSTRAINT IF EXISTS chk_c2rem_items_catalogo;
ALTER TABLE public.cuenta2_remito_items
  ADD CONSTRAINT chk_c2rem_items_catalogo CHECK (producto_id IS NULL OR material_id IS NULL);

CREATE OR REPLACE FUNCTION crm_insert_cuenta2_remito_items(
  p_remito_id integer,
  p_items     jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO cuenta2_remito_items
    (remito_id, producto_id, material_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
  SELECT
    p_remito_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    NULLIF(e.item->>'material_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer,
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION remitos_cuenta2_list(
  p_id          integer DEFAULT NULL,
  p_tipo_sector text    DEFAULT NULL,
  p_q           text    DEFAULT NULL,
  p_entidad_id  integer DEFAULT NULL,
  p_desde       date    DEFAULT NULL,
  p_hasta       date    DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT r.*,
      COALESCE(cl.nombre, pv.nombre) AS entidad_nombre,
      COALESCE(r.cliente_id, r.proveedor_id) AS entidad_id,
      json_agg(json_build_object(
        'id', ri.id, 'producto_id', ri.producto_id, 'material_id', ri.material_id,
        'codigo', COALESCE(pr.codigo, mt.codigo),
        'descripcion', ri.descripcion, 'cantidad', ri.cantidad,
        'precio_unitario', ri.precio_unitario, 'descuento_item', ri.descuento_item,
        'subtotal', ri.subtotal, 'orden', ri.orden,
        'pallets', ri.pallets, 'unidades_por_pallet', ri.unidades_por_pallet,
        'es_pallet_vacio', COALESCE(pr.es_pallet_vacio, false),
        'es_transporte', COALESCE(pr.es_transporte, false)
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items
    FROM cuenta2_remitos r
    LEFT JOIN clientes_cuenta2    cl ON cl.id = r.cliente_id
    LEFT JOIN proveedores_cuenta2 pv ON pv.id = r.proveedor_id
    LEFT JOIN cuenta2_remito_items ri ON ri.remito_id = r.id
    LEFT JOIN productos  pr ON pr.id = ri.producto_id
    LEFT JOIN materiales mt ON mt.id = ri.material_id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_tipo_sector IS NULL OR r.tipo_sector = p_tipo_sector)
      AND (p_entidad_id IS NULL OR r.cliente_id = p_entidad_id OR r.proveedor_id = p_entidad_id)
      AND (p_desde IS NULL OR r.fecha >= p_desde)
      AND (p_hasta IS NULL OR r.fecha <= p_hasta)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%'
                       OR cl.nombre ILIKE '%'||p_q||'%'
                       OR pv.nombre ILIKE '%'||p_q||'%')
    GROUP BY r.id, cl.nombre, pv.nombre
    ORDER BY r.fecha DESC, r.id DESC
  ) t;
$$;

REVOKE ALL ON FUNCTION crm_insert_cuenta2_remito_items(integer, jsonb) FROM PUBLIC, anon, authenticated;

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'remitos_cuenta2_list'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated;', r.sig);
  END LOOP;
END $$;
