-- =============================================================
-- Compras — percepciones sufridas: RPC de escritura y lecturas
-- PLAN_MAESTRO.md §3.9 pasos 2 y 3 · continúa 20261006140000_percepciones_compra_schema.sql
--
-- Las tres RPC de escritura reciben `p_percepciones jsonb` como ÚLTIMO parámetro (opcional) y
-- liquidan `total = neto_gravado + iva_monto + percepciones_monto`.
--
-- DROP + CREATE y no CREATE OR REPLACE: con una lista de argumentos distinta, REPLACE crea una
-- SOBRECARGA en vez de reemplazar, y dos `crear_factura_compra` conviviendo es ambigüedad que
-- PostgREST no puede resolver (mismo razonamiento que 20260821130000 y 20260821140000).
--
-- `recalcular_estado_factura_compra`, `informe_cta_cte_proveedor` y los pagos trabajan sobre
-- `total`, que ya incluye la percepción: no se tocan (verificado leyendo las tres).
-- =============================================================

-- ── 1) crear_factura_compra: + p_percepciones ────────────────────
DROP FUNCTION IF EXISTS crear_factura_compra(integer, text, integer, date, jsonb, varchar, numeric, date, integer, text, text, text);

CREATE OR REPLACE FUNCTION crear_factura_compra(
  p_proveedor_id          integer,
  p_punto_venta           text,
  p_numero_comp           integer,
  p_fecha                 date,
  p_items                 jsonb,
  p_tipo                  varchar DEFAULT 'A',
  p_descuento_general     numeric DEFAULT 0,
  p_fecha_recepcion       date    DEFAULT NULL,
  p_remito_compra_id      integer DEFAULT NULL,
  p_cae                   text    DEFAULT NULL,
  p_afip_tipo_comprobante text    DEFAULT NULL,
  p_observaciones         text    DEFAULT NULL,
  p_percepciones          jsonb   DEFAULT NULL
)
RETURNS facturas_compra
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_tot    jsonb;
  v_perc   jsonb;
  v_numero varchar;
  v_fc     facturas_compra;
BEGIN
  IF p_proveedor_id IS NULL THEN
    RAISE EXCEPTION 'El proveedor es obligatorio.';
  END IF;
  IF p_punto_venta IS NULL OR p_numero_comp IS NULL THEN
    RAISE EXCEPTION 'Punto de venta y número del comprobante son obligatorios.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  v_numero := lpad(p_punto_venta, 5, '0') || '-' || lpad(p_numero_comp::text, 8, '0');
  v_tot    := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  v_perc   := crm_calc_percepciones_compra(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  INSERT INTO facturas_compra
    (proveedor_id, tipo, punto_venta, numero_comp, numero, fecha, fecha_recepcion,
     remito_compra_id, cae, afip_tipo_comprobante, descuento_general,
     subtotal, descuento_monto, neto_gravado, iva_monto, percepciones_monto, total, estado, observaciones)
  VALUES
    (p_proveedor_id, COALESCE(p_tipo, 'A'), lpad(p_punto_venta, 5, '0'), p_numero_comp, v_numero,
     p_fecha, COALESCE(p_fecha_recepcion, CURRENT_DATE), p_remito_compra_id, p_cae,
     p_afip_tipo_comprobante, COALESCE(p_descuento_general, 0),
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric,
     (v_tot->>'neto_gravado')::numeric, (v_tot->>'iva_monto')::numeric,
     (v_perc->>'total')::numeric,
     round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
     'pendiente', p_observaciones)
  RETURNING * INTO v_fc;

  PERFORM crm_insert_factura_compra_items(v_fc.id, p_items);
  PERFORM crm_insert_factura_compra_iva_detalle(v_fc.id, v_tot->'detalle');
  PERFORM crm_insert_percepciones_compra(v_fc.id, NULL, v_perc->'detalle');

  IF p_remito_compra_id IS NOT NULL THEN
    UPDATE remitos_compra SET estado = 'facturado', factura_compra_id = v_fc.id, updated_at = NOW()
    WHERE id = p_remito_compra_id;
  END IF;

  RETURN v_fc;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Ya existe una factura % del proveedor con ese punto de venta y número (%).',
    COALESCE(p_tipo, 'A'), v_numero;
END;
$$;

-- ── 2) actualizar_factura_compra: + p_percepciones ───────────────
DROP FUNCTION IF EXISTS actualizar_factura_compra(integer, integer, text, integer, date, jsonb, varchar, numeric, date, text, text, text);

