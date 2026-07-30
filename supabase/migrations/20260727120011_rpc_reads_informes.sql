-- =============================================================
-- CRM Ventas — Supabase migration 0011: RPC — reads + informes
-- Ports the backend BASE_SELECT list/get queries and the informes aggregations to
-- jsonb-returning RPCs, so the frontend (supabase.rpc) gets byte-identical shapes to the
-- old Express JSON. Needed because:
--   * comprobante lists search across base table AND joined cliente name (numero OR razon_social),
--     which PostgREST can't express in one query;
--   * presupuestos auto-expire on list (an UPDATE);
--   * informes are multi-aggregation.
-- All SECURITY INVOKER (reads run as the authenticated caller, under RLS). anon revoked.
-- Each `*_list` also serves get-by-id via the optional p_id argument.
-- =============================================================

-- ── PRESUPUESTOS (list/get, con auto-vencimiento) ─────────────────
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
        'id', pi.id, 'producto_id', pi.producto_id, 'descripcion', pi.descripcion,
        'cantidad', pi.cantidad, 'precio_unitario', pi.precio_unitario,
        'descuento_item', pi.descuento_item, 'subtotal', pi.subtotal, 'orden', pi.orden
      ) ORDER BY pi.orden) FILTER (WHERE pi.id IS NOT NULL) AS items
    FROM presupuestos p
    JOIN clientes c ON c.id = p.cliente_id
    LEFT JOIN presupuesto_items pi ON pi.presupuesto_id = p.id
    WHERE (p_id IS NULL OR p.id = p_id)
      AND (p_estado IS NULL OR p.estado = p_estado)
      AND (p_q IS NULL OR p.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    GROUP BY p.id, c.id
    ORDER BY p.fecha DESC, p.numero DESC
  ) t;
END;
$$;

-- ── REMITOS (list/get/pendientes) ─────────────────────────────────
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
        'id', ri.id, 'producto_id', ri.producto_id, 'descripcion', ri.descripcion,
        'cantidad', ri.cantidad, 'precio_unitario', ri.precio_unitario,
        'descuento_item', ri.descuento_item, 'subtotal', ri.subtotal, 'orden', ri.orden
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items
    FROM remitos r
    JOIN clientes c ON c.id = r.cliente_id
    LEFT JOIN facturas f ON f.id = r.factura_id
    LEFT JOIN remito_items ri ON ri.remito_id = r.id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_estado IS NULL OR r.estado = p_estado)
      AND (p_cliente_id IS NULL OR r.cliente_id = p_cliente_id)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    GROUP BY r.id, c.id, f.numero
    ORDER BY r.fecha DESC, r.numero DESC
  ) t;
$$;

-- ── FACTURAS (list/get/pendientes-remitir) ────────────────────────
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
        'id', fi.id, 'producto_id', fi.producto_id, 'descripcion', fi.descripcion,
        'cantidad', fi.cantidad, 'precio_unitario', fi.precio_unitario,
        'descuento_item', fi.descuento_item, 'subtotal', fi.subtotal, 'orden', fi.orden
      ) ORDER BY fi.orden) FILTER (WHERE fi.id IS NOT NULL) AS items
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    LEFT JOIN remitos r ON r.id = f.remito_id
    LEFT JOIN presupuestos p ON p.id = f.presupuesto_id
    LEFT JOIN factura_items fi ON fi.factura_id = f.id
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

-- ── NOTAS (list/get) ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION notas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_tipo text DEFAULT NULL, p_cliente_id integer DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT n.*,
      f.numero AS factura_numero, f.tipo AS factura_tipo,
      c.razon_social, c.cuit, c.condicion_iva,
      json_agg(json_build_object(
        'id', ni.id, 'producto_id', ni.producto_id, 'descripcion', ni.descripcion,
        'cantidad', ni.cantidad, 'precio_unitario', ni.precio_unitario,
        'descuento_item', ni.descuento_item, 'subtotal', ni.subtotal, 'orden', ni.orden
      ) ORDER BY ni.orden) FILTER (WHERE ni.id IS NOT NULL) AS items
    FROM notas n
    JOIN facturas f ON f.id = n.factura_id
    JOIN clientes c ON c.id = f.cliente_id
    LEFT JOIN nota_items ni ON ni.nota_id = n.id
    WHERE (p_id IS NULL OR n.id = p_id)
      AND (p_tipo IS NULL OR n.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      AND (p_q IS NULL OR n.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR f.numero ILIKE '%'||p_q||'%')
    GROUP BY n.id, f.numero, f.tipo, c.razon_social, c.cuit, c.condicion_iva
    ORDER BY n.fecha DESC
  ) t;
