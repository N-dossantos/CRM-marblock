-- =============================================================
-- CRM — Fase A / migración 0109: RPC pagos a proveedor  §4.7/§4.8/§4.11
-- Espejo de Recibos pero en sentido contrario (dinero que SALE). Único comprobante de
-- Compras que numeramos nosotros: siguiente_numero('pago_proveedor').
--   * medios multi-modales (efectivo/transferencia/cheque_propio/cheque_tercero);
--   * imputa a N facturas de compra;
--   * registra retenciones (IVA/Ganancias/IIBB/SUSS);
--   * al usar un cheque de tercero, resuelve el handoff: cheques.estado='entregado' + FK real.
-- Cada factura imputada re-dispara recalcular_estado_factura_compra.
-- =============================================================

-- Contador propio para el número de pago (§4.7). Punto de venta 00002.
INSERT INTO contadores (tipo, punto_venta, ultimo_numero, descripcion)
VALUES ('pago_proveedor', '00002', 0, 'Pago a Proveedor')
ON CONFLICT (tipo) DO NOTHING;

CREATE OR REPLACE FUNCTION crear_pago_proveedor(
  p_proveedor_id  integer,
  p_medios        jsonb,
  p_factura_ids   integer[] DEFAULT '{}',
  p_fecha         date      DEFAULT NULL,
  p_retenciones   jsonb     DEFAULT '[]',
  p_observaciones text      DEFAULT NULL
)
RETURNS pagos_proveedor
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num   record;
  v_total numeric;
  v_pp    pagos_proveedor;
  v_fid   integer;
BEGIN
  IF p_proveedor_id IS NULL THEN
    RAISE EXCEPTION 'El proveedor es obligatorio.';
  END IF;
  IF p_medios IS NULL OR jsonb_array_length(p_medios) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un medio de pago.';
  END IF;

  SELECT COALESCE(SUM((m->>'monto')::numeric), 0) INTO v_total
  FROM jsonb_array_elements(p_medios) AS m;

  SELECT * INTO v_num FROM siguiente_numero('pago_proveedor');

  INSERT INTO pagos_proveedor
    (numero, punto_venta, numero_comp, fecha, proveedor_id, total, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero,
     COALESCE(p_fecha, CURRENT_DATE), p_proveedor_id, round(v_total, 2), p_observaciones)
  RETURNING * INTO v_pp;

  -- Medios
  INSERT INTO pago_proveedor_medios
    (pago_proveedor_id, tipo, detalle, cuenta_bancaria_id, cheque_id, cheque_propio_id, monto)
  SELECT
    v_pp.id, m->>'tipo', m->>'detalle',
    NULLIF(m->>'cuenta_bancaria_id', '')::int,
    NULLIF(m->>'cheque_id', '')::int,
    NULLIF(m->>'cheque_propio_id', '')::int,
    (m->>'monto')::numeric
  FROM jsonb_array_elements(p_medios) AS m;

  -- Cheques de tercero entregados: resolver el handoff (texto libre -> FK real, §4.9)
  UPDATE cheques SET estado = 'entregado', proveedor_id = p_proveedor_id, updated_at = NOW()
  WHERE id IN (
    SELECT cheque_id FROM pago_proveedor_medios
    WHERE pago_proveedor_id = v_pp.id AND tipo = 'cheque_tercero' AND cheque_id IS NOT NULL
  );

  -- Imputaciones a facturas de compra
  INSERT INTO pago_proveedor_facturas (pago_proveedor_id, factura_compra_id)
  SELECT v_pp.id, fid FROM unnest(p_factura_ids) AS fid;

  -- Retenciones (el frontend precompleta desde proveedor_alicuotas; acá se persisten)
  INSERT INTO retenciones
    (pago_proveedor_id, proveedor_id, tipo_retencion, jurisdiccion, numero_certificado,
     fecha, base_imponible, alicuota, monto)
  SELECT
    v_pp.id, p_proveedor_id, r->>'tipo_retencion', r->>'jurisdiccion', r->>'numero_certificado',
    COALESCE(NULLIF(r->>'fecha', '')::date, COALESCE(p_fecha, CURRENT_DATE)),
    (r->>'base_imponible')::numeric, (r->>'alicuota')::numeric, (r->>'monto')::numeric
  FROM jsonb_array_elements(COALESCE(p_retenciones, '[]'::jsonb)) AS r;

  -- Recalcular estado de cada factura imputada
  FOREACH v_fid IN ARRAY COALESCE(p_factura_ids, ARRAY[]::integer[]) LOOP
    PERFORM recalcular_estado_factura_compra(v_fid);
  END LOOP;

  RETURN v_pp;
END;
$$;

REVOKE ALL ON FUNCTION crear_pago_proveedor(integer, jsonb, integer[], date, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_pago_proveedor(integer, jsonb, integer[], date, jsonb, text) TO authenticated;
