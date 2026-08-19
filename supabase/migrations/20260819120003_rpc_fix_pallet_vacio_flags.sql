-- =============================================================
-- CRM — corrective migration: expose es_pallet_vacio/es_transporte per item in the read RPCs.
--
-- Bug: reopening a saved presupuesto/remito/factura/nota (or Cuenta 2 remito) via "Ver / Editar"
-- creates a SECOND, spurious "Pallet de Madera Vacío" line instead of recognizing the one already
-- saved. Root cause: presupuestos_list, remitos_list, facturas_list, notas_list, remitos_cuenta2_list
-- already LEFT JOIN productos pr and already select pr.codigo from it, and already select
-- pallets/unidades_por_pallet per item — but their per-item json_build_object never selected
-- pr.es_pallet_vacio / pr.es_transporte. frontend/src/hooks/usePalletsVacios.js (Task 4) depends on
-- every loaded item carrying these two booleans to find the existing auto-line
-- (items.findIndex(it => it.es_pallet_vacio)) and to exclude the vacío/transporte items themselves
-- from the pallet sum. On a freshly-created row the flags are set client-side by ItemsTable's
-- selectProd (Task 5), so the bug is invisible until a comprobante is saved and reopened — at which
-- point every loaded item has both flags undefined (falsy), findIndex never finds the existing vacío
-- line, and the hook creates a brand-new one instead of recognizing/updating it.
--
-- Fix: CREATE OR REPLACE the same 5 functions, changing ONLY their per-item json_build_object to add
-- 'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte, using the pr alias each
-- function's query already joins. Nothing else changes: same signature, same WHERE/GROUP BY/ORDER BY,
-- same other json keys, same joins. Starting point for each function is its live pg_get_functiondef
-- output (fetched via mcp__supabase__execute_sql before writing this file), NOT the plan document's
-- Task 2 SQL — migration 20260819120002_rpc_fix_alicuota_regression.sql already changed 4 of these 5
-- functions again (to restore alicuota_iva_id/iva_porcentaje) after the plan was written.
-- remitos_cuenta2_list was not touched by that alicuota fix (Cuenta 2 has no IVA) — its live body
-- matches the plan's Task 2 text for that one function.
--
-- Additive/backward-compatible: CREATE OR REPLACE with the same signature preserves existing grants
-- automatically — no REVOKE/GRANT block needed here (unlike 20260819120001, which introduced brand-
-- new functions).
-- =============================================================

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
        'pallets', pi.pallets, 'unidades_por_pallet', pi.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
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
        'pallets', ri.pallets, 'unidades_por_pallet', ri.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
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
        'pallets', fi.pallets, 'unidades_por_pallet', fi.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
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
        'pallets', ni.pallets, 'unidades_por_pallet', ni.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
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
        'pallets', ri.pallets, 'unidades_por_pallet', ri.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
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
