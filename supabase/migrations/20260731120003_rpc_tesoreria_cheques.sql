-- =============================================================
-- CRM — Fase C / migración 0203: RPC cheques  §5.2
--   * Cheques de TERCEROS (cartera existente): impactan el ledger al DEPOSITARSE.
--   * Cheques PROPIOS (nuevos): impactan al pasar a 'pagado' (el banco los debita).
-- Mismo patrón SECURITY DEFINER + trío de grants por función.
-- =============================================================

-- ── Depositar un cheque de tercero -> ACRED_CHEQUE (+1) ───────────
CREATE OR REPLACE FUNCTION depositar_cheque_tercero(
  p_cheque_id          integer,
  p_cuenta_bancaria_id integer,
  p_fecha              date DEFAULT NULL
)
RETURNS movimientos_tesoreria
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cheque cheques;
  v_tipo_id integer;
  v_mov    movimientos_tesoreria;
BEGIN
  SELECT * INTO v_cheque FROM cheques WHERE id = p_cheque_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cheque % inexistente.', p_cheque_id;
  END IF;
  IF v_cheque.estado <> 'en_cartera' THEN
    RAISE EXCEPTION 'Sólo se puede depositar un cheque en cartera (estado actual: %).', v_cheque.estado;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cuentas_bancarias WHERE id = p_cuenta_bancaria_id) THEN
    RAISE EXCEPTION 'Cuenta % inexistente.', p_cuenta_bancaria_id;
  END IF;

  SELECT id INTO v_tipo_id FROM tipos_comprobante_tesoreria WHERE codigo = 'ACRED_CHEQUE';

  UPDATE cheques SET estado = 'depositado', updated_at = NOW() WHERE id = p_cheque_id;

  INSERT INTO movimientos_tesoreria
    (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
     origen, referencia_tipo, referencia_id, concepto)
  VALUES
    (COALESCE(p_fecha, CURRENT_DATE), p_cuenta_bancaria_id, v_tipo_id, 1, v_cheque.monto,
     'cheque', 'cheques', p_cheque_id,
     'Acreditación cheque '||v_cheque.numero||' ('||v_cheque.banco||')')
  RETURNING * INTO v_mov;

  RETURN v_mov;
END;
$$;

