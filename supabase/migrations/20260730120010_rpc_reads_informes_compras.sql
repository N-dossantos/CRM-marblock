-- =============================================================
-- CRM — Fase A / migración 0110: RPC reads + informes (Compras)  §4.6/§4.10/§4.14
-- Espeja los *_list y los informes de Ventas (0011), en formato jsonb para el frontend.
-- Cta cte proveedor e IVA Compras se calculan en vivo (no hay ledger físico nuevo, salvo
-- la pequeña factura_compra_iva_detalle). SECURITY INVOKER; anon revocado.
-- Cada *_list también sirve get-by-id vía el parámetro opcional p_id.
-- =============================================================

-- ── FACTURAS DE COMPRA (list/get) ─────────────────────────────────
CREATE OR REPLACE FUNCTION facturas_compra_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL,
  p_proveedor_id integer DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT fc.*,
      p.razon_social, p.cuit, p.condicion_iva, p.direccion, p.email, p.telefono,
      rc.numero AS remito_numero,
      json_agg(json_build_object(
        'id', fi.id, 'material_id', fi.material_id, 'descripcion', fi.descripcion,
        'cantidad', fi.cantidad, 'precio_unitario', fi.precio_unitario,
        'descuento_item', fi.descuento_item, 'alicuota_iva_id', fi.alicuota_iva_id,
        'alicuota_porcentaje', ai.porcentaje, 'subtotal', fi.subtotal, 'orden', fi.orden
      ) ORDER BY fi.orden) FILTER (WHERE fi.id IS NOT NULL) AS items,
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'alicuota_iva_id', d.alicuota_iva_id, 'porcentaje', a.porcentaje,
                'neto_gravado', d.neto_gravado, 'iva_monto', d.iva_monto
              ) ORDER BY a.porcentaje), '[]')
       FROM factura_compra_iva_detalle d JOIN alicuotas_iva a ON a.id = d.alicuota_iva_id
       WHERE d.factura_compra_id = fc.id) AS iva_detalle
    FROM facturas_compra fc
    JOIN proveedores p ON p.id = fc.proveedor_id
    LEFT JOIN remitos_compra rc ON rc.id = fc.remito_compra_id
    LEFT JOIN facturas_compra_items fi ON fi.factura_compra_id = fc.id
    LEFT JOIN alicuotas_iva ai ON ai.id = fi.alicuota_iva_id
    WHERE (p_id IS NULL OR fc.id = p_id)
      AND (p_estado IS NULL OR fc.estado = p_estado)
      AND (p_proveedor_id IS NULL OR fc.proveedor_id = p_proveedor_id)
      AND (p_desde IS NULL OR fc.fecha >= p_desde)
      AND (p_hasta IS NULL OR fc.fecha <= p_hasta)
      AND (p_q IS NULL OR fc.numero ILIKE '%'||p_q||'%'
                       OR p.razon_social ILIKE '%'||p_q||'%'
                       OR p.cuit ILIKE '%'||p_q||'%')
    GROUP BY fc.id, p.id, rc.numero
    ORDER BY fc.fecha DESC, fc.numero DESC
  ) t;
$$;

