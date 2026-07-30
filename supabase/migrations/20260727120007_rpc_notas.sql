-- =============================================================
-- CRM Ventas — Supabase migration 0007: RPC — notas de crédito / débito
-- Port of backend/src/routes/notas.js (POST). Una nota SIEMPRE referencia una factura.
-- Numbering: NC -> contador 'nota_credito', ND -> 'nota_debito'. Descuento general fijo 0.
-- tipo_letra hereda la letra de la factura. Tras insertar, recalcula el estado de la factura
-- (una NC reduce el saldo -> puede pasar a 'parcial' o 'cobrada').
-- =============================================================

-- Helper: inserta los ítems de una nota desde jsonb.
CREATE OR REPLACE FUNCTION crm_insert_nota_items(
  p_nota_id integer,
  p_items   jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO nota_items
    (nota_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden)
  SELECT
    p_nota_id,
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

-- crear_nota  (port de POST /api/notas)
CREATE OR REPLACE FUNCTION crear_nota(
  p_factura_id    integer,
  p_tipo          varchar,
  p_items         jsonb,
  p_motivo        text DEFAULT NULL,
  p_observaciones text DEFAULT NULL
)
RETURNS notas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_fac      facturas;
  v_num      record;
  v_tot      record;
  v_nota     notas;
  v_contador text;
BEGIN
  IF p_factura_id IS NULL THEN
    RAISE EXCEPTION 'La factura de referencia es obligatoria.';
  END IF;
  IF p_tipo NOT IN ('NC','ND') THEN
    RAISE EXCEPTION 'Tipo inválido (NC o ND).';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_fac FROM facturas WHERE id = p_factura_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura no encontrada';
  END IF;
  IF v_fac.estado = 'anulada' THEN
    RAISE EXCEPTION 'No se puede crear nota sobre una factura anulada.';
  END IF;

  v_contador := CASE p_tipo WHEN 'NC' THEN 'nota_credito' ELSE 'nota_debito' END;

  SELECT * INTO v_tot FROM crm_calc_totales(p_items, 0);
  SELECT * INTO v_num FROM siguiente_numero(v_contador);

  INSERT INTO notas
    (numero, punto_venta, numero_comp, tipo, tipo_letra, fecha, factura_id, motivo,
     subtotal, descuento_monto, neto_gravado, iva_monto, total, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, p_tipo, v_fac.tipo, CURRENT_DATE,
     p_factura_id, p_motivo,
     v_tot.subtotal, v_tot.descuento_monto, v_tot.neto_gravado, v_tot.iva_monto, v_tot.total,
     p_observaciones)
  RETURNING * INTO v_nota;

  PERFORM crm_insert_nota_items(v_nota.id, p_items);
  PERFORM recalcular_estado_factura(p_factura_id);

  RETURN v_nota;
END;
$$;

-- ── Permisos ───────────────────────────────────────────────────
-- El helper también se revoca de anon explícitamente (default privileges no basta, ver 0004/0010).
REVOKE ALL ON FUNCTION crm_insert_nota_items(integer, jsonb)           FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_nota(integer, varchar, jsonb, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_nota(integer, varchar, jsonb, text, text) TO authenticated;
