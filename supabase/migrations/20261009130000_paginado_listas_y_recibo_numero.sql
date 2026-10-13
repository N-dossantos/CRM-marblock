-- ══════════════════════════════════════════════════════════════════
-- Mejoras del smoke del dry-run (2026-10-09) — PLAN_MIGRACION_TANGO.md, M11 y M7.
--
--   * M11 — paginado en el servidor. Con la historia de Tango cargada, las listas de comprobantes
--     traían todo de una: facturas 4.596 filas / ~9 MB de JSON (~0,8 s sólo en la base), remitos
--     6.835 / ~10 MB, recibos 3.701, facturas de compra 6.191 / ~8 MB, órdenes de pago 3.314.
--     facturas_list, remitos_list, recibos_list, facturas_compra_list y pagos_proveedor_list
--     reciben `p_limit` / `p_offset`. La página se elige ANTES de armar el JSON de los ítems (CTE
--     `pagina`, con los mismos filtros y el mismo orden), así que la base sólo agrega los renglones
--     de las filas que devuelve. Cada fila trae `total_filas` = cantidad total que cumple el filtro
--     (count(*) OVER () antes del LIMIT), para el "página X de Y".
--     `p_limit` NULL = sin límite (LIMIT NULL): el resto de los llamadores (get por id, PDF, remitos
--     pendientes de un cliente, consultas por cliente) no cambia. Se agrega `id DESC` como último
--     criterio de orden para que la paginación sea estable cuando fecha y número empatan.
--
--   * M7 — número de recibo editable. El recibo se hace sobre talonario y a veces una hoja se tacha
--     o se pierde la copia: el operador tiene que poder cargar otro número. crear_recibo recibe
--     `p_numero` opcional: NULL = siguiente_numero('recibo') como hasta ahora; con número, se valida
--     el formato, el UNIQUE de recibos.numero frena duplicados, y el contador sigue al talonario sin
--     volver nunca atrás (mismo criterio que crear_remito, 20260820120001).
--
-- Cambian las firmas: se DROPean las viejas (un parámetro nuevo crearía una SOBRECARGA y PostgREST
-- no podría resolver a cuál llamar) y se re-otorgan los permisos al final, revocando a anon.
-- ══════════════════════════════════════════════════════════════════

-- ── facturas_list ─────────────────────────────────────────────────
DROP FUNCTION IF EXISTS facturas_list(integer, text, text, text, integer, date, date, boolean);

CREATE FUNCTION facturas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL, p_tipo text DEFAULT NULL,
  p_cliente_id integer DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_solo_sin_remito boolean DEFAULT false, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT f.id, count(*) OVER () AS total_filas
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
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
    ORDER BY f.fecha DESC, f.numero DESC, f.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
  SELECT to_jsonb(t) FROM (
    SELECT f.*,
      c.razon_social, c.cuit, c.condicion_iva, c.direccion, c.email, c.telefono,
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
    LEFT JOIN remitos r ON r.id = f.remito_id
    LEFT JOIN presupuestos p ON p.id = f.presupuesto_id
    LEFT JOIN factura_items fi ON fi.factura_id = f.id
    LEFT JOIN productos pr ON pr.id = fi.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = fi.alicuota_iva_id
    GROUP BY f.id, c.id, r.numero, p.numero, pg.total_filas
    ORDER BY f.fecha DESC, f.numero DESC, f.id DESC
  ) t;
$$;

-- ── remitos_list ──────────────────────────────────────────────────
DROP FUNCTION IF EXISTS remitos_list(integer, text, text, integer);

CREATE FUNCTION remitos_list(
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
      AND (p_estado IS NULL OR r.estado = p_estado)
      AND (p_cliente_id IS NULL OR r.cliente_id = p_cliente_id)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
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
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items,
      pg.total_filas
    FROM pagina pg
    JOIN remitos r ON r.id = pg.id
    JOIN clientes c ON c.id = r.cliente_id
    LEFT JOIN facturas f ON f.id = r.factura_id
    LEFT JOIN remito_items ri ON ri.remito_id = r.id
    LEFT JOIN productos pr ON pr.id = ri.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = ri.alicuota_iva_id
    GROUP BY r.id, c.id, f.numero, pg.total_filas
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
  ) t;
$$;

-- ── recibos_list ──────────────────────────────────────────────────
DROP FUNCTION IF EXISTS recibos_list(integer, text, integer, date, date);

CREATE FUNCTION recibos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_cliente_id integer DEFAULT NULL,
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT r.id, count(*) OVER () AS total_filas
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
      pg.total_filas
    FROM pagina pg
    JOIN recibos r ON r.id = pg.id
    JOIN clientes c ON c.id = r.cliente_id
    LEFT JOIN recibo_facturas rf ON rf.recibo_id = r.id
    LEFT JOIN facturas f ON f.id = rf.factura_id
    LEFT JOIN recibo_medios rm ON rm.recibo_id = r.id
    GROUP BY r.id, c.id, pg.total_filas
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
  ) t;
$$;