CREATE OR REPLACE FUNCTION actualizar_factura_compra(
  p_id                    integer,
  p_proveedor_id          integer,
  p_punto_venta           text,
  p_numero_comp           integer,
  p_fecha                 date,
  p_items                 jsonb,
  p_tipo                  varchar DEFAULT 'A',
  p_descuento_general     numeric DEFAULT 0,
  p_fecha_recepcion       date    DEFAULT NULL,
  p_cae                   text    DEFAULT NULL,
  p_afip_tipo_comprobante text    DEFAULT NULL,
  p_observaciones         text    DEFAULT NULL,
  p_percepciones          jsonb   DEFAULT NULL
)
RETURNS facturas_compra
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur    facturas_compra;
  v_tot    jsonb;
  v_perc   jsonb;
  v_numero varchar;
  v_fc     facturas_compra;
BEGIN
  SELECT * INTO v_cur FROM facturas_compra WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;
  IF v_cur.estado IN ('pagada','anulada') THEN
    RAISE EXCEPTION 'No se puede editar una factura de compra pagada o anulada.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  v_numero := lpad(p_punto_venta, 5, '0') || '-' || lpad(p_numero_comp::text, 8, '0');
  v_tot    := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  v_perc   := crm_calc_percepciones_compra(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  UPDATE facturas_compra SET
    proveedor_id          = p_proveedor_id,
    tipo                  = COALESCE(p_tipo, 'A'),
    punto_venta           = lpad(p_punto_venta, 5, '0'),
    numero_comp           = p_numero_comp,
    numero                = v_numero,
    fecha                 = p_fecha,
    fecha_recepcion       = COALESCE(p_fecha_recepcion, fecha_recepcion),
    cae                   = p_cae,
    afip_tipo_comprobante = p_afip_tipo_comprobante,
    descuento_general     = COALESCE(p_descuento_general, 0),
    subtotal              = (v_tot->>'subtotal')::numeric,
    descuento_monto       = (v_tot->>'descuento_monto')::numeric,
    neto_gravado          = (v_tot->>'neto_gravado')::numeric,
    iva_monto             = (v_tot->>'iva_monto')::numeric,
    percepciones_monto    = (v_perc->>'total')::numeric,
    total                 = round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
    observaciones         = p_observaciones,
    updated_at            = NOW()
  WHERE id = p_id
  RETURNING * INTO v_fc;

  DELETE FROM facturas_compra_items      WHERE factura_compra_id = p_id;
  DELETE FROM factura_compra_iva_detalle WHERE factura_compra_id = p_id;
  DELETE FROM percepciones_compra        WHERE factura_compra_id = p_id;
  PERFORM crm_insert_factura_compra_items(p_id, p_items);
  PERFORM crm_insert_factura_compra_iva_detalle(p_id, v_tot->'detalle');
  PERFORM crm_insert_percepciones_compra(p_id, NULL, v_perc->'detalle');
  PERFORM recalcular_estado_factura_compra(p_id);

  SELECT * INTO v_fc FROM facturas_compra WHERE id = p_id;
  RETURN v_fc;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Ya existe una factura % del proveedor con ese punto de venta y número (%).',
    COALESCE(p_tipo, 'A'), v_numero;
END;
$$;

-- ── 3) crear_nota_compra: + p_percepciones ───────────────────────
DROP FUNCTION IF EXISTS crear_nota_compra(integer, varchar, text, integer, date, jsonb, varchar, text, text);

CREATE OR REPLACE FUNCTION crear_nota_compra(
  p_factura_compra_id integer,
  p_tipo              varchar,
  p_punto_venta       text,
  p_numero_comp       integer,
  p_fecha             date,
  p_items             jsonb,
  p_tipo_letra        varchar DEFAULT 'A',
  p_motivo            text    DEFAULT NULL,
  p_observaciones     text    DEFAULT NULL,
  p_percepciones      jsonb   DEFAULT NULL
)
RETURNS notas_compra
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_prov   integer;
  v_tot    jsonb;
  v_perc   jsonb;
  v_numero varchar;
  v_nc     notas_compra;
