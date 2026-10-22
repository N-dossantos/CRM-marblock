-- =============================================================
-- CRM Ventas — remitos contra facturas pendientes de remitir (PLAN_MAESTRO §3.11), 4 de 4:
-- listados e informes con lo pendiente real, a partir de las asignaciones.
--
-- 1) remitos_list: p_estado 'por_facturar' (remitos con algún renglón sin facturar); cada ítem
--    trae asignado, sin_facturar y sus asignaciones, y el remito, bloqueado, sin_facturar_total y
--    las facturas emitidas a las que está asignado.
-- 2) facturas_list: los remitos[] de una factura, el respaldo de remito_numero y
--    p_solo_sin_remito salen de los remitos con asignaciones a ella.
-- 3) Los informes de la solapa "⏳ Pendientes", con las mismas claves: las facturas con algo
--    pendiente de remitir (crm_facturas_pendientes) y los remitos con algo sin facturar.
--
-- Mismas firmas (CREATE OR REPLACE): conservan sus grants. Sin BEGIN/COMMIT: se ensaya dentro de
-- una transacción (supabase/remitos/ensayo.sql).
-- =============================================================

-- ── 1) remitos_list ──────────────────────────────────────────────
-- Copia de 20261015120001. 'por_facturar' no es un estado guardado: es "le queda algo sin
-- facturar", sin contar lo reservado por un borrador (RemitosAPI.pendientes, para armar una
-- factura). Sólo puede pasarle a un remito 'pendiente': crm_remito_recalcular marca 'facturado'
-- cuando todo está asignado a facturas emitidas.
CREATE OR REPLACE FUNCTION remitos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL,
  p_cliente_id integer DEFAULT NULL, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT r.id, count(*) OVER () AS total_filas
    FROM remitos r
    JOIN clientes c ON c.id = r.cliente_id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_estado IS NULL OR r.estado = p_estado
           OR (p_estado = 'por_facturar' AND r.estado = 'pendiente'
               AND EXISTS (SELECT 1 FROM crm_remito_items_sin_facturar(r.id) s WHERE s.sin_facturar > 0)))
      AND (p_cliente_id IS NULL OR r.cliente_id = p_cliente_id)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
  SELECT to_jsonb(t) FROM (
    SELECT r.*,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase, c.direccion, c.email, c.telefono,
      f.numero AS factura_numero,
      crm_remito_bloqueado(r.id) AS bloqueado,
      COALESCE(sum(s.sin_facturar), 0) AS sin_facturar_total,
      -- Las facturas emitidas a las que está asignado ("Factura vinculada"); un borrador no.
      COALESCE((SELECT json_agg(json_build_object('id', x.id, 'numero', x.numero) ORDER BY x.numero)
                FROM (SELECT DISTINCT fa.id, fa.numero
                      FROM remito_items rx
                      JOIN remito_item_facturas a ON a.remito_item_id = rx.id
                      JOIN facturas fa ON fa.id = a.factura_id
                      WHERE rx.remito_id = r.id AND fa.estado <> 'anulada'
                        AND fa.estado_fiscal IN ('historico','autorizado')) x), '[]') AS facturas,
      json_agg(json_build_object(
        'id', ri.id, 'producto_id', ri.producto_id, 'codigo', pr.codigo, 'descripcion', ri.descripcion,
        'cantidad', ri.cantidad, 'precio_unitario', ri.precio_unitario,
        'descuento_item', ri.descuento_item, 'subtotal', ri.subtotal, 'orden', ri.orden,
        'alicuota_iva_id', ri.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', ri.pallets, 'unidades_por_pallet', ri.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte,
        'asignado', s.asignado, 'sin_facturar', s.sin_facturar,
        'asignaciones', COALESCE(asig.lista, '[]')
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items,
      pg.total_filas
    FROM pagina pg
    JOIN remitos r ON r.id = pg.id
    JOIN clientes c ON c.id = r.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN facturas f ON f.id = r.factura_id
    -- Una fila por renglón: lo asignado y lo que falta facturar, con la regla de las RPC.
    LEFT JOIN crm_remito_items_sin_facturar(r.id) s ON true
    LEFT JOIN remito_items ri ON ri.id = s.remito_item_id
    LEFT JOIN productos pr ON pr.id = ri.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = ri.alicuota_iva_id
    LEFT JOIN LATERAL (
      SELECT json_agg(json_build_object('factura_id', a.factura_id, 'factura_numero', fa.numero,
                                        'cantidad', a.cantidad, 'origen', a.origen)
                      ORDER BY fa.numero NULLS LAST, a.id) AS lista
      FROM remito_item_facturas a
      JOIN facturas fa ON fa.id = a.factura_id
      WHERE a.remito_item_id = ri.id AND fa.estado <> 'anulada'
    ) asig ON true
    GROUP BY r.id, c.id, ci.id, f.numero, pg.total_filas
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
  ) t;
$$;

-- ── 2) facturas_list ─────────────────────────────────────────────
-- Copia de 20261015160000. Los remitos de una factura son los que tienen alguna asignación a
-- ella (no los de remitos.factura_id, que guarda sólo la primera). remito_numero sigue saliendo
-- primero de facturas.remito_id.
CREATE OR REPLACE FUNCTION facturas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL, p_tipo text DEFAULT NULL,
  p_cliente_id integer DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_solo_sin_remito boolean DEFAULT false, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0,
  p_estado_fiscal text[] DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT f.id, count(*) OVER () AS total_filas
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    WHERE (p_id IS NULL OR f.id = p_id)
      AND (p_estado IS NULL OR (f.estado = p_estado AND f.estado_fiscal IN ('historico','autorizado')))
      AND (p_estado_fiscal IS NULL OR f.estado_fiscal = ANY (p_estado_fiscal))
      AND (p_tipo IS NULL OR f.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      AND (p_desde IS NULL OR f.fecha >= p_desde)
      AND (p_hasta IS NULL OR f.fecha <= p_hasta)
      AND (NOT p_solo_sin_remito OR (
             f.remito_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM remito_item_facturas a
                             JOIN remito_items rx ON rx.id = a.remito_item_id
                             JOIN remitos rr ON rr.id = rx.remito_id
                             WHERE a.factura_id = f.id AND rr.estado <> 'anulado')
             AND f.estado <> 'anulada'
             AND f.estado_fiscal IN ('historico','autorizado')))
      AND (p_q IS NULL OR f.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR (regexp_replace(p_q, '\D', '', 'g') <> ''
                           AND c.doc_nro LIKE '%'||regexp_replace(p_q, '\D', '', 'g')||'%'))
    ORDER BY f.fecha DESC, f.numero DESC, f.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  ),
  -- Los remitos no anulados con alguna asignación a las facturas de la página.
  rems AS (
    SELECT DISTINCT a.factura_id, rr.id, rr.numero
    FROM remito_item_facturas a
    JOIN remito_items rx ON rx.id = a.remito_item_id
    JOIN remitos rr ON rr.id = rx.remito_id
    WHERE a.factura_id IN (SELECT id FROM pagina) AND rr.estado <> 'anulado'
  )
  SELECT to_jsonb(t) FROM (
    SELECT f.*,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase, c.direccion, c.email, c.telefono,
      COALESCE(r.numero, (SELECT min(rm.numero) FROM rems rm WHERE rm.factura_id = f.id))
        AS remito_numero,
      (SELECT json_agg(json_build_object('id', rm.id, 'numero', rm.numero) ORDER BY rm.numero)
         FROM rems rm WHERE rm.factura_id = f.id) AS remitos,
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
      ) ORDER BY fi.orden) FILTER (WHERE fi.id IS NOT NULL) AS items,
      pg.total_filas
    FROM pagina pg
    JOIN facturas f ON f.id = pg.id
    JOIN clientes c ON c.id = f.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN remitos r ON r.id = f.remito_id
    LEFT JOIN presupuestos p ON p.id = f.presupuesto_id
    LEFT JOIN factura_items fi ON fi.factura_id = f.id
    LEFT JOIN productos pr ON pr.id = fi.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = fi.alicuota_iva_id
    GROUP BY f.id, c.id, ci.id, r.numero, p.numero, pg.total_filas
    ORDER BY f.fecha DESC, f.numero DESC, f.id DESC
  ) t;
