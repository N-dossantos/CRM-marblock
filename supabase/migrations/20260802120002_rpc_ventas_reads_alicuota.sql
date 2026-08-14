-- =============================================================
-- CRM — Fase F / migración 0402: alícuota por ítem en los reads de Ventas  (WS3)
-- Re-crea los 4 *_list que devuelven ítems (basado en 0012) agregando dentro del items json:
--   * 'alicuota_iva_id' <- <item>.alicuota_iva_id
--   * 'iva_porcentaje'  <- alicuotas_iva.porcentaje (LEFT JOIN)
-- para que el form pueda prellenar el selector al editar y el PDF derive el desglose por alícuota.
-- ADITIVO (el frontend mapea campos puntuales; claves extra se ignoran). SECURITY INVOKER, anon
-- revocado. Todo lo demás idéntico a 0012.
-- =============================================================

-- ── PRESUPUESTOS ──────────────────────────────────────────────────
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
        'alicuota_iva_id', pi.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje
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

-- ── REMITOS ───────────────────────────────────────────────────────
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
        'alicuota_iva_id', ri.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje
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

-- ── FACTURAS ──────────────────────────────────────────────────────
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
        'alicuota_iva_id', fi.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje
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

-- ── NOTAS ─────────────────────────────────────────────────────────
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
        'alicuota_iva_id', ni.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje
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

-- ── Permisos: sólo staff autenticado; anon denegado ──────────────
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
