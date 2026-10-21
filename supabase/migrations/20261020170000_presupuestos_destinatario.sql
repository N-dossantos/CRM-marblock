-- Presupuestos a nombre de cualquier destinatario, con cliente opcional.
-- La leyenda/contacto sigue en observaciones y sale en el PDF.
ALTER TABLE presupuestos
  ALTER COLUMN cliente_id DROP NOT NULL,
  ADD COLUMN destinatario text,
  ADD CONSTRAINT chk_pres_destinatario CHECK (
    cliente_id IS NOT NULL OR NULLIF(btrim(destinatario), '') IS NOT NULL
  );

-- Se reemplazan las firmas anteriores: no quedan sobrecargas obsoletas en PostgREST.
DROP FUNCTION crear_presupuesto(integer, jsonb, numeric, text);
DROP FUNCTION actualizar_presupuesto(integer, integer, jsonb, numeric, text, varchar, boolean);

CREATE OR REPLACE FUNCTION crear_presupuesto(
  p_cliente_id integer, p_items jsonb, p_descuento_general numeric DEFAULT 0, p_observaciones text DEFAULT NULL,
  p_destinatario text DEFAULT NULL
)
RETURNS presupuestos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num  record;
  v_tot  jsonb;
  v_pres presupuestos;
BEGIN
  IF p_cliente_id IS NULL AND NULLIF(btrim(p_destinatario), '') IS NULL THEN
    RAISE EXCEPTION 'Ingrese el nombre del destinatario.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  SELECT * INTO v_num FROM siguiente_numero('presupuesto');

  INSERT INTO presupuestos
    (numero, punto_venta, numero_comp, fecha, fecha_vcto, cliente_id, destinatario, descuento_general,
     subtotal, descuento_monto, neto_gravado, iva_monto, total, estado, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, CURRENT_DATE,
     CURRENT_DATE + INTERVAL '7 days', p_cliente_id, NULLIF(btrim(p_destinatario), ''), COALESCE(p_descuento_general, 0),
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
  p_observaciones text DEFAULT NULL, p_estado varchar DEFAULT NULL, p_forzar_vencido boolean DEFAULT false,
  p_destinatario text DEFAULT NULL
)
RETURNS presupuestos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur  presupuestos;
  v_tot  jsonb;
  v_pres presupuestos;
BEGIN
  IF p_cliente_id IS NULL AND NULLIF(btrim(p_destinatario), '') IS NULL THEN
    RAISE EXCEPTION 'Ingrese el nombre del destinatario.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_cur FROM presupuestos WHERE id = p_id FOR UPDATE;
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
    destinatario      = NULLIF(btrim(p_destinatario), ''),
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

CREATE OR REPLACE FUNCTION presupuestos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE presupuestos SET estado = 'vencido', updated_at = NOW()
  WHERE estado IN ('borrador','enviado') AND fecha_vcto < CURRENT_DATE;

  RETURN QUERY
  SELECT to_jsonb(t) FROM (
    SELECT p.*,
      COALESCE(p.destinatario, c.razon_social) AS razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase, c.direccion, c.email, c.telefono,
      json_agg(json_build_object(
        'id', pi.id, 'producto_id', pi.producto_id, 'codigo', pr.codigo, 'descripcion', pi.descripcion,
        'cantidad', pi.cantidad, 'precio_unitario', pi.precio_unitario,
        'descuento_item', pi.descuento_item, 'subtotal', pi.subtotal, 'orden', pi.orden,
        'alicuota_iva_id', pi.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', pi.pallets, 'unidades_por_pallet', pi.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
      ) ORDER BY pi.orden) FILTER (WHERE pi.id IS NOT NULL) AS items
    FROM presupuestos p
    LEFT JOIN clientes c ON c.id = p.cliente_id
    LEFT JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN presupuesto_items pi ON pi.presupuesto_id = p.id
    LEFT JOIN productos pr ON pr.id = pi.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = pi.alicuota_iva_id
    WHERE (p_id IS NULL OR p.id = p_id)
      AND (p_estado IS NULL OR p.estado = p_estado)
      AND (p_q IS NULL OR p.numero ILIKE '%'||p_q||'%' OR COALESCE(p.destinatario, c.razon_social) ILIKE '%'||p_q||'%'
        OR c.razon_social ILIKE '%'||p_q||'%' OR p.observaciones ILIKE '%'||p_q||'%')
    GROUP BY p.id, c.id, ci.id
    ORDER BY p.fecha DESC, p.numero DESC
  ) t;
END;
$$;

-- Ítems: ON DELETE CASCADE. Facturas/remitos: ON DELETE SET NULL;
-- borrar el presupuesto no elimina los comprobantes que se hicieron a partir de él.
CREATE FUNCTION eliminar_presupuesto(p_id integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  DELETE FROM presupuestos WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Presupuesto no encontrado';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION crear_presupuesto(integer, jsonb, numeric, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_presupuesto(integer, integer, jsonb, numeric, text, varchar, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION eliminar_presupuesto(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_presupuesto(integer, jsonb, numeric, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_presupuesto(integer, integer, jsonb, numeric, text, varchar, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION eliminar_presupuesto(integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
