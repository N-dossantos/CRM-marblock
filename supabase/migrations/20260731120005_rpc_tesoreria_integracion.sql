-- =============================================================
-- CRM — Fase C / migración 0205: integración Tesorería ↔ Compras/Ventas  §4 / §5.4
-- Conecta los comprobantes origen con el ledger, SIN re-teclear nada:
--   * crear_pago_proveedor (Compras) se EXTIENDE (no se reescribe la lógica): además de
--     su comportamiento actual, emite movimientos -1 por medio efectivo/transferencia y
--     hace el handoff del cheque_propio (entregado + FK pago).
--   * crear_recibo (Ventas) se EXTIENDE de forma ADITIVA y OPCIONAL: si un medio
--     efectivo/transferencia trae 'cuenta_bancaria_id', emite COBRANZA (+1). Si no viene,
--     el recibo se comporta EXACTAMENTE como hoy (único retoque a Ventas, §4 ⚠, opción 1).
--   * generar_movimiento_desde_recibo: backfill de recibos históricos (§4 ⚠, opción 2).
-- Idempotente por medio: (origen='recibo', referencia_tipo='recibo_medios', referencia_id=medio_id).
-- =============================================================

-- ── Helper interno: emitir la cobranza de un recibo_medio (idempotente) ──
-- Sólo lo invocan RPC SECURITY DEFINER (corren como owner); anon/public revocado, sin
-- GRANT a authenticated.
CREATE OR REPLACE FUNCTION tes_emitir_cobranza(
  p_recibo_medio_id integer,
  p_cuenta_id       integer
)
RETURNS movimientos_tesoreria
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_rm       record;
  v_tipo_id  integer;
  v_existing movimientos_tesoreria;
  v_mov      movimientos_tesoreria;
BEGIN
  SELECT rm.id, rm.tipo, rm.monto, r.id AS recibo_id, r.fecha AS recibo_fecha, r.numero AS recibo_numero
    INTO v_rm
  FROM recibo_medios rm JOIN recibos r ON r.id = rm.recibo_id
  WHERE rm.id = p_recibo_medio_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Medio de recibo % inexistente.', p_recibo_medio_id;
  END IF;
  IF v_rm.tipo NOT IN ('efectivo','transferencia') THEN
    RAISE EXCEPTION 'Sólo medios efectivo/transferencia impactan un saldo directamente (medio %: %).',
      p_recibo_medio_id, v_rm.tipo;
  END IF;
  IF p_cuenta_id IS NULL OR NOT EXISTS (SELECT 1 FROM cuentas_bancarias WHERE id = p_cuenta_id) THEN
    RAISE EXCEPTION 'Cuenta % inexistente.', p_cuenta_id;
  END IF;

  -- Idempotencia: si ya existe el movimiento de este medio, devolverlo sin duplicar.
  SELECT * INTO v_existing FROM movimientos_tesoreria
  WHERE origen = 'recibo' AND referencia_tipo = 'recibo_medios'
    AND referencia_id = p_recibo_medio_id AND anulado = FALSE
  LIMIT 1;
  IF FOUND THEN
    RETURN v_existing;
  END IF;

  SELECT id INTO v_tipo_id FROM tipos_comprobante_tesoreria WHERE codigo = 'COBRANZA';

  INSERT INTO movimientos_tesoreria
    (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
     origen, referencia_tipo, referencia_id, concepto)
  VALUES
    (COALESCE(v_rm.recibo_fecha, CURRENT_DATE), p_cuenta_id, v_tipo_id, 1, v_rm.monto,
     'recibo', 'recibo_medios', p_recibo_medio_id,
     'Cobranza recibo '||v_rm.recibo_numero)
  RETURNING * INTO v_mov;

  RETURN v_mov;
END;
$$;

REVOKE ALL ON FUNCTION tes_emitir_cobranza(integer, integer) FROM PUBLIC, anon;