REVOKE ALL ON FUNCTION depositar_cheque_tercero(integer, integer, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION depositar_cheque_tercero(integer, integer, date) TO authenticated;

-- ── Rechazar un cheque de tercero depositado -> RECHAZO_CHEQUE (-1) ─
CREATE OR REPLACE FUNCTION rechazar_cheque_tercero(p_cheque_id integer)
RETURNS movimientos_tesoreria
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cheque cheques;
  v_acred  movimientos_tesoreria;
  v_tipo_id integer;
  v_mov    movimientos_tesoreria;
BEGIN
  SELECT * INTO v_cheque FROM cheques WHERE id = p_cheque_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cheque % inexistente.', p_cheque_id;
  END IF;
  IF v_cheque.estado <> 'depositado' THEN
    RAISE EXCEPTION 'Sólo se rechaza un cheque depositado (estado actual: %).', v_cheque.estado;
  END IF;

  -- La acreditación que se revierte (última no anulada de este cheque)
  SELECT * INTO v_acred FROM movimientos_tesoreria
  WHERE origen = 'cheque' AND referencia_tipo = 'cheques' AND referencia_id = p_cheque_id
    AND signo = 1 AND anulado = FALSE
  ORDER BY id DESC LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se encontró la acreditación a revertir para el cheque %.', p_cheque_id;
  END IF;

  SELECT id INTO v_tipo_id FROM tipos_comprobante_tesoreria WHERE codigo = 'RECHAZO_CHEQUE';

  UPDATE cheques SET estado = 'rechazado_banco', updated_at = NOW() WHERE id = p_cheque_id;

  INSERT INTO movimientos_tesoreria
    (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
     origen, referencia_tipo, referencia_id, concepto)
  VALUES
    (CURRENT_DATE, v_acred.cuenta_bancaria_id, v_tipo_id, -1, v_acred.monto,
     'cheque', 'cheques', p_cheque_id,
     'Rechazo cheque '||v_cheque.numero||' ('||v_cheque.banco||')')
  RETURNING * INTO v_mov;

  RETURN v_mov;
END;
$$;

REVOKE ALL ON FUNCTION rechazar_cheque_tercero(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION rechazar_cheque_tercero(integer) TO authenticated;

-- ── Emitir un cheque propio (sin impacto en saldo hasta 'pagado') ──
CREATE OR REPLACE FUNCTION crear_cheque_propio(
  p_cuenta_bancaria_id integer,
  p_numero             text,
  p_monto              numeric,
  p_fecha_pago         date,
  p_tipo               text    DEFAULT 'fisico',
  p_beneficiario       text    DEFAULT NULL,
  p_proveedor_id       integer DEFAULT NULL,
  p_fecha_emision      date    DEFAULT NULL,
  p_pago_proveedor_id  integer DEFAULT NULL,
  p_observaciones      text    DEFAULT NULL
)
RETURNS cheques_propios
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_ch cheques_propios;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cuentas_bancarias WHERE id = p_cuenta_bancaria_id) THEN
    RAISE EXCEPTION 'Cuenta % inexistente.', p_cuenta_bancaria_id;
  END IF;
  IF NULLIF(p_numero, '') IS NULL THEN
    RAISE EXCEPTION 'El número de cheque es obligatorio.';
  END IF;
  IF p_monto IS NULL OR p_monto <= 0 THEN
    RAISE EXCEPTION 'El monto debe ser mayor a cero.';
  END IF;
  IF p_fecha_pago IS NULL THEN
    RAISE EXCEPTION 'La fecha de pago es obligatoria.';
  END IF;
  IF COALESCE(p_tipo, 'fisico') NOT IN ('fisico','echeq') THEN
    RAISE EXCEPTION 'Tipo de cheque inválido: %', p_tipo;
  END IF;

  INSERT INTO cheques_propios
    (numero, cuenta_bancaria_id, tipo, beneficiario, proveedor_id,
     fecha_emision, fecha_pago, monto, estado, pago_proveedor_id, observaciones)
  VALUES
    (p_numero, p_cuenta_bancaria_id, COALESCE(p_tipo, 'fisico'), p_beneficiario, p_proveedor_id,
     COALESCE(p_fecha_emision, CURRENT_DATE), p_fecha_pago, round(p_monto, 2),
     CASE WHEN p_pago_proveedor_id IS NOT NULL THEN 'entregado' ELSE 'emitido' END,
     p_pago_proveedor_id, p_observaciones)
  RETURNING * INTO v_ch;

  RETURN v_ch;
END;
$$;

REVOKE ALL ON FUNCTION crear_cheque_propio(integer, text, numeric, date, text, text, integer, date, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_cheque_propio(integer, text, numeric, date, text, text, integer, date, integer, text) TO authenticated;

-- ── Transición de estado de un cheque propio  §5.2 ─────────────────
--   emitido   → entregado | anulado
--   entregado → pagado | rechazado | anulado
--   pagado    → rechazado (revierte el débito con +1)
--   Al 'pagado': PAGO_CHEQUE_PROPIO (-1) sobre su cuenta. Al 'rechazado' desde 'pagado': (+1).
CREATE OR REPLACE FUNCTION actualizar_estado_cheque_propio(
  p_id integer, p_nuevo_estado text
)
RETURNS cheques_propios
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_ch      cheques_propios;
  v_ok      boolean := FALSE;
  v_tipo_id integer;
BEGIN
  SELECT * INTO v_ch FROM cheques_propios WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cheque propio % inexistente.', p_id;
  END IF;

  -- Validación de la transición
  v_ok := CASE
    WHEN v_ch.estado = 'emitido'   AND p_nuevo_estado IN ('entregado','anulado')            THEN TRUE
    WHEN v_ch.estado = 'entregado' AND p_nuevo_estado IN ('pagado','rechazado','anulado')   THEN TRUE
    WHEN v_ch.estado = 'pagado'    AND p_nuevo_estado = 'rechazado'                          THEN TRUE
    ELSE FALSE
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'Transición inválida: % -> %.', v_ch.estado, p_nuevo_estado;
  END IF;

  -- Impacto en el ledger
  IF p_nuevo_estado = 'pagado' THEN
    SELECT id INTO v_tipo_id FROM tipos_comprobante_tesoreria WHERE codigo = 'PAGO_CHEQUE_PROPIO';
    INSERT INTO movimientos_tesoreria
      (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
       origen, referencia_tipo, referencia_id, concepto)
    VALUES
      (COALESCE(v_ch.fecha_pago, CURRENT_DATE), v_ch.cuenta_bancaria_id, v_tipo_id, -1, v_ch.monto,
       'cheque_propio', 'cheques_propios', v_ch.id,
       'Pago cheque propio '||v_ch.numero);
  ELSIF p_nuevo_estado = 'rechazado' AND v_ch.estado = 'pagado' THEN
    SELECT id INTO v_tipo_id FROM tipos_comprobante_tesoreria WHERE codigo = 'PAGO_CHEQUE_PROPIO';
    INSERT INTO movimientos_tesoreria
      (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
       origen, referencia_tipo, referencia_id, concepto)
    VALUES
      (CURRENT_DATE, v_ch.cuenta_bancaria_id, v_tipo_id, 1, v_ch.monto,
       'cheque_propio', 'cheques_propios', v_ch.id,
       'Reversión por rechazo cheque propio '||v_ch.numero);
  END IF;

  UPDATE cheques_propios SET estado = p_nuevo_estado, updated_at = NOW()
  WHERE id = p_id RETURNING * INTO v_ch;

  RETURN v_ch;
END;
$$;

REVOKE ALL ON FUNCTION actualizar_estado_cheque_propio(integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION actualizar_estado_cheque_propio(integer, text) TO authenticated;
