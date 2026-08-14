-- =============================================================
-- CRM — Fase F / migración 0401: RPC de Ventas con IVA multi-alícuota  (WS3)
-- system_plan_fase_f_integracion_ventas.md §4.1.
-- Re-crea los helpers de ítems y las RPC de escritura de Ventas para:
--   * persistir `alicuota_iva_id` por ítem (si viene vacío ⇒ fila 21%);
--   * calcular los totales con `crm_calc_totales_multi_alicuota` (Compras 0104) en vez del
--     `crm_calc_totales` de 21% fijo.
-- FIRMAS IDÉNTICAS a las originales (0003/0005/0006/0007) → el frontend actual sigue andando sin
-- cambios (manda ítems sin alícuota ⇒ 21%, mismo resultado que antes). Sólo cambia el cuerpo.
-- La cabecera guarda los agregados; `facturas.iva_alicuota` queda legacy (tasa única cuando hay una
-- sola alícuota; tasa efectiva si hay varias). El desglose por alícuota se deriva de los ítems.
-- SECURITY DEFINER, search_path fijado; grants preservados por CREATE OR REPLACE.
-- =============================================================

-- Expresión reutilizada: alícuota del ítem, resolviendo vacío/NULL a la fila de 21%.
-- (Se inserta el id concreto para que reads/PDF agrupen sin lógica de fallback.)

-- ── Helpers de ítems (agregan alicuota_iva_id) ────────────────────
CREATE OR REPLACE FUNCTION crm_insert_presupuesto_items(p_presupuesto_id integer, p_items jsonb)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO presupuesto_items
    (presupuesto_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, alicuota_iva_id)
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
    (e.ord - 1)::integer,
    COALESCE(NULLIF(e.item->>'alicuota_iva_id', '')::int, (SELECT id FROM alicuotas_iva WHERE porcentaje = 21))
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_factura_items(p_factura_id integer, p_items jsonb)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO factura_items
    (factura_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, alicuota_iva_id)
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
    (e.ord - 1)::integer,
    COALESCE(NULLIF(e.item->>'alicuota_iva_id', '')::int, (SELECT id FROM alicuotas_iva WHERE porcentaje = 21))
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_nota_items(p_nota_id integer, p_items jsonb)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO nota_items
    (nota_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, alicuota_iva_id)
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
    (e.ord - 1)::integer,
    COALESCE(NULLIF(e.item->>'alicuota_iva_id', '')::int, (SELECT id FROM alicuotas_iva WHERE porcentaje = 21))
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_remito_items(p_remito_id integer, p_items jsonb)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO remito_items
    (remito_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, alicuota_iva_id)
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
    (e.ord - 1)::integer,
    COALESCE(NULLIF(e.item->>'alicuota_iva_id', '')::int, (SELECT id FROM alicuotas_iva WHERE porcentaje = 21))
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

-- ── crear_presupuesto (multi-alícuota) ────────────────────────────
CREATE OR REPLACE FUNCTION crear_presupuesto(
  p_cliente_id integer, p_items jsonb, p_descuento_general numeric DEFAULT 0, p_observaciones text DEFAULT NULL
)
RETURNS presupuestos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num  record;
  v_tot  jsonb;
  v_pres presupuestos;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  SELECT * INTO v_num FROM siguiente_numero('presupuesto');

  INSERT INTO presupuestos
    (numero, punto_venta, numero_comp, fecha, fecha_vcto, cliente_id, descuento_general,
     subtotal, descuento_monto, neto_gravado, iva_monto, total, estado, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, CURRENT_DATE,
     CURRENT_DATE + INTERVAL '7 days', p_cliente_id, COALESCE(p_descuento_general, 0),
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric, (v_tot->>'neto_gravado')::numeric,
     (v_tot->>'iva_monto')::numeric, (v_tot->>'total')::numeric, 'borrador', p_observaciones)
  RETURNING * INTO v_pres;

  PERFORM crm_insert_presupuesto_items(v_pres.id, p_items);
  RETURN v_pres;
END;
$$;

-- ── actualizar_presupuesto (multi-alícuota) ───────────────────────
CREATE OR REPLACE FUNCTION actualizar_presupuesto(
  p_id integer, p_cliente_id integer, p_items jsonb, p_descuento_general numeric DEFAULT 0,
  p_observaciones text DEFAULT NULL, p_estado varchar DEFAULT NULL, p_forzar_vencido boolean DEFAULT false
)
RETURNS presupuestos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur  presupuestos;
  v_tot  jsonb;
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

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);

  UPDATE presupuestos SET
    cliente_id        = p_cliente_id,
    descuento_general = COALESCE(p_descuento_general, 0),
    subtotal          = (v_tot->>'subtotal')::numeric,
    descuento_monto   = (v_tot->>'descuento_monto')::numeric,
    neto_gravado      = (v_tot->>'neto_gravado')::numeric,
    iva_monto         = (v_tot->>'iva_monto')::numeric,
    total             = (v_tot->>'total')::numeric,
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