$$;

-- ── 3) Informes de la solapa "⏳ Pendientes" ──────────────────────
-- Copia de 20261015130000: las facturas con algún producto pendiente de remitir, no las que no
-- tienen ningún remito.
CREATE OR REPLACE FUNCTION informe_facturas_pendientes_remitir()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT f.id, f.numero, f.fecha, f.total, f.estado, c.razon_social, c.doc_tipo, c.doc_nro,
      (CURRENT_DATE - f.fecha::date) AS dias_pendiente
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    WHERE f.id IN (SELECT p.factura_id FROM crm_facturas_pendientes(NULL) p)
    ORDER BY f.fecha ASC
  ) t;
$$;

-- Copia de 20261015120001: los remitos con algo sin facturar (no los 'pendiente', que incluyen
-- los reservados enteros por un borrador); cantidad_items = renglones con algo sin facturar.
CREATE OR REPLACE FUNCTION informe_remitos_pendientes_facturar()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT r.id, r.numero, r.fecha, c.razon_social, c.doc_tipo, c.doc_nro,
      COUNT(*) AS cantidad_items,
      (CURRENT_DATE - r.fecha::date) AS dias_pendiente
    FROM remitos r
    JOIN clientes c ON c.id = r.cliente_id
    CROSS JOIN LATERAL crm_remito_items_sin_facturar(r.id) s
    WHERE r.estado = 'pendiente' AND s.sin_facturar > 0
    GROUP BY r.id, c.id
    ORDER BY r.fecha ASC
  ) t;
$$;

-- ── Permisos ─────────────────────────────────────────────────────
-- Las reemplazadas conservan sus grants; se reafirman por la convención del proyecto.
REVOKE ALL ON FUNCTION remitos_list(integer, text, text, integer, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION facturas_list(integer, text, text, text, integer, date, date, boolean, integer, integer, text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION informe_facturas_pendientes_remitir() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION informe_remitos_pendientes_facturar() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION remitos_list(integer, text, text, integer, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION facturas_list(integer, text, text, text, integer, date, date, boolean, integer, integer, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION informe_facturas_pendientes_remitir() TO authenticated;
GRANT EXECUTE ON FUNCTION informe_remitos_pendientes_facturar() TO authenticated;
