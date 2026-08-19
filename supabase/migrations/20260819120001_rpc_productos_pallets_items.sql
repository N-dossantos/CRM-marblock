-- =============================================================
-- CRM Ventas — productos.md: pallets/unidades_por_pallet a través de las RPC de escritura y
-- lectura. Sólo re-crea los helpers internos crm_insert_*_items (agregan 2 columnas al INSERT) y
-- las *_list de lectura (agregan 2 claves al json_build_object de cada ítem) — las RPC públicas
-- crear_*/actualizar_* no cambian: ya reenvían p_items sin tocarlo al helper correspondiente.
-- Additive/backward-compatible: los ítems guardados antes de esta migración simplemente no traen
-- 'pallets'/'unidades_por_pallet' (columnas nullable / default 1). CREATE OR REPLACE con la misma
-- firma preserva los grants existentes automáticamente; se restatean igual por la convención del
-- proyecto (ver 20260728120012_pdf_list_fields.sql).
-- =============================================================

-- ── Helpers de escritura ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION crm_insert_presupuesto_items(
  p_presupuesto_id integer,
  p_items          jsonb
)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO presupuesto_items
    (presupuesto_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
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
    (remito_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
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
    (factura_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
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
    (nota_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
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
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_cuenta2_remito_items(
  p_remito_id integer,
  p_items     jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO cuenta2_remito_items
    (remito_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
  SELECT
    p_remito_id,
    NULLIF(e.item->>'producto_id', '')::integer,
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

-- ── RPC de lectura ────────────────────────────────────────────────

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
        'pallets', pi.pallets, 'unidades_por_pallet', pi.unidades_por_pallet
      ) ORDER BY pi.orden) FILTER (WHERE pi.id IS NOT NULL) AS items
    FROM presupuestos p
    JOIN clientes c ON c.id = p.cliente_id
    LEFT JOIN presupuesto_items pi ON pi.presupuesto_id = p.id
    LEFT JOIN productos pr ON pr.id = pi.producto_id
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
        'pallets', ri.pallets, 'unidades_por_pallet', ri.unidades_por_pallet
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items
    FROM remitos r
    JOIN clientes c ON c.id = r.cliente_id
    LEFT JOIN facturas f ON f.id = r.factura_id
    LEFT JOIN remito_items ri ON ri.remito_id = r.id
    LEFT JOIN productos pr ON pr.id = ri.producto_id
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
        'pallets', fi.pallets, 'unidades_por_pallet', fi.unidades_por_pallet
      ) ORDER BY fi.orden) FILTER (WHERE fi.id IS NOT NULL) AS items
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    LEFT JOIN remitos r ON r.id = f.remito_id
    LEFT JOIN presupuestos p ON p.id = f.presupuesto_id
    LEFT JOIN factura_items fi ON fi.factura_id = f.id
    LEFT JOIN productos pr ON pr.id = fi.producto_id
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
        'pallets', ni.pallets, 'unidades_por_pallet', ni.unidades_por_pallet
      ) ORDER BY ni.orden) FILTER (WHERE ni.id IS NOT NULL) AS items
    FROM notas n
    JOIN facturas f ON f.id = n.factura_id
    JOIN clientes c ON c.id = f.cliente_id
    LEFT JOIN nota_items ni ON ni.nota_id = n.id
    LEFT JOIN productos pr ON pr.id = ni.producto_id
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
        'id', ri.id, 'producto_id', ri.producto_id, 'codigo', pr.codigo,
        'descripcion', ri.descripcion, 'cantidad', ri.cantidad,
        'precio_unitario', ri.precio_unitario, 'descuento_item', ri.descuento_item,
        'subtotal', ri.subtotal, 'orden', ri.orden,
        'pallets', ri.pallets, 'unidades_por_pallet', ri.unidades_por_pallet
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items
    FROM cuenta2_remitos r
    LEFT JOIN clientes_cuenta2    cl ON cl.id = r.cliente_id
    LEFT JOIN proveedores_cuenta2 pv ON pv.id = r.proveedor_id
    LEFT JOIN cuenta2_remito_items ri ON ri.remito_id = r.id
    LEFT JOIN productos pr ON pr.id = ri.producto_id
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

-- ── Permisos ───────────────────────────────────────────────────────
-- crm_insert_*_items: CREATE OR REPLACE con la misma firma preserva el ACL existente solo; se
-- restatea igual, por la convención del proyecto (ver comentario en 20260728120012_pdf_list_fields.sql).
REVOKE ALL ON FUNCTION crm_insert_presupuesto_items(integer, jsonb)    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_remito_items(integer, jsonb)         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_factura_items(integer, jsonb)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_nota_items(integer, jsonb)           FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_cuenta2_remito_items(integer, jsonb) FROM PUBLIC, anon, authenticated;

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'presupuestos_list','remitos_list','facturas_list','notas_list','remitos_cuenta2_list'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated;', r.sig);
  END LOOP;
END $$;
