-- =============================================================
-- CRM — Fase A / migración 0106: RPC facturas de compra  §4.5/§4.11
-- Espeja el patrón crear_/actualizar_/anular de Ventas, con una divergencia clave (§4.11):
-- punto_venta/numero_comp son DEL PROVEEDOR y entran como PARÁMETROS (no siguiente_numero).
-- Los totales los recalcula el servidor con crm_calc_totales_multi_alicuota (anti-tamper) y
-- se persiste el desglose por alícuota en factura_compra_iva_detalle.
-- =============================================================

-- ── Helpers internos ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm_insert_factura_compra_items(
  p_factura_compra_id integer, p_items jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO facturas_compra_items
    (factura_compra_id, material_id, descripcion, cantidad, precio_unitario,
     descuento_item, alicuota_iva_id, subtotal, orden)
  SELECT
    p_factura_compra_id,
    NULLIF(e.item->>'material_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    COALESCE(NULLIF(e.item->>'alicuota_iva_id', '')::int,
             (SELECT id FROM alicuotas_iva WHERE porcentaje = 21)),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_factura_compra_iva_detalle(
  p_factura_compra_id integer, p_detalle jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO factura_compra_iva_detalle (factura_compra_id, alicuota_iva_id, neto_gravado, iva_monto)
  SELECT p_factura_compra_id, (d->>'alicuota_iva_id')::int,
         (d->>'neto_gravado')::numeric, (d->>'iva_monto')::numeric
  FROM jsonb_array_elements(p_detalle) AS d;
END;
$$;

-- ── recalcular_estado_factura_compra  (espeja recalcular_estado_factura de 0001) ──
-- Cubierto = pagos imputados (medios) + retenciones de esos pagos + notas de crédito.
-- Misma simplificación de imputación múltiple que Ventas (se atribuye el pago completo a
-- cada factura que toca; en la práctica un pago imputa una factura).
CREATE OR REPLACE FUNCTION recalcular_estado_factura_compra(p_factura_compra_id integer)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_total  numeric;
  v_pagado numeric;
  v_ret    numeric;
  v_nc     numeric;
BEGIN
  SELECT total INTO v_total FROM facturas_compra WHERE id = p_factura_compra_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT COALESCE(SUM(m.monto), 0) INTO v_pagado
  FROM pago_proveedor_medios m
  JOIN pago_proveedor_facturas pf ON pf.pago_proveedor_id = m.pago_proveedor_id
  WHERE pf.factura_compra_id = p_factura_compra_id;

  SELECT COALESCE(SUM(r.monto), 0) INTO v_ret
  FROM retenciones r
  JOIN pago_proveedor_facturas pf ON pf.pago_proveedor_id = r.pago_proveedor_id
  WHERE pf.factura_compra_id = p_factura_compra_id;

  SELECT COALESCE(SUM(total), 0) INTO v_nc
  FROM notas_compra
  WHERE factura_compra_id = p_factura_compra_id AND tipo = 'NC';

  v_pagado := v_pagado + v_ret + v_nc;

  UPDATE facturas_compra SET
    estado = CASE
      WHEN v_pagado <= 0              THEN 'pendiente'
      WHEN v_pagado >= v_total - 0.01 THEN 'pagada'
      ELSE                                 'parcial'
    END,
    updated_at = NOW()
  WHERE id = p_factura_compra_id AND estado <> 'anulada';
END;
$$;

-- ── crear_factura_compra ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION crear_factura_compra(
  p_proveedor_id        integer,
  p_punto_venta         text,
  p_numero_comp         integer,
  p_fecha               date,
  p_items               jsonb,
  p_tipo                varchar DEFAULT 'A',
  p_descuento_general   numeric DEFAULT 0,
  p_fecha_recepcion     date    DEFAULT NULL,
  p_remito_compra_id    integer DEFAULT NULL,
  p_cae                 text    DEFAULT NULL,
  p_afip_tipo_comprobante text  DEFAULT NULL,
  p_observaciones       text    DEFAULT NULL
)
RETURNS facturas_compra
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_tot    jsonb;
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

  INSERT INTO facturas_compra
    (proveedor_id, tipo, punto_venta, numero_comp, numero, fecha, fecha_recepcion,
     remito_compra_id, cae, afip_tipo_comprobante, descuento_general,
     subtotal, descuento_monto, neto_gravado, iva_monto, total, estado, observaciones)
  VALUES
    (p_proveedor_id, COALESCE(p_tipo, 'A'), lpad(p_punto_venta, 5, '0'), p_numero_comp, v_numero,
     p_fecha, COALESCE(p_fecha_recepcion, CURRENT_DATE), p_remito_compra_id, p_cae,
     p_afip_tipo_comprobante, COALESCE(p_descuento_general, 0),
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric,
     (v_tot->>'neto_gravado')::numeric, (v_tot->>'iva_monto')::numeric,
     (v_tot->>'total')::numeric, 'pendiente', p_observaciones)
  RETURNING * INTO v_fc;

  PERFORM crm_insert_factura_compra_items(v_fc.id, p_items);
  PERFORM crm_insert_factura_compra_iva_detalle(v_fc.id, v_tot->'detalle');

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

-- ── actualizar_factura_compra ─────────────────────────────────────
CREATE OR REPLACE FUNCTION actualizar_factura_compra(
  p_id                  integer,
  p_proveedor_id        integer,
  p_punto_venta         text,
  p_numero_comp         integer,
  p_fecha               date,
  p_items               jsonb,
  p_tipo                varchar DEFAULT 'A',
  p_descuento_general   numeric DEFAULT 0,
  p_fecha_recepcion     date    DEFAULT NULL,
  p_cae                 text    DEFAULT NULL,
  p_afip_tipo_comprobante text  DEFAULT NULL,
  p_observaciones       text    DEFAULT NULL
)
RETURNS facturas_compra
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur    facturas_compra;
  v_tot    jsonb;
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
    total                 = (v_tot->>'total')::numeric,
    observaciones         = p_observaciones,
    updated_at            = NOW()
  WHERE id = p_id
  RETURNING * INTO v_fc;

  DELETE FROM facturas_compra_items      WHERE factura_compra_id = p_id;
  DELETE FROM factura_compra_iva_detalle WHERE factura_compra_id = p_id;
  PERFORM crm_insert_factura_compra_items(p_id, p_items);
  PERFORM crm_insert_factura_compra_iva_detalle(p_id, v_tot->'detalle');
  PERFORM recalcular_estado_factura_compra(p_id);

  SELECT * INTO v_fc FROM facturas_compra WHERE id = p_id;
  RETURN v_fc;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Ya existe una factura % del proveedor con ese punto de venta y número (%).',
    COALESCE(p_tipo, 'A'), v_numero;
END;
$$;

-- ── factura_compra_anular ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION factura_compra_anular(p_id integer)
RETURNS facturas_compra
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_fc facturas_compra;
BEGIN
  UPDATE facturas_compra SET estado = 'anulada', updated_at = NOW()
  WHERE id = p_id
  RETURNING * INTO v_fc;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;

  -- si tenía un remito de compra ligado, revertirlo a pendiente
  UPDATE remitos_compra SET estado = 'pendiente', factura_compra_id = NULL, updated_at = NOW()
  WHERE factura_compra_id = p_id;

  RETURN v_fc;
END;
$$;

-- ── Permisos ──────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION crm_insert_factura_compra_items(integer, jsonb)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_factura_compra_iva_detalle(integer, jsonb)  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION recalcular_estado_factura_compra(integer)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_factura_compra(integer, text, integer, date, jsonb, varchar, numeric, date, integer, text, text, text)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_factura_compra(integer, integer, text, integer, date, jsonb, varchar, numeric, date, text, text, text)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION factura_compra_anular(integer)                         FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_factura_compra(integer, text, integer, date, jsonb, varchar, numeric, date, integer, text, text, text)      TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_factura_compra(integer, integer, text, integer, date, jsonb, varchar, numeric, date, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION factura_compra_anular(integer)                       TO authenticated;
