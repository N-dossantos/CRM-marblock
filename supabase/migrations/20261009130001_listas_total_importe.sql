-- ══════════════════════════════════════════════════════════════════
-- M11 (complemento de 20261009130000): recibos_list y pagos_proveedor_list agregan `total_importe`
-- = suma de `total` de TODAS las filas que cumplen el filtro (sum() OVER () antes del LIMIT).
-- Las pantallas de Recibos y Órdenes de pago muestran "Total cobrado/pagado (filtro actual)"; con
-- la lista paginada, sumar las filas recibidas daría sólo el total de la página.
-- Misma firma: CREATE OR REPLACE, los permisos de 20261009130000 siguen aplicando.
-- ══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION recibos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_cliente_id integer DEFAULT NULL,
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT r.id, count(*) OVER () AS total_filas, sum(r.total) OVER () AS total_importe
    FROM recibos r
    JOIN clientes c ON c.id = r.cliente_id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_cliente_id IS NULL OR r.cliente_id = p_cliente_id)
      AND (p_desde IS NULL OR r.fecha >= p_desde)
      AND (p_hasta IS NULL OR r.fecha <= p_hasta)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
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
      ) AS medios,
      pg.total_filas, pg.total_importe
    FROM pagina pg
    JOIN recibos r ON r.id = pg.id
    JOIN clientes c ON c.id = r.cliente_id
    LEFT JOIN recibo_facturas rf ON rf.recibo_id = r.id
    LEFT JOIN facturas f ON f.id = rf.factura_id
    LEFT JOIN recibo_medios rm ON rm.recibo_id = r.id
    GROUP BY r.id, c.id, pg.total_filas, pg.total_importe
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
  ) t;
$$;

CREATE OR REPLACE FUNCTION pagos_proveedor_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_proveedor_id integer DEFAULT NULL,
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT pp.id, count(*) OVER () AS total_filas, sum(pp.total) OVER () AS total_importe
    FROM pagos_proveedor pp
    JOIN proveedores p ON p.id = pp.proveedor_id
    WHERE (p_id IS NULL OR pp.id = p_id)
      AND (p_proveedor_id IS NULL OR pp.proveedor_id = p_proveedor_id)
      AND (p_desde IS NULL OR pp.fecha >= p_desde)
      AND (p_hasta IS NULL OR pp.fecha <= p_hasta)
      AND (p_q IS NULL OR pp.numero ILIKE '%'||p_q||'%' OR p.razon_social ILIKE '%'||p_q||'%')
    ORDER BY pp.fecha DESC, pp.numero DESC, pp.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
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
      ) AS retenciones,
      pg.total_filas, pg.total_importe
    FROM pagina pg
    JOIN pagos_proveedor pp ON pp.id = pg.id
    JOIN proveedores p ON p.id = pp.proveedor_id
    LEFT JOIN pago_proveedor_facturas pf ON pf.pago_proveedor_id = pp.id
    LEFT JOIN facturas_compra fc ON fc.id = pf.factura_compra_id
    LEFT JOIN pago_proveedor_medios m ON m.pago_proveedor_id = pp.id
    LEFT JOIN retenciones r ON r.pago_proveedor_id = pp.id
    GROUP BY pp.id, p.id, pg.total_filas, pg.total_importe
    ORDER BY pp.fecha DESC, pp.numero DESC, pp.id DESC
  ) t;
$$;