-- ═══════════════════════════════════════════════════════════════════
-- crear_pago_proveedor  — EXTENSIÓN (reemplaza 20260730120009 conservando su lógica)
-- ═══════════════════════════════════════════════════════════════════
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
  v_num     record;
  v_total   numeric;
  v_pp      pagos_proveedor;
  v_fid     integer;
  v_tipo_pp integer;
  v_caja    integer;
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

  -- ── Fase C: impacto en el ledger de Tesorería ──────────────────
  SELECT id INTO v_tipo_pp FROM tipos_comprobante_tesoreria WHERE codigo = 'PAGO_PROV';
  SELECT NULLIF(valor, '')::int INTO v_caja
  FROM config_empresa WHERE clave = 'tesoreria_caja_default_id';

  -- Efectivo -> caja default (si está configurada; si no, avisa y no genera)
  IF v_caja IS NOT NULL THEN
    INSERT INTO movimientos_tesoreria
      (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
       origen, referencia_tipo, referencia_id, concepto)
    SELECT COALESCE(p_fecha, CURRENT_DATE), v_caja, v_tipo_pp, -1, (m->>'monto')::numeric,
           'pago_proveedor', 'pagos_proveedor', v_pp.id, 'Pago a proveedor '||v_pp.numero||' (efectivo)'
    FROM jsonb_array_elements(p_medios) AS m
    WHERE m->>'tipo' = 'efectivo' AND (m->>'monto')::numeric > 0;
  ELSIF EXISTS (SELECT 1 FROM jsonb_array_elements(p_medios) m WHERE m->>'tipo' = 'efectivo') THEN
    RAISE NOTICE 'tesoreria_caja_default_id no configurada: no se generan movimientos de efectivo para el pago %.', v_pp.numero;
  END IF;

  -- Transferencia -> cuenta del medio
  INSERT INTO movimientos_tesoreria
    (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
     origen, referencia_tipo, referencia_id, concepto)
  SELECT COALESCE(p_fecha, CURRENT_DATE), NULLIF(m->>'cuenta_bancaria_id', '')::int, v_tipo_pp, -1,
         (m->>'monto')::numeric,
         'pago_proveedor', 'pagos_proveedor', v_pp.id, 'Pago a proveedor '||v_pp.numero||' (transferencia)'
  FROM jsonb_array_elements(p_medios) AS m
  WHERE m->>'tipo' = 'transferencia'
    AND NULLIF(m->>'cuenta_bancaria_id', '') IS NOT NULL
    AND (m->>'monto')::numeric > 0;

  -- Cheque propio -> handoff (entregado + link al pago); débito bancario difiere al 'pagado'
  UPDATE cheques_propios SET estado = 'entregado', pago_proveedor_id = v_pp.id, updated_at = NOW()
  WHERE id IN (
    SELECT NULLIF(m->>'cheque_propio_id', '')::int FROM jsonb_array_elements(p_medios) AS m
    WHERE m->>'tipo' = 'cheque_propio' AND NULLIF(m->>'cheque_propio_id', '') IS NOT NULL
  ) AND estado = 'emitido';

  -- Recalcular estado de cada factura imputada
  FOREACH v_fid IN ARRAY COALESCE(p_factura_ids, ARRAY[]::integer[]) LOOP
    PERFORM recalcular_estado_factura_compra(v_fid);
  END LOOP;

  RETURN v_pp;
END;
$$;