-- ── facturas_compra_list ──────────────────────────────────────────
DROP FUNCTION IF EXISTS facturas_compra_list(integer, text, text, integer, date, date);

CREATE FUNCTION facturas_compra_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL,
  p_proveedor_id integer DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT fc.id, count(*) OVER () AS total_filas
    FROM facturas_compra fc
    JOIN proveedores p ON p.id = fc.proveedor_id
    WHERE (p_id IS NULL OR fc.id = p_id)
      AND (p_estado IS NULL OR fc.estado = p_estado)
      AND (p_proveedor_id IS NULL OR fc.proveedor_id = p_proveedor_id)
      AND (p_desde IS NULL OR fc.fecha >= p_desde)
      AND (p_hasta IS NULL OR fc.fecha <= p_hasta)
      AND (p_q IS NULL OR fc.numero ILIKE '%'||p_q||'%'
                       OR p.razon_social ILIKE '%'||p_q||'%'
                       OR p.cuit ILIKE '%'||p_q||'%')
    ORDER BY fc.fecha DESC, fc.numero DESC, fc.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
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
       WHERE d.factura_compra_id = fc.id) AS iva_detalle,
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id', pc.id, 'tipo', pc.tipo, 'jurisdiccion', pc.jurisdiccion,
                'base_imponible', pc.base_imponible, 'alicuota', pc.alicuota, 'monto', pc.monto
              ) ORDER BY pc.tipo, pc.jurisdiccion NULLS FIRST), '[]')
       FROM percepciones_compra pc WHERE pc.factura_compra_id = fc.id) AS percepciones,
      pg.total_filas
    FROM pagina pg
    JOIN facturas_compra fc ON fc.id = pg.id
    JOIN proveedores p ON p.id = fc.proveedor_id
    LEFT JOIN remitos_compra rc ON rc.id = fc.remito_compra_id
    LEFT JOIN facturas_compra_items fi ON fi.factura_compra_id = fc.id
    LEFT JOIN alicuotas_iva ai ON ai.id = fi.alicuota_iva_id
    GROUP BY fc.id, p.id, rc.numero, pg.total_filas
    ORDER BY fc.fecha DESC, fc.numero DESC, fc.id DESC
  ) t;
$$;

-- ── pagos_proveedor_list ──────────────────────────────────────────
DROP FUNCTION IF EXISTS pagos_proveedor_list(integer, text, integer, date, date);

CREATE FUNCTION pagos_proveedor_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_proveedor_id integer DEFAULT NULL,
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT pp.id, count(*) OVER () AS total_filas
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
      pg.total_filas
    FROM pagina pg
    JOIN pagos_proveedor pp ON pp.id = pg.id
    JOIN proveedores p ON p.id = pp.proveedor_id
    LEFT JOIN pago_proveedor_facturas pf ON pf.pago_proveedor_id = pp.id
    LEFT JOIN facturas_compra fc ON fc.id = pf.factura_compra_id
    LEFT JOIN pago_proveedor_medios m ON m.pago_proveedor_id = pp.id
    LEFT JOIN retenciones r ON r.pago_proveedor_id = pp.id
    GROUP BY pp.id, p.id, pg.total_filas
    ORDER BY pp.fecha DESC, pp.numero DESC, pp.id DESC
  ) t;
$$;

-- ── M7: crear_recibo con número opcional ──────────────────────────
-- Misma lógica que 20260731120005 (cobranza en tesorería incluida); sólo cambia de dónde sale el
-- número.
DROP FUNCTION IF EXISTS crear_recibo(integer, jsonb, jsonb, text);

