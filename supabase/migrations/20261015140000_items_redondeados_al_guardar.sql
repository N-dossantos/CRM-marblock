-- =============================================================
-- Ítems redondeados antes de calcular (PLAN_ARCA Fase 3)
--
-- factura_items guarda cantidad con 3 decimales y precio_unitario / descuento_item con 2, pero
-- crear_factura y actualizar_factura calculaban los totales con lo que llegaba del formulario, que
-- acepta más decimales. Con un precio de 333,335 el ítem quedaba guardado a 333,34 y la cabecera
-- calculada con 333,335: un centavo de diferencia que arca_comprobante_para_emitir (que recalcula
-- desde los ítems guardados) bloquea con razón, y que volver a guardar no corregía.
--
-- Ahora los ítems se redondean a la escala de sus columnas antes de calcular y de insertar: la
-- cabecera, el subtotal de cada renglón y lo que se informa a ARCA salen de los mismos números.
-- Presupuestos, remitos y compras tienen la misma diferencia latente; no se tocan acá porque no se
-- informan a ARCA (crear_nota / actualizar_nota lo van a usar en la Fase 4).
-- =============================================================

-- Redondeo de numeric(10,3) y numeric(14,2)/numeric(5,2) al asignar: el mismo que round().
CREATE FUNCTION crm_items_normalizados(p_items jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT COALESCE(jsonb_agg(e.item || jsonb_build_object(
           'cantidad',        round((e.item->>'cantidad')::numeric, 3),
           'precio_unitario', round((e.item->>'precio_unitario')::numeric, 2),
           'descuento_item',  round(COALESCE((e.item->>'descuento_item')::numeric, 0), 2))
         ORDER BY e.ord), '[]'::jsonb)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
$$;
REVOKE ALL ON FUNCTION crm_items_normalizados(jsonb) FROM PUBLIC, anon, authenticated;

-- Mismas firmas y cuerpos que 20261015130000, más el redondeo de los ítems.
-- 20261015130000
CREATE OR REPLACE FUNCTION crear_factura(
  p_cliente_id        integer,
  p_items             jsonb,
  p_tipo              varchar   DEFAULT 'A',
  p_descuento_general numeric   DEFAULT 0,
  p_remito_ids        integer[] DEFAULT NULL,
  p_presupuesto_id    integer   DEFAULT NULL,
  p_observaciones     text      DEFAULT NULL,
  p_percepciones      jsonb     DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_tot      jsonb;
  v_perc     jsonb;
  v_fac      facturas;
  v_iva_alic numeric;
  v_rems     integer[];
  v_cant     integer;
  v_primero  integer;
  v_malo     text;
  v_otra     integer;
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
  PERFORM crm_validar_letra_cliente(p_cliente_id, p_tipo);

  -- Los totales salen de los ítems tal como se guardan.
  p_items := crm_items_normalizados(p_items);

  -- Normaliza la lista: sin NULLs y sin repetidos (marcar dos veces el mismo remito
  -- en la grilla no puede contar doble).
  SELECT array_agg(DISTINCT x) INTO v_rems
  FROM unnest(COALESCE(p_remito_ids, ARRAY[]::integer[])) AS x
  WHERE x IS NOT NULL;
  v_rems := COALESCE(v_rems, ARRAY[]::integer[]);
  v_cant := array_length(v_rems, 1);

  IF v_cant > 0 THEN
    -- Un remito inexistente, de otro cliente, ya facturado/anulado o tomado por otro borrador
    -- invalida la factura entera.
    SELECT string_agg(t.detalle, '; ') INTO v_malo
    FROM (
      SELECT CASE
               WHEN r.id IS NULL             THEN 'remito id=' || e.rid || ' inexistente'
               WHEN r.cliente_id <> p_cliente_id THEN 'el remito ' || r.numero || ' es de otro cliente'
               WHEN r.estado <> 'pendiente'  THEN 'el remito ' || r.numero || ' no está pendiente (' || r.estado || ')'
               ELSE 'el remito ' || r.numero || ' ya está en otra factura sin emitir (id ' || r.factura_id || ')'
             END AS detalle
      FROM unnest(v_rems) AS e(rid)
      LEFT JOIN remitos r ON r.id = e.rid
      WHERE r.id IS NULL OR r.cliente_id <> p_cliente_id OR r.estado <> 'pendiente'
         OR r.factura_id IS NOT NULL
    ) t;

    IF v_malo IS NOT NULL THEN
      RAISE EXCEPTION 'No se puede facturar: %.', v_malo;
    END IF;

    SELECT r.id INTO v_primero
    FROM remitos r WHERE r.id = ANY(v_rems)
    ORDER BY r.numero LIMIT 1;
  END IF;

  IF p_presupuesto_id IS NOT NULL THEN
    SELECT f.id INTO v_otra FROM facturas f
    WHERE f.presupuesto_id = p_presupuesto_id
      AND f.estado_fiscal IN ('borrador','en_proceso','resultado_incierto','rechazado')
    LIMIT 1;
    IF v_otra IS NOT NULL THEN
      RAISE EXCEPTION 'El presupuesto ya está en otra factura sin emitir (id %).', v_otra;
    END IF;
  END IF;

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  -- tasa legacy de cabecera: única alícuota → su %; varias → tasa efectiva (iva/neto).
  v_iva_alic := CASE
    WHEN jsonb_array_length(v_tot->'detalle') = 1 THEN (v_tot->'detalle'->0->>'porcentaje')::numeric
    WHEN (v_tot->>'neto_gravado')::numeric > 0
      THEN round((v_tot->>'iva_monto')::numeric / (v_tot->>'neto_gravado')::numeric * 100, 2)
    ELSE 21
  END;

  -- Percepciones sobre el neto gravado ya descontado. Una factura con percepciones se guarda, pero
  -- arca_comprobante_para_emitir no la deja emitir todavía (§3.3).
  v_perc := crm_calc_percepciones(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  INSERT INTO facturas
    (tipo, fecha, cliente_id, remito_id, presupuesto_id,
     descuento_general, subtotal, descuento_monto, neto_gravado, iva_alicuota, iva_monto,
     percepciones_monto, total, estado, estado_fiscal, observaciones)
  VALUES
    (p_tipo, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, p_cliente_id,
     v_primero, p_presupuesto_id, COALESCE(p_descuento_general, 0),
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric, (v_tot->>'neto_gravado')::numeric,
     v_iva_alic, (v_tot->>'iva_monto')::numeric,
     (v_perc->>'total')::numeric,
     round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
     'pendiente', 'borrador', p_observaciones)
  RETURNING * INTO v_fac;

  PERFORM crm_insert_factura_items(v_fac.id, p_items);
  PERFORM crm_insert_percepciones(v_fac.id, NULL, v_perc->'detalle');

  -- Sólo el vínculo: el remito pasa a `facturado` cuando la factura tiene CAE.
  IF v_cant > 0 THEN
    UPDATE remitos SET factura_id = v_fac.id, updated_at = NOW()
    WHERE id = ANY(v_rems);
  END IF;

  RETURN v_fac;
END;
$$;

-- 20261015130000
CREATE OR REPLACE FUNCTION actualizar_factura(
  p_id integer, p_cliente_id integer, p_items jsonb, p_descuento_general numeric DEFAULT 0,
  p_observaciones text DEFAULT NULL, p_percepciones jsonb DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur      facturas;
  v_tot      jsonb;
  v_perc     jsonb;
  v_fac      facturas;
  v_iva_alic numeric;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_cur FROM facturas WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura no encontrada';
  END IF;
  IF v_cur.estado_fiscal NOT IN ('borrador','rechazado') THEN
    RAISE EXCEPTION '%', CASE v_cur.estado_fiscal
      WHEN 'autorizado'         THEN 'La factura ya tiene CAE: no se puede modificar. Corregila con una Nota de Crédito o Débito.'
      WHEN 'en_proceso'         THEN 'La factura se está emitiendo: no se puede modificar.'
      WHEN 'resultado_incierto' THEN 'La factura tiene un resultado incierto en ARCA: consultá el estado antes de modificarla.'
      ELSE                           'Es un comprobante histórico: no se puede modificar.'
    END;
  END IF;
  PERFORM crm_validar_letra_cliente(p_cliente_id, v_cur.tipo);

  -- Los totales salen de los ítems tal como se guardan.
  p_items := crm_items_normalizados(p_items);

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  v_iva_alic := CASE
    WHEN jsonb_array_length(v_tot->'detalle') = 1 THEN (v_tot->'detalle'->0->>'porcentaje')::numeric
    WHEN (v_tot->>'neto_gravado')::numeric > 0
      THEN round((v_tot->>'iva_monto')::numeric / (v_tot->>'neto_gravado')::numeric * 100, 2)
    ELSE 21
  END;

  -- NULL ⇒ se recalculan como vacías y se borra el detalle: editar una factura sin mandar
  -- percepciones las quita, igual que pasa con los ítems (DELETE + re-insert).
  v_perc := crm_calc_percepciones(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  UPDATE facturas SET
    cliente_id         = p_cliente_id,
    descuento_general  = COALESCE(p_descuento_general, 0),
    subtotal           = (v_tot->>'subtotal')::numeric,
    descuento_monto    = (v_tot->>'descuento_monto')::numeric,
    neto_gravado       = (v_tot->>'neto_gravado')::numeric,
    iva_alicuota       = v_iva_alic,
    iva_monto          = (v_tot->>'iva_monto')::numeric,
    percepciones_monto = (v_perc->>'total')::numeric,
    total              = round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
    observaciones      = p_observaciones,
    estado_fiscal      = 'borrador',
    updated_at         = NOW()
  WHERE id = p_id
  RETURNING * INTO v_fac;

  DELETE FROM factura_items WHERE factura_id = p_id;
  PERFORM crm_insert_factura_items(p_id, p_items);

  DELETE FROM percepciones WHERE factura_id = p_id;
  PERFORM crm_insert_percepciones(p_id, NULL, v_perc->'detalle');

  RETURN v_fac;
END;
$$;