-- ── REMITOS DE COMPRA (list/get) ──────────────────────────────────
CREATE OR REPLACE FUNCTION remitos_compra_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_estado text DEFAULT NULL, p_proveedor_id integer DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT rc.*,
      p.razon_social, p.cuit, p.condicion_iva,
      fc.numero AS factura_numero,
      json_agg(json_build_object(
        'id', ri.id, 'material_id', ri.material_id, 'descripcion', ri.descripcion,
        'cantidad', ri.cantidad, 'precio_unitario', ri.precio_unitario,
        'descuento_item', ri.descuento_item, 'subtotal', ri.subtotal, 'orden', ri.orden
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items
    FROM remitos_compra rc
    JOIN proveedores p ON p.id = rc.proveedor_id
    LEFT JOIN facturas_compra fc ON fc.id = rc.factura_compra_id
    LEFT JOIN remito_compra_items ri ON ri.remito_compra_id = rc.id
    WHERE (p_id IS NULL OR rc.id = p_id)
      AND (p_estado IS NULL OR rc.estado = p_estado)
      AND (p_proveedor_id IS NULL OR rc.proveedor_id = p_proveedor_id)
      AND (p_q IS NULL OR rc.numero ILIKE '%'||p_q||'%' OR p.razon_social ILIKE '%'||p_q||'%')
    GROUP BY rc.id, p.id, fc.numero
    ORDER BY rc.fecha DESC, rc.numero DESC
  ) t;
$$;

-- ── NOTAS DE COMPRA (list/get) ────────────────────────────────────
CREATE OR REPLACE FUNCTION notas_compra_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_tipo text DEFAULT NULL, p_proveedor_id integer DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT nc.*,
      fc.numero AS factura_numero, fc.tipo AS factura_tipo,
      p.razon_social, p.cuit, p.condicion_iva,
      json_agg(json_build_object(
        'id', ni.id, 'material_id', ni.material_id, 'descripcion', ni.descripcion,
        'cantidad', ni.cantidad, 'precio_unitario', ni.precio_unitario,
        'descuento_item', ni.descuento_item, 'subtotal', ni.subtotal, 'orden', ni.orden
      ) ORDER BY ni.orden) FILTER (WHERE ni.id IS NOT NULL) AS items
    FROM notas_compra nc
    JOIN facturas_compra fc ON fc.id = nc.factura_compra_id
    JOIN proveedores p ON p.id = nc.proveedor_id
    LEFT JOIN nota_compra_items ni ON ni.nota_compra_id = nc.id
    WHERE (p_id IS NULL OR nc.id = p_id)
      AND (p_tipo IS NULL OR nc.tipo = p_tipo)
      AND (p_proveedor_id IS NULL OR nc.proveedor_id = p_proveedor_id)
      AND (p_q IS NULL OR nc.numero ILIKE '%'||p_q||'%'
                       OR p.razon_social ILIKE '%'||p_q||'%'
                       OR fc.numero ILIKE '%'||p_q||'%')
    GROUP BY nc.id, fc.numero, fc.tipo, p.razon_social, p.cuit, p.condicion_iva
    ORDER BY nc.fecha DESC
  ) t;
$$;

-- ── PAGOS A PROVEEDOR (list/get) ──────────────────────────────────
CREATE OR REPLACE FUNCTION pagos_proveedor_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_proveedor_id integer DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT pp.*,
      p.razon_social, p.cuit, p.condicion_iva,
      COALESCE(
        json_agg(DISTINCT jsonb_build_object('factura_compra_id', pf.factura_compra_id, 'numero', fc.numero))
          FILTER (WHERE pf.id IS NOT NULL), '[]'
      ) AS facturas,
      COALESCE(
        json_agg(DISTINCT jsonb_build_object(
          'id', m.id, 'tipo', m.tipo, 'detalle', m.detalle,
          'cuenta_bancaria_id', m.cuenta_bancaria_id, 'cheque_id', m.cheque_id,
          'cheque_propio_id', m.cheque_propio_id, 'monto', m.monto
        )) FILTER (WHERE m.id IS NOT NULL), '[]'
      ) AS medios,
      COALESCE(
        json_agg(DISTINCT jsonb_build_object(
          'id', r.id, 'tipo_retencion', r.tipo_retencion, 'jurisdiccion', r.jurisdiccion,
          'numero_certificado', r.numero_certificado, 'base_imponible', r.base_imponible,
          'alicuota', r.alicuota, 'monto', r.monto
        )) FILTER (WHERE r.id IS NOT NULL), '[]'
      ) AS retenciones
    FROM pagos_proveedor pp
    JOIN proveedores p ON p.id = pp.proveedor_id
    LEFT JOIN pago_proveedor_facturas pf ON pf.pago_proveedor_id = pp.id
    LEFT JOIN facturas_compra fc ON fc.id = pf.factura_compra_id
    LEFT JOIN pago_proveedor_medios m ON m.pago_proveedor_id = pp.id
    LEFT JOIN retenciones r ON r.pago_proveedor_id = pp.id
    WHERE (p_id IS NULL OR pp.id = p_id)
      AND (p_proveedor_id IS NULL OR pp.proveedor_id = p_proveedor_id)
      AND (p_desde IS NULL OR pp.fecha >= p_desde)
      AND (p_hasta IS NULL OR pp.fecha <= p_hasta)
      AND (p_q IS NULL OR pp.numero ILIKE '%'||p_q||'%' OR p.razon_social ILIKE '%'||p_q||'%')
    GROUP BY pp.id, p.id
    ORDER BY pp.fecha DESC, pp.numero DESC
  ) t;