$$;

-- ── RECIBOS (list/get) ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION recibos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_cliente_id integer DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT r.*,
      c.razon_social, c.cuit, c.condicion_iva,
      COALESCE(
        json_agg(DISTINCT jsonb_build_object('factura_id', rf.factura_id, 'numero', f.numero))
          FILTER (WHERE rf.id IS NOT NULL), '[]'
      ) AS facturas,
      COALESCE(
        json_agg(DISTINCT jsonb_build_object(
          'id', rm.id, 'tipo', rm.tipo, 'detalle', rm.detalle,
          'numero_cheque', rm.numero_cheque, 'banco', rm.banco, 'titular', rm.titular,
          'cuit_titular', rm.cuit_titular, 'fecha_emision', rm.fecha_emision,
          'fecha_vcto', rm.fecha_vcto, 'monto', rm.monto
        )) FILTER (WHERE rm.id IS NOT NULL), '[]'
      ) AS medios
    FROM recibos r
    JOIN clientes c ON c.id = r.cliente_id
    LEFT JOIN recibo_facturas rf ON rf.recibo_id = r.id
    LEFT JOIN facturas f ON f.id = rf.factura_id
    LEFT JOIN recibo_medios rm ON rm.recibo_id = r.id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_cliente_id IS NULL OR r.cliente_id = p_cliente_id)
      AND (p_desde IS NULL OR r.fecha >= p_desde)
      AND (p_hasta IS NULL OR r.fecha <= p_hasta)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    GROUP BY r.id, c.id
    ORDER BY r.fecha DESC, r.numero DESC
  ) t;
$$;

-- ── CLIENTES (list con saldo) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION clientes_list(
  p_q text DEFAULT NULL, p_activo boolean DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.*,
      COALESCE(SUM(f.total) FILTER (WHERE f.estado <> 'anulada'), 0)               AS total_facturado,
      COALESCE(SUM(f.total) FILTER (WHERE f.estado IN ('pendiente','parcial')), 0) AS saldo_pendiente
    FROM clientes c
    LEFT JOIN facturas f ON f.cliente_id = c.id
    WHERE (p_q IS NULL OR c.razon_social ILIKE '%'||p_q||'%' OR c.cuit ILIKE '%'||p_q||'%')
      AND (p_activo IS NULL OR c.activo = p_activo)
    GROUP BY c.id
    ORDER BY c.razon_social
  ) t;
$$;

-- ── PRODUCTOS: aumento masivo por porcentaje ──────────────────────
CREATE OR REPLACE FUNCTION productos_actualizar_precios(p_porcentaje numeric)
RETURNS jsonb
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_count  integer;
  v_factor numeric;
BEGIN
  IF p_porcentaje IS NULL OR p_porcentaje <= 0 THEN
    RAISE EXCEPTION 'El porcentaje debe ser un número positivo.';
  END IF;
  v_factor := 1 + p_porcentaje / 100;
  UPDATE productos SET precio_sin_iva = round(precio_sin_iva * v_factor, 2), updated_at = NOW()
  WHERE activo = TRUE;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'actualizados', v_count, 'porcentaje', p_porcentaje);
END;
$$;

-- ── INFORME: dashboard ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION informe_dashboard()
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'kpis', jsonb_build_object(
      'total_clientes',       (SELECT COUNT(*) FROM clientes WHERE activo),
      'total_productos',      (SELECT COUNT(*) FROM productos WHERE activo),
      'total_por_cobrar',     (SELECT COALESCE(SUM(total),0) FROM facturas WHERE estado IN ('pendiente','parcial')),
      'remitos_pendientes',   (SELECT COUNT(*) FROM remitos WHERE estado = 'pendiente'),
      'presupuestos_activos', (SELECT COUNT(*) FROM presupuestos WHERE estado IN ('borrador','enviado')),
      'cheques_vencidos',     (SELECT COUNT(*) FROM cheques WHERE estado = 'en_cartera' AND fecha_vcto < CURRENT_DATE)
    ),
    'ultimas_facturas', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT f.id, f.numero, f.fecha, f.total, f.estado, f.tipo, c.razon_social
      FROM facturas f JOIN clientes c ON c.id = f.cliente_id
      WHERE f.estado <> 'anulada'
      ORDER BY f.created_at DESC LIMIT 8) x),
    'top_deudores', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT c.id, c.razon_social, SUM(f.total) AS saldo_pendiente
      FROM clientes c JOIN facturas f ON f.cliente_id = c.id AND f.estado IN ('pendiente','parcial')
      GROUP BY c.id, c.razon_social
      ORDER BY SUM(f.total) DESC LIMIT 5) x),
    'cheques_por_vencer', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT ch.numero, ch.banco, ch.monto, ch.fecha_vcto, ch.estado, c.razon_social AS cliente_razon_social
      FROM cheques ch LEFT JOIN clientes c ON c.id = ch.cliente_id
      WHERE ch.estado = 'en_cartera' AND ch.fecha_vcto BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '7 days'
      ORDER BY ch.fecha_vcto LIMIT 5) x)
  );
