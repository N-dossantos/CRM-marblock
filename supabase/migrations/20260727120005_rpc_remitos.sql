-- =============================================================
-- CRM Ventas — Supabase migration 0005: RPC — remitos
-- Port of backend/src/routes/remitos.js (POST / PUT / PATCH anular).
-- Remitos have NO totals on the header; each item still stores its own subtotal.
-- Follows the presupuestos reference pattern: SECURITY DEFINER + pinned search_path,
-- EXECUTE revoked from PUBLIC+anon and granted to authenticated only.
-- =============================================================

-- Helper: inserta los ítems de un remito desde jsonb (precio_unitario opcional, default 0).
CREATE OR REPLACE FUNCTION crm_insert_remito_items(
  p_remito_id integer,
  p_items     jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO remito_items
    (remito_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden)
  SELECT
    p_remito_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    COALESCE((e.item->>'precio_unitario')::numeric, 0),
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * COALESCE((e.item->>'precio_unitario')::numeric, 0)
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

-- crear_remito  (port de POST /api/remitos)
CREATE OR REPLACE FUNCTION crear_remito(
  p_cliente_id     integer,
  p_items          jsonb,
  p_observaciones  text    DEFAULT NULL,
  p_presupuesto_id integer DEFAULT NULL
)
RETURNS remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num record;
  v_rem remitos;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_num FROM siguiente_numero('remito');

  INSERT INTO remitos
    (numero, punto_venta, numero_comp, fecha, cliente_id, presupuesto_id, estado, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, CURRENT_DATE,
     p_cliente_id, p_presupuesto_id, 'pendiente', p_observaciones)
  RETURNING * INTO v_rem;

  PERFORM crm_insert_remito_items(v_rem.id, p_items);

  IF p_presupuesto_id IS NOT NULL THEN
    UPDATE presupuestos SET estado = 'convertido', updated_at = NOW() WHERE id = p_presupuesto_id;
  END IF;

  RETURN v_rem;
END;
$$;

-- actualizar_remito  (port de PUT /api/remitos/:id — sólo si está 'pendiente')
CREATE OR REPLACE FUNCTION actualizar_remito(
  p_id            integer,
  p_cliente_id    integer,
  p_items         jsonb,
  p_observaciones text DEFAULT NULL
)
RETURNS remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur remitos;
  v_rem remitos;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_cur FROM remitos WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remito no encontrado';
  END IF;
  IF v_cur.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'Solo se pueden editar remitos en estado pendiente.';
  END IF;

  UPDATE remitos SET
    cliente_id    = p_cliente_id,
    observaciones = p_observaciones,
    updated_at    = NOW()
  WHERE id = p_id
  RETURNING * INTO v_rem;

  DELETE FROM remito_items WHERE remito_id = p_id;
  PERFORM crm_insert_remito_items(p_id, p_items);
  RETURN v_rem;
END;
$$;

-- remito_anular  (port de PATCH /api/remitos/:id/anular)
CREATE OR REPLACE FUNCTION remito_anular(p_id integer)
RETURNS remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_rem remitos;
BEGIN
  UPDATE remitos SET estado = 'anulado', updated_at = NOW()
  WHERE id = p_id AND estado = 'pendiente'
  RETURNING * INTO v_rem;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remito no encontrado o no se puede anular.';
  END IF;
  RETURN v_rem;
END;
$$;

-- ── Permisos ───────────────────────────────────────────────────
-- El helper también se revoca de anon explícitamente (default privileges no basta, ver 0004/0010).
REVOKE ALL ON FUNCTION crm_insert_remito_items(integer, jsonb)          FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_remito(integer, jsonb, text, integer)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_remito(integer, integer, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION remito_anular(integer)                           FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_remito(integer, jsonb, text, integer)      TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_remito(integer, integer, jsonb, text) TO authenticated;
GRANT EXECUTE ON FUNCTION remito_anular(integer)                           TO authenticated;
