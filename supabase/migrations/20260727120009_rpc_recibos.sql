-- =============================================================
-- CRM Ventas — Supabase migration 0009: RPC — recibos de cobro
-- Port of backend/src/routes/recibos.js (POST). Un recibo:
--   * combina N medios de pago (efectivo/transferencia/cheque/echeq) -> recibo_medios,
--   * imputa a N facturas del mismo cliente (no anuladas)            -> recibo_facturas,
--   * registra cada cheque/echeq en la cartera `cheques` (en_cartera),
--   * recalcula el estado de cada factura imputada.
-- El total lo calcula el servidor sumando los medios (anti-tamper).
-- =============================================================

CREATE OR REPLACE FUNCTION crear_recibo(
  p_cliente_id    integer,
  p_medios        jsonb,
  p_factura_ids   jsonb DEFAULT '[]'::jsonb,
  p_observaciones text  DEFAULT NULL
)
RETURNS recibos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num    record;
  v_recibo recibos;
  v_total  numeric;
  v_bad    text;
  v_fid    integer;
  v_m      jsonb;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_medios IS NULL OR jsonb_array_length(p_medios) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un medio de pago.';
  END IF;

  -- Total = Σ medios (autoritativo). Debe ser > 0.
  SELECT COALESCE(SUM((m->>'monto')::numeric), 0) INTO v_total
  FROM jsonb_array_elements(p_medios) AS m;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'El total debe ser mayor a cero.';
  END IF;

  -- Validación de cada medio: tipo permitido y monto > 0.
  SELECT (m->>'tipo') INTO v_bad
  FROM jsonb_array_elements(p_medios) AS m
  WHERE (m->>'tipo') NOT IN ('efectivo','transferencia','cheque','echeq')
  LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Medio de pago inválido: %', v_bad;
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_medios) AS m
    WHERE COALESCE((m->>'monto')::numeric, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'El monto de cada medio debe ser mayor a cero.';
  END IF;

  -- Cabecera
  SELECT * INTO v_num FROM siguiente_numero('recibo');
  INSERT INTO recibos (numero, punto_venta, numero_comp, fecha, cliente_id, total, observaciones)
  VALUES (v_num.numero_formateado, v_num.punto_venta, v_num.numero, CURRENT_DATE,
          p_cliente_id, v_total, p_observaciones)
  RETURNING * INTO v_recibo;

  -- Imputación de facturas (cada una debe ser del cliente y no estar anulada)
  FOR v_fid IN SELECT value::integer FROM jsonb_array_elements_text(p_factura_ids) LOOP
    PERFORM 1 FROM facturas
      WHERE id = v_fid AND cliente_id = p_cliente_id AND estado <> 'anulada';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Factura % inválida.', v_fid;
    END IF;
    INSERT INTO recibo_facturas (recibo_id, factura_id) VALUES (v_recibo.id, v_fid);
  END LOOP;

  -- Medios de pago (+ alta en cartera de cheques/echeqs)
  FOR v_m IN SELECT value FROM jsonb_array_elements(p_medios) LOOP
    INSERT INTO recibo_medios
      (recibo_id, tipo, detalle, numero_cheque, banco, titular, cuit_titular,
       fecha_emision, fecha_vcto, monto)
    VALUES
      (v_recibo.id, v_m->>'tipo', v_m->>'detalle', v_m->>'numero_cheque', v_m->>'banco',
       v_m->>'titular', v_m->>'cuit_titular',
       NULLIF(v_m->>'fecha_emision','')::date, NULLIF(v_m->>'fecha_vcto','')::date,
       (v_m->>'monto')::numeric);

    IF v_m->>'tipo' IN ('cheque','echeq') AND NULLIF(v_m->>'numero_cheque','') IS NOT NULL THEN
      INSERT INTO cheques
        (numero, tipo, banco, titular, cuit_titular, fecha_emision, fecha_vcto, monto, cliente_id, estado)
      VALUES
        (v_m->>'numero_cheque',
         CASE WHEN v_m->>'tipo' = 'cheque' THEN 'fisico' ELSE 'echeq' END,
         v_m->>'banco', v_m->>'titular', v_m->>'cuit_titular',
         NULLIF(v_m->>'fecha_emision','')::date, NULLIF(v_m->>'fecha_vcto','')::date,
         (v_m->>'monto')::numeric, p_cliente_id, 'en_cartera')
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  -- Recalcular estado de cada factura imputada
  FOR v_fid IN SELECT value::integer FROM jsonb_array_elements_text(p_factura_ids) LOOP
    PERFORM recalcular_estado_factura(v_fid);
  END LOOP;

  RETURN v_recibo;
END;
$$;

-- ── Permisos ───────────────────────────────────────────────────
REVOKE ALL ON FUNCTION crear_recibo(integer, jsonb, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_recibo(integer, jsonb, jsonb, text) TO authenticated;
