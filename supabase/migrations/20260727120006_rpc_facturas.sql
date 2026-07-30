-- =============================================================
-- CRM Ventas — Supabase migration 0006: RPC — facturas
-- Port of backend/src/routes/facturas.js (POST / PUT / PATCH anular).
-- Numbering is per tipo: Factura A -> contador 'factura_a', Factura B -> 'factura_b'.
-- IVA fijo 21%. Al vincular un remito lo marca 'facturado'; anular libera el remito.
-- tipo/numero son inmutables tras la emisión: actualizar_factura NO los toca (igual que el PUT).
-- =============================================================

-- Helper: inserta los ítems de una factura desde jsonb.
CREATE OR REPLACE FUNCTION crm_insert_factura_items(
  p_factura_id integer,
  p_items      jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO factura_items
    (factura_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden)
  SELECT
    p_factura_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

-- crear_factura  (port de POST /api/facturas)
CREATE OR REPLACE FUNCTION crear_factura(
  p_cliente_id        integer,
  p_items             jsonb,
  p_tipo              varchar DEFAULT 'A',
  p_descuento_general numeric DEFAULT 0,
  p_remito_id         integer DEFAULT NULL,
  p_presupuesto_id    integer DEFAULT NULL,
  p_observaciones     text    DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num      record;
  v_tot      record;
  v_fac      facturas;
  v_contador text;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;
  IF p_tipo NOT IN ('A','B') THEN
    RAISE EXCEPTION 'Tipo de factura inválido (A o B).';
  END IF;

  v_contador := CASE p_tipo WHEN 'A' THEN 'factura_a' ELSE 'factura_b' END;

  SELECT * INTO v_tot FROM crm_calc_totales(p_items, p_descuento_general);
  SELECT * INTO v_num FROM siguiente_numero(v_contador);

  INSERT INTO facturas
    (numero, punto_venta, numero_comp, tipo, fecha, cliente_id, remito_id, presupuesto_id,
     descuento_general, subtotal, descuento_monto, neto_gravado, iva_alicuota, iva_monto, total,
     estado, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, p_tipo, CURRENT_DATE, p_cliente_id,
     p_remito_id, p_presupuesto_id, COALESCE(p_descuento_general, 0),
     v_tot.subtotal, v_tot.descuento_monto, v_tot.neto_gravado, 21.00, v_tot.iva_monto, v_tot.total,
     'pendiente', p_observaciones)
  RETURNING * INTO v_fac;

  PERFORM crm_insert_factura_items(v_fac.id, p_items);

  IF p_remito_id IS NOT NULL THEN
    UPDATE remitos SET estado = 'facturado', factura_id = v_fac.id, updated_at = NOW()
    WHERE id = p_remito_id;
  END IF;
  IF p_presupuesto_id IS NOT NULL THEN
    UPDATE presupuestos SET estado = 'convertido', updated_at = NOW() WHERE id = p_presupuesto_id;
  END IF;

  RETURN v_fac;
END;
$$;

-- actualizar_factura  (port de PUT /api/facturas/:id — sólo si está 'pendiente')
CREATE OR REPLACE FUNCTION actualizar_factura(
  p_id                integer,
  p_cliente_id        integer,
  p_items             jsonb,
  p_descuento_general numeric DEFAULT 0,
  p_observaciones     text    DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur facturas;
  v_tot record;
  v_fac facturas;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_cur FROM facturas WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura no encontrada';
  END IF;
  IF v_cur.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'Solo se pueden editar facturas en estado pendiente.';
  END IF;

  SELECT * INTO v_tot FROM crm_calc_totales(p_items, p_descuento_general);

  UPDATE facturas SET
    cliente_id        = p_cliente_id,
    descuento_general = COALESCE(p_descuento_general, 0),
    subtotal          = v_tot.subtotal,
    descuento_monto   = v_tot.descuento_monto,
    neto_gravado      = v_tot.neto_gravado,
    iva_monto         = v_tot.iva_monto,
    total             = v_tot.total,
    observaciones     = p_observaciones,
    updated_at        = NOW()
  WHERE id = p_id
  RETURNING * INTO v_fac;

  DELETE FROM factura_items WHERE factura_id = p_id;
  PERFORM crm_insert_factura_items(p_id, p_items);
  RETURN v_fac;
END;
$$;

-- factura_anular  (port de PATCH /api/facturas/:id/anular)
--   Atómico: anula la factura y libera el remito vinculado (el backend lo hacía en 2 queries).
CREATE OR REPLACE FUNCTION factura_anular(p_id integer)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_fac facturas;
BEGIN
  UPDATE facturas SET estado = 'anulada', updated_at = NOW()
  WHERE id = p_id AND estado = 'pendiente'
  RETURNING * INTO v_fac;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura no encontrada o no se puede anular.';
  END IF;

  UPDATE remitos SET estado = 'pendiente', factura_id = NULL, updated_at = NOW()
  WHERE factura_id = p_id;

  RETURN v_fac;
END;
$$;

-- ── Permisos ───────────────────────────────────────────────────
-- El helper también se revoca de anon explícitamente (default privileges no basta, ver 0004/0010).
REVOKE ALL ON FUNCTION crm_insert_factura_items(integer, jsonb)                                 FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_factura(integer, jsonb, varchar, numeric, integer, integer, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_factura(integer, integer, jsonb, numeric, text)               FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION factura_anular(integer)                                                  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_factura(integer, jsonb, varchar, numeric, integer, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_factura(integer, integer, jsonb, numeric, text)              TO authenticated;
GRANT EXECUTE ON FUNCTION factura_anular(integer)                                                 TO authenticated;