$$;

-- ── INFORME: ventas por período ───────────────────────────────────
CREATE OR REPLACE FUNCTION informe_ventas(
  p_desde date, p_hasta date, p_cliente_id integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'Parámetros desde y hasta son obligatorios.';
  END IF;
  SELECT jsonb_build_object(
    'totales', (SELECT jsonb_build_object(
      'cantidad_facturas', COUNT(f.id),
      'subtotal',          SUM(f.subtotal),
      'descuento_total',   SUM(f.descuento_monto),
      'neto_gravado',      SUM(f.neto_gravado),
      'iva_total',         SUM(f.iva_monto),
      'total_facturado',   SUM(f.total),
      'total_cobrado',     SUM(CASE WHEN f.estado = 'cobrada' THEN f.total ELSE 0 END),
      'total_pendiente',   SUM(CASE WHEN f.estado IN ('pendiente','parcial') THEN f.total ELSE 0 END))
      FROM facturas f
      WHERE f.estado <> 'anulada' AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)),
    'por_cliente', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT c.id, c.razon_social, c.cuit,
        COUNT(f.id) AS cantidad_facturas, SUM(f.total) AS total_facturado,
        SUM(CASE WHEN f.estado IN ('pendiente','parcial') THEN f.total ELSE 0 END) AS pendiente
      FROM facturas f JOIN clientes c ON c.id = f.cliente_id
      WHERE f.estado <> 'anulada' AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      GROUP BY c.id, c.razon_social, c.cuit
      ORDER BY SUM(f.total) DESC) x),
    'por_mes', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT TO_CHAR(f.fecha, 'YYYY-MM') AS mes, COUNT(f.id) AS cantidad, SUM(f.total) AS total
      FROM facturas f
      WHERE f.estado <> 'anulada' AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      GROUP BY TO_CHAR(f.fecha, 'YYYY-MM') ORDER BY mes) x),
    'por_producto', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT p.codigo, p.descripcion, SUM(fi.cantidad) AS total_cantidad, SUM(fi.subtotal) AS total_neto
      FROM factura_items fi JOIN facturas f ON f.id = fi.factura_id
      LEFT JOIN productos p ON p.id = fi.producto_id
      WHERE f.estado <> 'anulada' AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      GROUP BY p.codigo, p.descripcion
      ORDER BY SUM(fi.subtotal) DESC LIMIT 20) x)
  ) INTO v;
  RETURN v;
END;
$$;

-- ── INFORME: ranking de clientes ──────────────────────────────────
CREATE OR REPLACE FUNCTION informe_ranking_clientes(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.id, c.razon_social, c.cuit,
      COUNT(f.id) AS cantidad_facturas, SUM(f.total) AS total_facturado,
      SUM(CASE WHEN f.estado IN ('pendiente','parcial') THEN f.total ELSE 0 END) AS saldo_pendiente,
      MAX(f.fecha) AS ultima_compra
    FROM clientes c
    LEFT JOIN facturas f ON f.cliente_id = c.id AND f.estado <> 'anulada'
      AND (p_desde IS NULL OR p_hasta IS NULL OR f.fecha BETWEEN p_desde AND p_hasta)
    GROUP BY c.id, c.razon_social, c.cuit
    HAVING SUM(f.total) > 0
    ORDER BY SUM(f.total) DESC LIMIT 50
  ) t;
$$;

-- ── INFORME: ranking de deudores ──────────────────────────────────
CREATE OR REPLACE FUNCTION informe_ranking_deudores()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.id, c.razon_social, c.cuit, c.telefono, c.email,
      COUNT(f.id) AS facturas_pendientes, SUM(f.total) AS total_pendiente,
      MIN(f.fecha) AS factura_mas_antigua,
      (CURRENT_DATE - MIN(f.fecha)::date) AS dias_deuda
    FROM clientes c
    JOIN facturas f ON f.cliente_id = c.id AND f.estado IN ('pendiente','parcial')
    GROUP BY c.id, c.razon_social, c.cuit, c.telefono, c.email
    ORDER BY SUM(f.total) DESC
  ) t;