$$;

-- ── INFORME: cuenta corriente de un proveedor ("composición de saldos")  §4.6 ──
CREATE OR REPLACE FUNCTION informe_cta_cte_proveedor(
  p_proveedor_id integer, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_prov  jsonb;
  v_movs  jsonb;
  v_saldo numeric;
BEGIN
  SELECT to_jsonb(p) INTO v_prov FROM proveedores p WHERE p.id = p_proveedor_id;
  IF v_prov IS NULL THEN
    RAISE EXCEPTION 'Proveedor no encontrado';
  END IF;

  WITH movs AS (
    -- Factura de compra: debe (le debemos)
    SELECT fc.fecha, fc.numero AS comprobante, 'FACTURA'::text AS tipo,
           fc.total AS debe, 0::numeric AS haber
    FROM facturas_compra fc
    WHERE fc.proveedor_id = p_proveedor_id AND fc.estado <> 'anulada'
      AND (p_desde IS NULL OR p_hasta IS NULL OR fc.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    -- Nota de crédito: haber (nos deben menos / debemos menos)
    SELECT nc.fecha, nc.numero, 'NOTA CRED.', 0::numeric, nc.total
    FROM notas_compra nc
    WHERE nc.proveedor_id = p_proveedor_id AND nc.tipo = 'NC'
      AND (p_desde IS NULL OR p_hasta IS NULL OR nc.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    -- Nota de débito: debe
    SELECT nc.fecha, nc.numero, 'NOTA DEB.', nc.total, 0::numeric
    FROM notas_compra nc
    WHERE nc.proveedor_id = p_proveedor_id AND nc.tipo = 'ND'
      AND (p_desde IS NULL OR p_hasta IS NULL OR nc.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    -- Pago: haber
    SELECT pp.fecha, pp.numero, 'PAGO', 0::numeric, pp.total
    FROM pagos_proveedor pp
    WHERE pp.proveedor_id = p_proveedor_id
      AND (p_desde IS NULL OR p_hasta IS NULL OR pp.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    -- Retención: haber (reduce lo que debemos al proveedor)
    SELECT r.fecha, COALESCE(r.numero_certificado, 'RET '||r.tipo_retencion), 'RETENCIÓN', 0::numeric, r.monto
    FROM retenciones r
    WHERE r.proveedor_id = p_proveedor_id
      AND (p_desde IS NULL OR p_hasta IS NULL OR r.fecha BETWEEN p_desde AND p_hasta)
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

  RETURN jsonb_build_object('proveedor', v_prov, 'movimientos', v_movs, 'saldo_total', v_saldo);
END;
$$;

-- ── INFORME: Libro IVA Compras  §4.10 ─────────────────────────────
CREATE OR REPLACE FUNCTION informe_iva_compras(p_desde date, p_hasta date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'Parámetros desde y hasta son obligatorios.';
  END IF;

  SELECT jsonb_build_object(
    'comprobantes', (SELECT COALESCE(jsonb_agg(x ORDER BY x.fecha, x.numero), '[]') FROM (
      SELECT fc.fecha, fc.tipo, fc.punto_venta, fc.numero,
        p.razon_social, p.cuit,
        fc.neto_gravado, fc.iva_monto, fc.total,
        (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'porcentaje', a.porcentaje, 'neto_gravado', d.neto_gravado, 'iva_monto', d.iva_monto
                ) ORDER BY a.porcentaje), '[]')
         FROM factura_compra_iva_detalle d JOIN alicuotas_iva a ON a.id = d.alicuota_iva_id
         WHERE d.factura_compra_id = fc.id) AS iva_detalle
      FROM facturas_compra fc
      JOIN proveedores p ON p.id = fc.proveedor_id
      WHERE fc.estado <> 'anulada' AND fc.fecha BETWEEN p_desde AND p_hasta
    ) x),
    'retenciones', (SELECT COALESCE(jsonb_agg(y ORDER BY y.fecha), '[]') FROM (
      SELECT r.fecha, r.tipo_retencion, r.jurisdiccion, r.numero_certificado, r.monto,
        p.razon_social, p.cuit
      FROM retenciones r JOIN proveedores p ON p.id = r.proveedor_id
      WHERE r.fecha BETWEEN p_desde AND p_hasta
    ) y),
    'totales', (SELECT jsonb_build_object(
      'neto_gravado', COALESCE(SUM(fc.neto_gravado), 0),
      'iva_monto',    COALESCE(SUM(fc.iva_monto), 0),
      'total',        COALESCE(SUM(fc.total), 0),
      'retenciones',  COALESCE((SELECT SUM(r.monto) FROM retenciones r
                                WHERE r.fecha BETWEEN p_desde AND p_hasta), 0))
      FROM facturas_compra fc
      WHERE fc.estado <> 'anulada' AND fc.fecha BETWEEN p_desde AND p_hasta)
  ) INTO v;
  RETURN v;
END;
$$;

-- ── INFORME: precios de compra (último precio conocido por material) ──
CREATE OR REPLACE FUNCTION informe_precios_compra(p_q text DEFAULT NULL)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT DISTINCT ON (fi.material_id)
      fi.material_id, m.codigo, m.descripcion, m.unidad_medida,
      fi.precio_unitario AS ultimo_precio, fc.fecha AS fecha_ultima_compra,
      p.razon_social AS ultimo_proveedor
    FROM facturas_compra_items fi
    JOIN facturas_compra fc ON fc.id = fi.factura_compra_id AND fc.estado <> 'anulada'
    JOIN proveedores p ON p.id = fc.proveedor_id
    LEFT JOIN materiales m ON m.id = fi.material_id
    WHERE fi.material_id IS NOT NULL
      AND (p_q IS NULL OR m.codigo ILIKE '%'||p_q||'%' OR m.descripcion ILIKE '%'||p_q||'%')
    ORDER BY fi.material_id, fc.fecha DESC, fc.id DESC
  ) t;
$$;

-- ── INFORME: nómina de proveedores (con saldos) ───────────────────
CREATE OR REPLACE FUNCTION informe_nomina_proveedores()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT p.id, p.razon_social, p.cuit, p.condicion_iva, p.condicion_compra,
      p.telefono, p.email, p.activo,
      COUNT(fc.id) FILTER (WHERE fc.estado <> 'anulada')                       AS cantidad_facturas,
      COALESCE(SUM(fc.total) FILTER (WHERE fc.estado <> 'anulada'), 0)         AS total_comprado,
      COALESCE(SUM(fc.total) FILTER (WHERE fc.estado IN ('pendiente','parcial')), 0) AS saldo_pendiente
    FROM proveedores p
    LEFT JOIN facturas_compra fc ON fc.proveedor_id = p.id
    GROUP BY p.id
    ORDER BY p.razon_social
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
      'facturas_compra_list','remitos_compra_list','notas_compra_list','pagos_proveedor_list',
      'informe_cta_cte_proveedor','informe_iva_compras','informe_precios_compra',
      'informe_nomina_proveedores'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated;', r.sig);
  END LOOP;
END $$;
