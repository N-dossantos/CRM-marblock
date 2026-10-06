-- =============================================================
-- Ventas — percepciones: exponerlas en las reads
--
-- Complementa 20260821140000 (esquema + escritura). `facturas_list`/`notas_list` ya devolvían
-- `percepciones_monto` sin tocar nada (seleccionan `f.*` / `n.*`), pero no el detalle por
-- impuesto/jurisdicción — que es lo que necesitan el detalle en pantalla y el PDF para imprimir
-- una línea por percepción.
--
-- Va como subconsulta correlacionada y NO como JOIN, por el mismo motivo documentado en
-- 20260821130000 para `remitos`: un join multiplicaría las filas y rompería el `json_agg` de ítems.
--
-- CREATE OR REPLACE con firma idéntica ⇒ preserva los grants existentes.
-- =============================================================

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
      -- Compat: el PDF y VentaDetalle siguen mostrando un único número.
      COALESCE(r.numero, (SELECT min(rr.numero) FROM remitos rr WHERE rr.factura_id = f.id))
        AS remito_numero,
      (SELECT json_agg(json_build_object('id', rr.id, 'numero', rr.numero) ORDER BY rr.numero)
         FROM remitos rr WHERE rr.factura_id = f.id) AS remitos,
      (SELECT json_agg(json_build_object(
                'id', pc.id, 'tipo_percepcion', pc.tipo_percepcion, 'jurisdiccion', pc.jurisdiccion,
                'base_imponible', pc.base_imponible, 'alicuota', pc.alicuota, 'monto', pc.monto
              ) ORDER BY pc.tipo_percepcion, pc.jurisdiccion)
         FROM percepciones pc WHERE pc.factura_id = f.id) AS percepciones,
      p.numero AS presupuesto_numero,
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
      AND (NOT p_solo_sin_remito OR (
             f.remito_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM remitos rr WHERE rr.factura_id = f.id)
             AND f.estado <> 'anulada'))
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
      (SELECT json_agg(json_build_object(
                'id', pc.id, 'tipo_percepcion', pc.tipo_percepcion, 'jurisdiccion', pc.jurisdiccion,
                'base_imponible', pc.base_imponible, 'alicuota', pc.alicuota, 'monto', pc.monto
              ) ORDER BY pc.tipo_percepcion, pc.jurisdiccion)
         FROM percepciones pc WHERE pc.nota_id = n.id) AS percepciones,
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