-- ── crear_factura (multi-alícuota) ────────────────────────────────
CREATE OR REPLACE FUNCTION crear_factura(
  p_cliente_id integer, p_items jsonb, p_tipo varchar DEFAULT 'A', p_descuento_general numeric DEFAULT 0,
  p_remito_id integer DEFAULT NULL, p_presupuesto_id integer DEFAULT NULL, p_observaciones text DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num      record;
  v_tot      jsonb;
  v_fac      facturas;
  v_contador text;
  v_iva_alic numeric;
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

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  -- tasa legacy de cabecera: única alícuota → su %; varias → tasa efectiva (iva/neto).
  v_iva_alic := CASE
    WHEN jsonb_array_length(v_tot->'detalle') = 1 THEN (v_tot->'detalle'->0->>'porcentaje')::numeric
    WHEN (v_tot->>'neto_gravado')::numeric > 0
      THEN round((v_tot->>'iva_monto')::numeric / (v_tot->>'neto_gravado')::numeric * 100, 2)
    ELSE 21
  END;

  SELECT * INTO v_num FROM siguiente_numero(v_contador);

  INSERT INTO facturas
    (numero, punto_venta, numero_comp, tipo, fecha, cliente_id, remito_id, presupuesto_id,
     descuento_general, subtotal, descuento_monto, neto_gravado, iva_alicuota, iva_monto, total,
     estado, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, p_tipo, CURRENT_DATE, p_cliente_id,
     p_remito_id, p_presupuesto_id, COALESCE(p_descuento_general, 0),
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric, (v_tot->>'neto_gravado')::numeric,
     v_iva_alic, (v_tot->>'iva_monto')::numeric, (v_tot->>'total')::numeric,
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

-- ── actualizar_factura (multi-alícuota) ───────────────────────────
CREATE OR REPLACE FUNCTION actualizar_factura(
  p_id integer, p_cliente_id integer, p_items jsonb, p_descuento_general numeric DEFAULT 0,
  p_observaciones text DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur      facturas;
  v_tot      jsonb;
  v_fac      facturas;
  v_iva_alic numeric;
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

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  v_iva_alic := CASE
    WHEN jsonb_array_length(v_tot->'detalle') = 1 THEN (v_tot->'detalle'->0->>'porcentaje')::numeric
    WHEN (v_tot->>'neto_gravado')::numeric > 0
      THEN round((v_tot->>'iva_monto')::numeric / (v_tot->>'neto_gravado')::numeric * 100, 2)
    ELSE 21
  END;

  UPDATE facturas SET
    cliente_id        = p_cliente_id,
    descuento_general = COALESCE(p_descuento_general, 0),
    subtotal          = (v_tot->>'subtotal')::numeric,
    descuento_monto   = (v_tot->>'descuento_monto')::numeric,
    neto_gravado      = (v_tot->>'neto_gravado')::numeric,
    iva_alicuota      = v_iva_alic,
    iva_monto         = (v_tot->>'iva_monto')::numeric,
    total             = (v_tot->>'total')::numeric,
    observaciones     = p_observaciones,
    updated_at        = NOW()
  WHERE id = p_id
  RETURNING * INTO v_fac;

  DELETE FROM factura_items WHERE factura_id = p_id;
  PERFORM crm_insert_factura_items(p_id, p_items);
  RETURN v_fac;
END;
$$;

-- ── crear_nota (multi-alícuota) ───────────────────────────────────
CREATE OR REPLACE FUNCTION crear_nota(
  p_factura_id integer, p_tipo varchar, p_items jsonb, p_motivo text DEFAULT NULL, p_observaciones text DEFAULT NULL
)
RETURNS notas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_fac      facturas;
  v_num      record;
  v_tot      jsonb;
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

  v_tot := crm_calc_totales_multi_alicuota(p_items, 0);
  SELECT * INTO v_num FROM siguiente_numero(v_contador);

  INSERT INTO notas
    (numero, punto_venta, numero_comp, tipo, tipo_letra, fecha, factura_id, motivo,
     subtotal, descuento_monto, neto_gravado, iva_monto, total, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, p_tipo, v_fac.tipo, CURRENT_DATE,
     p_factura_id, p_motivo,
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric, (v_tot->>'neto_gravado')::numeric,
     (v_tot->>'iva_monto')::numeric, (v_tot->>'total')::numeric,
     p_observaciones)
  RETURNING * INTO v_nota;

  PERFORM crm_insert_nota_items(v_nota.id, p_items);
  PERFORM recalcular_estado_factura(p_factura_id);

  RETURN v_nota;
END;
$$;

-- ── Permisos (re-aplicados por regla del proyecto; CREATE OR REPLACE los preserva) ──
REVOKE ALL ON FUNCTION crm_insert_presupuesto_items(integer, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_factura_items(integer, jsonb)     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_nota_items(integer, jsonb)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_remito_items(integer, jsonb)      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_presupuesto(integer, jsonb, numeric, text)                                 FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_presupuesto(integer, integer, jsonb, numeric, text, varchar, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_factura(integer, jsonb, varchar, numeric, integer, integer, text)          FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_factura(integer, integer, jsonb, numeric, text)                       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_nota(integer, varchar, jsonb, text, text)                                  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_presupuesto(integer, jsonb, numeric, text)                                 TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_presupuesto(integer, integer, jsonb, numeric, text, varchar, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION crear_factura(integer, jsonb, varchar, numeric, integer, integer, text)          TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_factura(integer, integer, jsonb, numeric, text)                       TO authenticated;
GRANT EXECUTE ON FUNCTION crear_nota(integer, varchar, jsonb, text, text)                                   TO authenticated;