BEGIN
  IF p_tipo NOT IN ('NC','ND') THEN
    RAISE EXCEPTION 'Tipo de nota inválido (NC/ND).';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  -- factura_compra_id admite NULL en la base (las 3 ND "a cuenta" de Tango), pero una nota creada
  -- desde la app siempre cuelga de una factura: de ahí sale el proveedor.
  SELECT proveedor_id INTO v_prov FROM facturas_compra WHERE id = p_factura_compra_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;

  v_numero := lpad(p_punto_venta, 5, '0') || '-' || lpad(p_numero_comp::text, 8, '0');
  v_tot    := crm_calc_totales_multi_alicuota(p_items, 0);
  v_perc   := crm_calc_percepciones_compra(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  INSERT INTO notas_compra
    (proveedor_id, tipo, tipo_letra, punto_venta, numero_comp, numero, fecha, factura_compra_id,
     motivo, subtotal, descuento_monto, neto_gravado, iva_monto, percepciones_monto, total, observaciones)
  VALUES
    (v_prov, p_tipo, COALESCE(p_tipo_letra, 'A'), lpad(p_punto_venta, 5, '0'), p_numero_comp,
     v_numero, p_fecha, p_factura_compra_id, p_motivo,
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric,
     (v_tot->>'neto_gravado')::numeric, (v_tot->>'iva_monto')::numeric,
     (v_perc->>'total')::numeric,
     round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
     p_observaciones)
  RETURNING * INTO v_nc;

  PERFORM crm_insert_nota_compra_items(v_nc.id, p_items);
  PERFORM crm_insert_percepciones_compra(NULL, v_nc.id, v_perc->'detalle');
  -- El saldo de la factura sale de notas_compra.total, que ahora incluye la percepción.
  PERFORM recalcular_estado_factura_compra(p_factura_compra_id);
  RETURN v_nc;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Ya existe una nota % del proveedor con ese punto de venta y número (%).', p_tipo, v_numero;
END;
$$;

-- ── 4) facturas_compra_list: expone el detalle de percepciones ───
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
       WHERE d.factura_compra_id = fc.id) AS iva_detalle,
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id', pc.id, 'tipo', pc.tipo, 'jurisdiccion', pc.jurisdiccion,
                'base_imponible', pc.base_imponible, 'alicuota', pc.alicuota, 'monto', pc.monto
              ) ORDER BY pc.tipo, pc.jurisdiccion NULLS FIRST), '[]')
       FROM percepciones_compra pc WHERE pc.factura_compra_id = fc.id) AS percepciones
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

-- ── 5) notas_compra_list: percepciones + LEFT JOIN a la factura ──
-- El JOIN a facturas_compra era INNER: con `factura_compra_id` NULL (las 3 ND "a cuenta" de Tango,
-- 20261006130000) esas notas desaparecían de la lista. El proveedor sale de notas_compra, no de la
-- factura, así que la nota se ve igual sin factura asociada.
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
      ) ORDER BY ni.orden) FILTER (WHERE ni.id IS NOT NULL) AS items,
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'id', pc.id, 'tipo', pc.tipo, 'jurisdiccion', pc.jurisdiccion,
                'base_imponible', pc.base_imponible, 'alicuota', pc.alicuota, 'monto', pc.monto
              ) ORDER BY pc.tipo, pc.jurisdiccion NULLS FIRST), '[]')
       FROM percepciones_compra pc WHERE pc.nota_compra_id = nc.id) AS percepciones
    FROM notas_compra nc
    LEFT JOIN facturas_compra fc ON fc.id = nc.factura_compra_id
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