REVOKE ALL ON FUNCTION crear_pago_proveedor(integer, jsonb, integer[], date, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_pago_proveedor(integer, jsonb, integer[], date, jsonb, text) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- crear_recibo — EXTENSIÓN ADITIVA (reemplaza 20260727120009 conservando su lógica).
-- Sólo agrega: si un medio efectivo/transferencia trae 'cuenta_bancaria_id', emite COBRANZA(+1).
-- Misma firma; el frontend suma el campo opcional al objeto del medio.
-- ═══════════════════════════════════════════════════════════════════
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
  v_rm_id  integer;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_medios IS NULL OR jsonb_array_length(p_medios) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un medio de pago.';
  END IF;

  SELECT COALESCE(SUM((m->>'monto')::numeric), 0) INTO v_total
  FROM jsonb_array_elements(p_medios) AS m;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'El total debe ser mayor a cero.';
  END IF;

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

  SELECT * INTO v_num FROM siguiente_numero('recibo');
  INSERT INTO recibos (numero, punto_venta, numero_comp, fecha, cliente_id, total, observaciones)
  VALUES (v_num.numero_formateado, v_num.punto_venta, v_num.numero, CURRENT_DATE,
          p_cliente_id, v_total, p_observaciones)
  RETURNING * INTO v_recibo;

  FOR v_fid IN SELECT value::integer FROM jsonb_array_elements_text(p_factura_ids) LOOP
    PERFORM 1 FROM facturas
      WHERE id = v_fid AND cliente_id = p_cliente_id AND estado <> 'anulada';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Factura % inválida.', v_fid;
    END IF;
    INSERT INTO recibo_facturas (recibo_id, factura_id) VALUES (v_recibo.id, v_fid);
  END LOOP;

  FOR v_m IN SELECT value FROM jsonb_array_elements(p_medios) LOOP
    INSERT INTO recibo_medios
      (recibo_id, tipo, detalle, numero_cheque, banco, titular, cuit_titular,
       fecha_emision, fecha_vcto, monto)
    VALUES
      (v_recibo.id, v_m->>'tipo', v_m->>'detalle', v_m->>'numero_cheque', v_m->>'banco',
       v_m->>'titular', v_m->>'cuit_titular',
       NULLIF(v_m->>'fecha_emision','')::date, NULLIF(v_m->>'fecha_vcto','')::date,
       (v_m->>'monto')::numeric)
    RETURNING id INTO v_rm_id;

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

    -- Fase C (aditivo): cobranza efectivo/transferencia con cuenta asignada -> COBRANZA(+1)
    IF v_m->>'tipo' IN ('efectivo','transferencia')
       AND NULLIF(v_m->>'cuenta_bancaria_id','') IS NOT NULL THEN
      PERFORM tes_emitir_cobranza(v_rm_id, NULLIF(v_m->>'cuenta_bancaria_id','')::int);
    END IF;
  END LOOP;

  FOR v_fid IN SELECT value::integer FROM jsonb_array_elements_text(p_factura_ids) LOOP
    PERFORM recalcular_estado_factura(v_fid);
  END LOOP;

  RETURN v_recibo;
END;
$$;

REVOKE ALL ON FUNCTION crear_recibo(integer, jsonb, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_recibo(integer, jsonb, jsonb, text) TO authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- Backfill: asignar cobranzas de un recibo histórico a cuentas (§4 ⚠ opción 2)
-- p_asignaciones: [{recibo_medio_id, cuenta_bancaria_id}] (sólo efectivo/transferencia).
-- Idempotente vía tes_emitir_cobranza.
-- ═══════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION generar_movimiento_desde_recibo(
  p_recibo_id     integer,
  p_asignaciones  jsonb
)
RETURNS SETOF movimientos_tesoreria
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  a       jsonb;
  v_rm_id integer;
  v_cta   integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM recibos WHERE id = p_recibo_id) THEN
    RAISE EXCEPTION 'Recibo % inexistente.', p_recibo_id;
  END IF;

  FOR a IN SELECT value FROM jsonb_array_elements(COALESCE(p_asignaciones, '[]'::jsonb)) LOOP
    v_rm_id := NULLIF(a->>'recibo_medio_id','')::int;
    v_cta   := NULLIF(a->>'cuenta_bancaria_id','')::int;
    IF NOT EXISTS (SELECT 1 FROM recibo_medios WHERE id = v_rm_id AND recibo_id = p_recibo_id) THEN
      RAISE EXCEPTION 'El medio % no pertenece al recibo %.', v_rm_id, p_recibo_id;
    END IF;
    RETURN NEXT tes_emitir_cobranza(v_rm_id, v_cta);
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION generar_movimiento_desde_recibo(integer, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION generar_movimiento_desde_recibo(integer, jsonb) TO authenticated;
