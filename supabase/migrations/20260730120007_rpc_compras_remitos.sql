-- =============================================================
-- CRM — Fase A / migración 0107: RPC remitos de compra  §4.5/§4.11
-- Remito de recepción de mercadería del proveedor. Numeración del proveedor (parámetros).
-- Sin totales de cabecera (la tabla no los tiene); los ítems guardan subtotal informativo.
-- =============================================================

CREATE OR REPLACE FUNCTION crm_insert_remito_compra_items(
  p_remito_compra_id integer, p_items jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO remito_compra_items
    (remito_compra_id, material_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden)
  SELECT
    p_remito_compra_id,
    NULLIF(e.item->>'material_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    COALESCE((e.item->>'precio_unitario')::numeric, 0),
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round(COALESCE((e.item->>'cantidad')::numeric, 0)
        * COALESCE((e.item->>'precio_unitario')::numeric, 0)
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crear_remito_compra(
  p_proveedor_id  integer,
  p_punto_venta   text,
  p_numero_comp   integer,
  p_fecha         date,
  p_items         jsonb,
  p_observaciones text DEFAULT NULL
)
RETURNS remitos_compra
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_numero varchar;
  v_rc     remitos_compra;
BEGIN
  IF p_proveedor_id IS NULL THEN
    RAISE EXCEPTION 'El proveedor es obligatorio.';
  END IF;
  IF p_punto_venta IS NULL OR p_numero_comp IS NULL THEN
    RAISE EXCEPTION 'Punto de venta y número del remito son obligatorios.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  v_numero := lpad(p_punto_venta, 5, '0') || '-' || lpad(p_numero_comp::text, 8, '0');

  INSERT INTO remitos_compra
    (proveedor_id, punto_venta, numero_comp, numero, fecha, estado, observaciones)
  VALUES
    (p_proveedor_id, lpad(p_punto_venta, 5, '0'), p_numero_comp, v_numero, p_fecha, 'pendiente', p_observaciones)
  RETURNING * INTO v_rc;

  PERFORM crm_insert_remito_compra_items(v_rc.id, p_items);
  RETURN v_rc;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Ya existe un remito del proveedor con ese punto de venta y número (%).', v_numero;
END;
$$;

CREATE OR REPLACE FUNCTION actualizar_remito_compra(
  p_id            integer,
  p_proveedor_id  integer,
  p_punto_venta   text,
  p_numero_comp   integer,
  p_fecha         date,
  p_items         jsonb,
  p_observaciones text DEFAULT NULL
)
RETURNS remitos_compra
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur    remitos_compra;
  v_numero varchar;
  v_rc     remitos_compra;
BEGIN
  SELECT * INTO v_cur FROM remitos_compra WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remito de compra no encontrado';
  END IF;
  IF v_cur.estado IN ('facturado','anulado') THEN
    RAISE EXCEPTION 'No se puede editar un remito de compra facturado o anulado.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  v_numero := lpad(p_punto_venta, 5, '0') || '-' || lpad(p_numero_comp::text, 8, '0');

  UPDATE remitos_compra SET
    proveedor_id  = p_proveedor_id,
    punto_venta   = lpad(p_punto_venta, 5, '0'),
    numero_comp   = p_numero_comp,
    numero        = v_numero,
    fecha         = p_fecha,
    observaciones = p_observaciones,
    updated_at    = NOW()
  WHERE id = p_id
  RETURNING * INTO v_rc;

  DELETE FROM remito_compra_items WHERE remito_compra_id = p_id;
  PERFORM crm_insert_remito_compra_items(p_id, p_items);
  RETURN v_rc;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Ya existe un remito del proveedor con ese punto de venta y número (%).', v_numero;
END;
$$;

CREATE OR REPLACE FUNCTION remito_compra_anular(p_id integer)
RETURNS remitos_compra
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_rc remitos_compra;
BEGIN
  UPDATE remitos_compra SET estado = 'anulado', updated_at = NOW()
  WHERE id = p_id
  RETURNING * INTO v_rc;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remito de compra no encontrado';
  END IF;
  RETURN v_rc;
END;
$$;

-- ── Permisos ──────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION crm_insert_remito_compra_items(integer, jsonb)                    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_remito_compra(integer, text, integer, date, jsonb, text)    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_remito_compra(integer, integer, text, integer, date, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION remito_compra_anular(integer)                                     FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_remito_compra(integer, text, integer, date, jsonb, text)  TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_remito_compra(integer, integer, text, integer, date, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION remito_compra_anular(integer)                                   TO authenticated;