-- ── 6) informe_iva_compras: percepciones en columna aparte ───────
-- La percepción NO suma al crédito fiscal: va en sus propias columnas (`percepcion_iva`,
-- `percepcion_iibb` por jurisdicción, `percepcion_otros`), que es lo que mira el contador para
-- computarlas como pago a cuenta. Las notas de compra se suman al libro con su signo (NC negativo).
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
        fc.neto_gravado, fc.iva_monto, fc.percepciones_monto, fc.total,
        (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'porcentaje', a.porcentaje, 'neto_gravado', d.neto_gravado, 'iva_monto', d.iva_monto
                ) ORDER BY a.porcentaje), '[]')
         FROM factura_compra_iva_detalle d JOIN alicuotas_iva a ON a.id = d.alicuota_iva_id
         WHERE d.factura_compra_id = fc.id) AS iva_detalle,
        COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                  WHERE pc.factura_compra_id = fc.id AND pc.tipo = 'iva'), 0)  AS percepcion_iva,
        COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                  WHERE pc.factura_compra_id = fc.id AND pc.tipo = 'iibb'), 0) AS percepcion_iibb,
        COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                  WHERE pc.factura_compra_id = fc.id
                    AND pc.tipo IN ('ganancias','imp_internos')), 0)           AS percepcion_otros,
        (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                  'tipo', pc.tipo, 'jurisdiccion', pc.jurisdiccion,
                  'alicuota', pc.alicuota, 'monto', pc.monto
                ) ORDER BY pc.tipo, pc.jurisdiccion NULLS FIRST), '[]')
         FROM percepciones_compra pc WHERE pc.factura_compra_id = fc.id) AS percepciones
      FROM facturas_compra fc
      JOIN proveedores p ON p.id = fc.proveedor_id
      WHERE fc.estado <> 'anulada' AND fc.fecha BETWEEN p_desde AND p_hasta
    ) x),
    -- Percepciones por tipo y jurisdicción, para el resumen del libro.
    'percepciones_resumen', (SELECT COALESCE(jsonb_agg(z ORDER BY z.tipo, z.jurisdiccion NULLS FIRST), '[]') FROM (
      SELECT pc.tipo, pc.jurisdiccion, COUNT(*) AS comprobantes, SUM(pc.monto) AS monto
      FROM percepciones_compra pc
      LEFT JOIN facturas_compra fc ON fc.id = pc.factura_compra_id
      LEFT JOIN notas_compra    nc ON nc.id = pc.nota_compra_id
      WHERE COALESCE(fc.fecha, nc.fecha) BETWEEN p_desde AND p_hasta
        AND COALESCE(fc.estado, 'ok') <> 'anulada'
      GROUP BY pc.tipo, pc.jurisdiccion
    ) z),
    'retenciones', (SELECT COALESCE(jsonb_agg(y ORDER BY y.fecha), '[]') FROM (
      SELECT r.fecha, r.tipo_retencion, r.jurisdiccion, r.numero_certificado, r.monto,
        p.razon_social, p.cuit
      FROM retenciones r JOIN proveedores p ON p.id = r.proveedor_id
      WHERE r.fecha BETWEEN p_desde AND p_hasta
    ) y),
    'totales', (SELECT jsonb_build_object(
      'neto_gravado',       COALESCE(SUM(fc.neto_gravado), 0),
      'iva_monto',          COALESCE(SUM(fc.iva_monto), 0),
      'percepciones_monto', COALESCE(SUM(fc.percepciones_monto), 0),
      'total',              COALESCE(SUM(fc.total), 0),
      'percepcion_iva',     COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                                      JOIN facturas_compra f2 ON f2.id = pc.factura_compra_id
                                      WHERE pc.tipo = 'iva' AND f2.estado <> 'anulada'
                                        AND f2.fecha BETWEEN p_desde AND p_hasta), 0),
      'percepcion_iibb',    COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                                      JOIN facturas_compra f2 ON f2.id = pc.factura_compra_id
                                      WHERE pc.tipo = 'iibb' AND f2.estado <> 'anulada'
                                        AND f2.fecha BETWEEN p_desde AND p_hasta), 0),
      'retenciones',        COALESCE((SELECT SUM(r.monto) FROM retenciones r
                                      WHERE r.fecha BETWEEN p_desde AND p_hasta), 0))
      FROM facturas_compra fc
      WHERE fc.estado <> 'anulada' AND fc.fecha BETWEEN p_desde AND p_hasta)
  ) INTO v;
  RETURN v;
END;
$$;

-- ── 7) Permisos ──────────────────────────────────────────────────
-- Las 3 RPC de escritura se recrearon con firma nueva ⇒ el DROP se llevó sus grants.
REVOKE ALL ON FUNCTION crear_factura_compra(integer, text, integer, date, jsonb, varchar, numeric, date, integer, text, text, text, jsonb)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_factura_compra(integer, integer, text, integer, date, jsonb, varchar, numeric, date, text, text, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_nota_compra(integer, varchar, text, integer, date, jsonb, varchar, text, text, jsonb)                              FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_factura_compra(integer, text, integer, date, jsonb, varchar, numeric, date, integer, text, text, text, jsonb)      TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_factura_compra(integer, integer, text, integer, date, jsonb, varchar, numeric, date, text, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION crear_nota_compra(integer, varchar, text, integer, date, jsonb, varchar, text, text, jsonb)                              TO authenticated;

-- Las lecturas se reemplazaron con CREATE OR REPLACE (misma firma): los grants siguen, pero se
-- re-afirman por si alguna corrió antes de 20260730120011.
REVOKE ALL ON FUNCTION facturas_compra_list(integer, text, text, integer, date, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION notas_compra_list(integer, text, text, integer)                FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION informe_iva_compras(date, date)                                FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION facturas_compra_list(integer, text, text, integer, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION notas_compra_list(integer, text, text, integer)                TO authenticated;
GRANT EXECUTE ON FUNCTION informe_iva_compras(date, date)                               TO authenticated;