$$;

-- ── INFORME: remitos pendientes de facturar ───────────────────────
CREATE OR REPLACE FUNCTION informe_remitos_pendientes_facturar()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT r.id, r.numero, r.fecha, c.razon_social, c.cuit,
      COUNT(ri.id) AS cantidad_items,
      (CURRENT_DATE - r.fecha::date) AS dias_pendiente
    FROM remitos r
    JOIN clientes c ON c.id = r.cliente_id
    LEFT JOIN remito_items ri ON ri.remito_id = r.id
    WHERE r.estado = 'pendiente'
    GROUP BY r.id, r.numero, r.fecha, c.razon_social, c.cuit
    ORDER BY r.fecha ASC
  ) t;
$$;

-- ── INFORME: facturas pendientes de remitir ───────────────────────
CREATE OR REPLACE FUNCTION informe_facturas_pendientes_remitir()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT f.id, f.numero, f.fecha, f.total, f.estado, c.razon_social, c.cuit,
      (CURRENT_DATE - f.fecha::date) AS dias_pendiente
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    WHERE f.remito_id IS NULL AND f.estado <> 'anulada'
    ORDER BY f.fecha ASC
  ) t;
$$;

-- ── INFORME: cuenta corriente de un cliente (con saldo acumulado) ─
CREATE OR REPLACE FUNCTION informe_cta_cte(
  p_cliente_id integer, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_cli   jsonb;
  v_movs  jsonb;
  v_saldo numeric;
BEGIN
  SELECT to_jsonb(c) INTO v_cli FROM clientes c WHERE c.id = p_cliente_id;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'Cliente no encontrado';
  END IF;

  WITH movs AS (
    SELECT f.id, f.fecha, f.numero AS comprobante, 'FACTURA'::text AS tipo,
           f.total AS debe, 0::numeric AS haber
    FROM facturas f
    WHERE f.cliente_id = p_cliente_id AND f.estado <> 'anulada'
      AND (p_desde IS NULL OR p_hasta IS NULL OR f.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    SELECT r.id, r.fecha, r.numero, 'RECIBO', 0::numeric, r.total
    FROM recibos r
    WHERE r.cliente_id = p_cliente_id
      AND (p_desde IS NULL OR p_hasta IS NULL OR r.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    SELECT n.id, n.fecha, n.numero, 'NOTA CRED.', 0::numeric, n.total
    FROM notas n JOIN facturas f ON f.id = n.factura_id
    WHERE f.cliente_id = p_cliente_id AND n.tipo = 'NC'
      AND (p_desde IS NULL OR p_hasta IS NULL OR n.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    SELECT n.id, n.fecha, n.numero, 'NOTA DEB.', n.total, 0::numeric
    FROM notas n JOIN facturas f ON f.id = n.factura_id
    WHERE f.cliente_id = p_cliente_id AND n.tipo = 'ND'
      AND (p_desde IS NULL OR p_hasta IS NULL OR n.fecha BETWEEN p_desde AND p_hasta)
  ),
  ordered AS (
    SELECT m.*,
      SUM(m.debe - m.haber) OVER (
        ORDER BY m.fecha ASC, m.comprobante ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS saldo
    FROM movs m
  )
  SELECT
    COALESCE(jsonb_agg(to_jsonb(ordered) ORDER BY ordered.fecha ASC, ordered.comprobante ASC), '[]'),
    COALESCE((SELECT o.saldo FROM ordered o ORDER BY o.fecha DESC, o.comprobante DESC LIMIT 1), 0)
  INTO v_movs, v_saldo
  FROM ordered;

  RETURN jsonb_build_object('cliente', v_cli, 'movimientos', v_movs, 'saldo_total', v_saldo);
END;
$$;

-- ── Permisos: sólo staff autenticado; anon denegado ──────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'presupuestos_list','remitos_list','facturas_list','notas_list','recibos_list',
      'clientes_list','productos_actualizar_precios','informe_dashboard','informe_ventas',
      'informe_ranking_clientes','informe_ranking_deudores','informe_remitos_pendientes_facturar',
      'informe_facturas_pendientes_remitir','informe_cta_cte'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated;', r.sig);
  END LOOP;
END $$;
