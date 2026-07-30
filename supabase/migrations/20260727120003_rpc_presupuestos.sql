-- =============================================================
-- CRM Ventas — Supabase migration 0003: RPC — totales + presupuestos
-- PostgREST cannot span a multi-statement transaction, so every atomic comprobante
-- operation (numbering + header + N items + estado) becomes a SECURITY DEFINER function
-- called from the browser via supabase.rpc(...). Totals are ALWAYS recomputed here — a
-- browser client must never be trusted to send its own total.
--
-- This file is the reference pattern (create / update / set-estado). The equivalent RPCs
-- for remitos, facturas, notas and recibos follow the same shape and land in later
-- migrations, each verified against the live DB as it is created.
-- =============================================================

-- ──────────────────────────────────────────────────────────────
-- Helper: totales de un comprobante  (port de utils/calculos.js)
--   subtotal = Σ(cantidad · precio · (1 - dto_item/100)),  IVA fijo 21%.
--   Se suma sin redondear y se redondea cada total al final (igual que calcularTotales).
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm_calc_totales(
  p_items             jsonb,
  p_descuento_general numeric DEFAULT 0
)
RETURNS TABLE (
  subtotal        numeric,
  descuento_monto numeric,
  neto_gravado    numeric,
  iva_monto       numeric,
  total           numeric
)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_subtotal numeric := 0;
  v_desc     numeric := 0;
  v_neto     numeric := 0;
  v_iva      numeric := 0;
BEGIN
  SELECT COALESCE(SUM(
           (it->>'cantidad')::numeric
         * (it->>'precio_unitario')::numeric
         * (1 - COALESCE((it->>'descuento_item')::numeric, 0) / 100)
         ), 0)
    INTO v_subtotal
  FROM jsonb_array_elements(p_items) AS it;

  v_desc := v_subtotal * (COALESCE(p_descuento_general, 0) / 100);
  v_neto := v_subtotal - v_desc;
  v_iva  := v_neto * 0.21;

  subtotal        := round(v_subtotal, 2);
  descuento_monto := round(v_desc, 2);
  neto_gravado    := round(v_neto, 2);
  iva_monto       := round(v_iva, 2);
  total           := round(v_neto + v_iva, 2);
  RETURN NEXT;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- Helper interno: inserta los ítems de un presupuesto desde jsonb.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm_insert_presupuesto_items(
  p_presupuesto_id integer,
  p_items          jsonb
)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO presupuesto_items
    (presupuesto_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden)
  SELECT
    p_presupuesto_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer                       -- orden 0-based, igual que el loop original
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- crear_presupuesto  (port de POST /api/presupuestos)
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crear_presupuesto(
  p_cliente_id        integer,
  p_items             jsonb,
  p_descuento_general numeric DEFAULT 0,
  p_observaciones     text    DEFAULT NULL
)
RETURNS presupuestos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num  record;
  v_tot  record;
  v_pres presupuestos;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_tot FROM crm_calc_totales(p_items, p_descuento_general);
  SELECT * INTO v_num FROM siguiente_numero('presupuesto');

  INSERT INTO presupuestos
    (numero, punto_venta, numero_comp, fecha, fecha_vcto, cliente_id, descuento_general,
     subtotal, descuento_monto, neto_gravado, iva_monto, total, estado, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, CURRENT_DATE,
     CURRENT_DATE + INTERVAL '7 days', p_cliente_id, COALESCE(p_descuento_general, 0),
     v_tot.subtotal, v_tot.descuento_monto, v_tot.neto_gravado, v_tot.iva_monto, v_tot.total,
     'borrador', p_observaciones)
  RETURNING * INTO v_pres;

  PERFORM crm_insert_presupuesto_items(v_pres.id, p_items);
  RETURN v_pres;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- actualizar_presupuesto  (port de PUT /api/presupuestos/:id)
--   Reglas: no editable si está 'convertido'/'rechazado'; si venció y no se fuerza,
--   lanza 'PRESUPUESTO_VENCIDO' (el frontend lo detecta por ese texto exacto).
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION actualizar_presupuesto(
  p_id                integer,
  p_cliente_id        integer,
  p_items             jsonb,
  p_descuento_general numeric DEFAULT 0,
  p_observaciones     text    DEFAULT NULL,
  p_estado            varchar DEFAULT NULL,
  p_forzar_vencido    boolean DEFAULT false
)
RETURNS presupuestos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur  presupuestos;
  v_tot  record;
  v_pres presupuestos;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_cur FROM presupuestos WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Presupuesto no encontrado';
  END IF;
  IF v_cur.estado IN ('convertido', 'rechazado') THEN
    RAISE EXCEPTION 'No se puede editar un presupuesto convertido o rechazado.';
  END IF;
  IF v_cur.fecha_vcto < CURRENT_DATE AND NOT p_forzar_vencido THEN
    RAISE EXCEPTION 'PRESUPUESTO_VENCIDO';
  END IF;

  SELECT * INTO v_tot FROM crm_calc_totales(p_items, p_descuento_general);

  UPDATE presupuestos SET
    cliente_id        = p_cliente_id,
    descuento_general = COALESCE(p_descuento_general, 0),
    subtotal          = v_tot.subtotal,
    descuento_monto   = v_tot.descuento_monto,
    neto_gravado      = v_tot.neto_gravado,
    iva_monto         = v_tot.iva_monto,
    total             = v_tot.total,
    estado            = COALESCE(p_estado, estado),
    observaciones     = p_observaciones,
    updated_at        = NOW()
  WHERE id = p_id
  RETURNING * INTO v_pres;

  DELETE FROM presupuesto_items WHERE presupuesto_id = p_id;
  PERFORM crm_insert_presupuesto_items(p_id, p_items);
  RETURN v_pres;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- presupuesto_set_estado  (port de PATCH /api/presupuestos/:id/estado)
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION presupuesto_set_estado(
  p_id     integer,
  p_estado varchar
)
RETURNS presupuestos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_pres presupuestos;
BEGIN
  IF p_estado NOT IN ('borrador','enviado','aceptado','vencido','convertido','rechazado') THEN
    RAISE EXCEPTION 'Estado inválido.';
  END IF;

  UPDATE presupuestos SET estado = p_estado, updated_at = NOW()
  WHERE id = p_id
  RETURNING * INTO v_pres;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Presupuesto no encontrado';
  END IF;
  RETURN v_pres;
END;
$$;

-- ── Permisos: solo staff autenticado puede ejecutar las RPC ────
-- OJO: hay que revocar de `anon` explícitamente, no solo de PUBLIC. Supabase concede
-- EXECUTE sobre funciones nuevas de `public` directamente al rol `anon` (default privileges),
-- y `REVOKE ... FROM PUBLIC` NO quita esa concesión directa. La migración 0004 lo endurece a
-- nivel de esquema; este patrón debe copiarse tal cual en las RPC de remitos/facturas/notas/recibos.
REVOKE ALL ON FUNCTION crear_presupuesto(integer, jsonb, numeric, text)                                   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_presupuesto(integer, integer, jsonb, numeric, text, varchar, boolean)   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION presupuesto_set_estado(integer, varchar)                                            FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_presupuesto(integer, jsonb, numeric, text)                                 TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_presupuesto(integer, integer, jsonb, numeric, text, varchar, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION presupuesto_set_estado(integer, varchar)                                          TO authenticated;
