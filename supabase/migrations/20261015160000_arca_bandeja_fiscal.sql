-- =============================================================
-- ARCA — bandeja fiscal para la UI (PLAN_ARCA.md §5, Fase 5)
--
-- Lo que la pantalla necesita de la base para operar los comprobantes sin CAE; la emisión y la
-- reconciliación no cambian (Edge Function `arca` + RPCs arca_*).
--
-- 1) facturas_list: filtro por estado fiscal. La lista es paginada, así que la bandeja (borradores,
--    rechazados, inciertos) y el selector de factura de las NC/ND (sólo fiscales) filtran acá.
-- 2) notas_list: el estado fiscal de la factura asociada, para avisar cuando es histórica (se
--    verifica a mano en la web de ARCA, §4).
-- 3) arca_bandeja: cuántos comprobantes hay sin CAE, por estado, para el Dashboard y las listas.
-- =============================================================

-- Los comprobantes sin CAE son pocos y los que más se consultan (bandeja, contadores): índice
-- parcial, sin el histórico ni los autorizados.
CREATE INDEX idx_facturas_sin_cae ON facturas (estado_fiscal)
  WHERE estado_fiscal NOT IN ('historico','autorizado');
CREATE INDEX idx_notas_sin_cae ON notas (estado_fiscal)
  WHERE estado_fiscal NOT IN ('historico','autorizado');

-- ── 1) facturas_list ─────────────────────────────────────────────
-- Mismo cuerpo que 20261015130000, más p_estado_fiscal (NULL = todos). Cambia la firma: se borra
-- la anterior para no dejar dos versiones que hagan ambigua la llamada por nombre.
DROP FUNCTION IF EXISTS facturas_list(integer, text, text, text, integer, date, date, boolean, integer, integer);

CREATE FUNCTION facturas_list(
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
             AND NOT EXISTS (SELECT 1 FROM remitos rr WHERE rr.factura_id = f.id)
             AND f.estado <> 'anulada'
             AND f.estado_fiscal IN ('historico','autorizado')))
      AND (p_q IS NULL OR f.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR (regexp_replace(p_q, '\D', '', 'g') <> ''
                           AND c.doc_nro LIKE '%'||regexp_replace(p_q, '\D', '', 'g')||'%'))
    ORDER BY f.fecha DESC, f.numero DESC, f.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
  SELECT to_jsonb(t) FROM (
    SELECT f.*,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase, c.direccion, c.email, c.telefono,
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

-- ── 2) notas_list ────────────────────────────────────────────────
-- Misma firma y cuerpo que 20261015120001, más factura_estado_fiscal.
CREATE OR REPLACE FUNCTION notas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_tipo text DEFAULT NULL, p_cliente_id integer DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT n.*,
      f.numero AS factura_numero, f.tipo AS factura_tipo, f.estado_fiscal AS factura_estado_fiscal,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase, c.direccion,
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
    LEFT JOIN facturas f ON f.id = n.factura_id
    LEFT JOIN clientes c ON c.id = COALESCE(n.cliente_id, f.cliente_id)
    LEFT JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN nota_items ni ON ni.nota_id = n.id
    LEFT JOIN productos pr ON pr.id = ni.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = ni.alicuota_iva_id
    WHERE (p_id IS NULL OR n.id = p_id)
      AND (p_tipo IS NULL OR n.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR COALESCE(n.cliente_id, f.cliente_id) = p_cliente_id)
      AND (p_q IS NULL OR n.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR f.numero ILIKE '%'||p_q||'%')
    GROUP BY n.id, f.numero, f.tipo, f.estado_fiscal, c.id, ci.id
    ORDER BY n.fecha DESC
  ) t;
$$;

-- ── 3) arca_bandeja ──────────────────────────────────────────────
-- Comprobantes sin CAE por estado. Los inciertos son los urgentes: bloquean su serie hasta que se
-- reconcilien (§4). SECURITY INVOKER: lee con los permisos del staff, como las listas.
CREATE FUNCTION arca_bandeja()
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'facturas', (SELECT jsonb_build_object(
        'borrador',           count(*) FILTER (WHERE estado_fiscal = 'borrador'),
        'rechazado',          count(*) FILTER (WHERE estado_fiscal = 'rechazado'),
        'resultado_incierto', count(*) FILTER (WHERE estado_fiscal = 'resultado_incierto'),
        'en_proceso',         count(*) FILTER (WHERE estado_fiscal = 'en_proceso'))
      FROM facturas WHERE estado_fiscal NOT IN ('historico','autorizado')),
    'notas', (SELECT jsonb_build_object(
        'borrador',           count(*) FILTER (WHERE estado_fiscal = 'borrador'),
        'rechazado',          count(*) FILTER (WHERE estado_fiscal = 'rechazado'),
        'resultado_incierto', count(*) FILTER (WHERE estado_fiscal = 'resultado_incierto'),
        'en_proceso',         count(*) FILTER (WHERE estado_fiscal = 'en_proceso'))
      FROM notas WHERE estado_fiscal NOT IN ('historico','autorizado')));
$$;

-- ── Permisos ─────────────────────────────────────────────────────
-- facturas_list es una función nueva (DROP + CREATE): los DEFAULT PRIVILEGES de Supabase le dan
-- EXECUTE a anon. notas_list conserva los suyos (CREATE OR REPLACE).
REVOKE ALL ON FUNCTION facturas_list(integer, text, text, text, integer, date, date, boolean, integer, integer, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION facturas_list(integer, text, text, text, integer, date, date, boolean, integer, integer, text[]) TO authenticated;
REVOKE ALL ON FUNCTION arca_bandeja() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION arca_bandeja() TO authenticated;