CREATE FUNCTION crear_recibo(
  p_cliente_id    integer,
  p_medios        jsonb,
  p_factura_ids   jsonb   DEFAULT '[]'::jsonb,
  p_observaciones text    DEFAULT NULL,
  p_numero        varchar DEFAULT NULL
)
RETURNS recibos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num    record;
  v_numero varchar;
  v_pv     CHAR(5);
  v_comp   INTEGER;
  v_recibo recibos;
  v_total  numeric;
  v_bad    text;
  v_fid    integer;
  v_m      jsonb;
  v_rm_id  integer;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_medios IS NULL OR jsonb_array_length(p_medios) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un medio de pago.';
  END IF;

  SELECT COALESCE(SUM((m->>'monto')::numeric), 0) INTO v_total
  FROM jsonb_array_elements(p_medios) AS m;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'El total debe ser mayor a cero.';
  END IF;

  SELECT (m->>'tipo') INTO v_bad
  FROM jsonb_array_elements(p_medios) AS m
  WHERE (m->>'tipo') NOT IN ('efectivo','transferencia','cheque','echeq')
  LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Medio de pago inválido: %', v_bad;
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_medios) AS m
    WHERE COALESCE((m->>'monto')::numeric, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'El monto de cada medio debe ser mayor a cero.';
  END IF;

  v_numero := NULLIF(trim(p_numero), '');
  IF v_numero IS NULL THEN
    SELECT * INTO v_num FROM siguiente_numero('recibo');
    v_numero := v_num.numero_formateado;
    v_pv     := v_num.punto_venta;
    v_comp   := v_num.numero;
  ELSE
    IF v_numero !~ '^\d{5}-\d{8}$' THEN
      RAISE EXCEPTION 'El número % no tiene el formato PPPPP-NNNNNNNN (ej. 00001-00004289).', v_numero;
    END IF;
    v_pv   := split_part(v_numero, '-', 1);
    v_comp := split_part(v_numero, '-', 2)::INTEGER;
  END IF;

  BEGIN
    INSERT INTO recibos (numero, punto_venta, numero_comp, fecha, cliente_id, total, observaciones)
    VALUES (v_numero, v_pv, v_comp, CURRENT_DATE, p_cliente_id, v_total, p_observaciones)
    RETURNING * INTO v_recibo;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'El recibo % ya fue emitido.', v_numero;
  END;

  -- Número manual: el contador sigue al talonario y nunca vuelve atrás — cargar un número salteado
  -- (la copia que apareció) no hace que la próxima sugerencia repita hojas ya usadas.
  IF p_numero IS NOT NULL THEN
    UPDATE contadores
       SET ultimo_numero = v_comp,
           punto_venta   = v_pv
     WHERE tipo = 'recibo'
       AND (punto_venta <> v_pv OR ultimo_numero < v_comp);
  END IF;

  FOR v_fid IN SELECT value::integer FROM jsonb_array_elements_text(p_factura_ids) LOOP
    PERFORM 1 FROM facturas
      WHERE id = v_fid AND cliente_id = p_cliente_id AND estado <> 'anulada';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Factura % inválida.', v_fid;
    END IF;
    INSERT INTO recibo_facturas (recibo_id, factura_id) VALUES (v_recibo.id, v_fid);
  END LOOP;

  FOR v_m IN SELECT value FROM jsonb_array_elements(p_medios) LOOP
    INSERT INTO recibo_medios
      (recibo_id, tipo, detalle, numero_cheque, banco, titular, cuit_titular,
       fecha_emision, fecha_vcto, monto)
    VALUES
      (v_recibo.id, v_m->>'tipo', v_m->>'detalle', v_m->>'numero_cheque', v_m->>'banco',
       v_m->>'titular', v_m->>'cuit_titular',
       NULLIF(v_m->>'fecha_emision','')::date, NULLIF(v_m->>'fecha_vcto','')::date,
       (v_m->>'monto')::numeric)
    RETURNING id INTO v_rm_id;

    IF v_m->>'tipo' IN ('cheque','echeq') AND NULLIF(v_m->>'numero_cheque','') IS NOT NULL THEN
      INSERT INTO cheques
        (numero, tipo, banco, titular, cuit_titular, fecha_emision, fecha_vcto, monto, cliente_id, estado)
      VALUES
        (v_m->>'numero_cheque',
         CASE WHEN v_m->>'tipo' = 'cheque' THEN 'fisico' ELSE 'echeq' END,
         v_m->>'banco', v_m->>'titular', v_m->>'cuit_titular',
         NULLIF(v_m->>'fecha_emision','')::date, NULLIF(v_m->>'fecha_vcto','')::date,
         (v_m->>'monto')::numeric, p_cliente_id, 'en_cartera')
      ON CONFLICT DO NOTHING;
    END IF;

    IF v_m->>'tipo' IN ('efectivo','transferencia')
       AND NULLIF(v_m->>'cuenta_bancaria_id','') IS NOT NULL THEN
      PERFORM tes_emitir_cobranza(v_rm_id, NULLIF(v_m->>'cuenta_bancaria_id','')::int);
    END IF;
  END LOOP;

  FOR v_fid IN SELECT value::integer FROM jsonb_array_elements_text(p_factura_ids) LOOP
    PERFORM recalcular_estado_factura(v_fid);
  END LOOP;

  RETURN v_recibo;
END;
$$;

-- ── Permisos ───────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION facturas_list(integer, text, text, text, integer, date, date, boolean, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION remitos_list(integer, text, text, integer, integer, integer)                           FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION recibos_list(integer, text, integer, date, date, integer, integer)                     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION facturas_compra_list(integer, text, text, integer, date, date, integer, integer)       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION pagos_proveedor_list(integer, text, integer, date, date, integer, integer)             FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_recibo(integer, jsonb, jsonb, text, varchar)                                     FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION facturas_list(integer, text, text, text, integer, date, date, boolean, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION remitos_list(integer, text, text, integer, integer, integer)                           TO authenticated;
GRANT EXECUTE ON FUNCTION recibos_list(integer, text, integer, date, date, integer, integer)                     TO authenticated;
GRANT EXECUTE ON FUNCTION facturas_compra_list(integer, text, text, integer, date, date, integer, integer)       TO authenticated;
GRANT EXECUTE ON FUNCTION pagos_proveedor_list(integer, text, integer, date, date, integer, integer)             TO authenticated;
GRANT EXECUTE ON FUNCTION crear_recibo(integer, jsonb, jsonb, text, varchar)                                     TO authenticated;
