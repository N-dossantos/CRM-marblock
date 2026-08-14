-- =============================================================
-- CRM — Fase C / migración 0202: RPC ledger — movimientos + transferencias  §5.1
-- Mismo patrón que las RPC de Compras: SECURITY DEFINER, search_path fijo, y por función
-- el trío REVOKE ALL FROM PUBLIC, anon + GRANT EXECUTE TO authenticated.
-- Ledger utilizable solo: alta manual + anulación + transferencia entre cuentas.
-- =============================================================

-- ── Alta de un movimiento (manual o disparado por otra RPC) ───────
CREATE OR REPLACE FUNCTION crear_movimiento_tesoreria(
  p_cuenta_bancaria_id integer,
  p_tipo_id            integer,
  p_signo              smallint,
  p_monto              numeric,
  p_fecha              date    DEFAULT NULL,
  p_concepto           text    DEFAULT NULL,
  p_origen             text    DEFAULT 'manual',
  p_referencia_tipo    text    DEFAULT NULL,
  p_referencia_id      integer DEFAULT NULL
)
RETURNS movimientos_tesoreria
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_mov movimientos_tesoreria;
BEGIN
  IF p_cuenta_bancaria_id IS NULL THEN
    RAISE EXCEPTION 'La cuenta es obligatoria.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cuentas_bancarias WHERE id = p_cuenta_bancaria_id) THEN
    RAISE EXCEPTION 'Cuenta % inexistente.', p_cuenta_bancaria_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM tipos_comprobante_tesoreria WHERE id = p_tipo_id) THEN
    RAISE EXCEPTION 'Tipo de comprobante % inexistente.', p_tipo_id;
  END IF;
  IF p_signo NOT IN (-1, 1) THEN
    RAISE EXCEPTION 'El signo debe ser -1 o 1.';
  END IF;
  IF p_monto IS NULL OR p_monto <= 0 THEN
    RAISE EXCEPTION 'El monto debe ser mayor a cero.';
  END IF;

  INSERT INTO movimientos_tesoreria
    (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
     origen, referencia_tipo, referencia_id, concepto)
  VALUES
    (COALESCE(p_fecha, CURRENT_DATE), p_cuenta_bancaria_id, p_tipo_id, p_signo, round(p_monto, 2),
     COALESCE(p_origen, 'manual'), p_referencia_tipo, p_referencia_id, p_concepto)
  RETURNING * INTO v_mov;

  RETURN v_mov;
END;
$$;

REVOKE ALL ON FUNCTION crear_movimiento_tesoreria(integer, integer, smallint, numeric, date, text, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_movimiento_tesoreria(integer, integer, smallint, numeric, date, text, text, text, integer) TO authenticated;

-- ── Anulación (no borra; preserva rastro y conciliación) ──────────
CREATE OR REPLACE FUNCTION anular_movimiento_tesoreria(p_id integer)
RETURNS movimientos_tesoreria
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_mov movimientos_tesoreria;
BEGIN
  SELECT * INTO v_mov FROM movimientos_tesoreria WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Movimiento % inexistente.', p_id;
  END IF;
  IF v_mov.conciliado THEN
    RAISE EXCEPTION 'No se puede anular un movimiento ya conciliado (integridad del extracto cerrado).';
  END IF;
  IF v_mov.anulado THEN
    RETURN v_mov;  -- idempotente
  END IF;

  UPDATE movimientos_tesoreria SET anulado = TRUE, updated_at = NOW()
  WHERE id = p_id RETURNING * INTO v_mov;
  RETURN v_mov;
END;
$$;

REVOKE ALL ON FUNCTION anular_movimiento_tesoreria(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION anular_movimiento_tesoreria(integer) TO authenticated;

-- ── Transferencia entre cuentas (par atómico débito/crédito)  §5.1 ─
-- (frontend → Fase D; el backend va en C porque el ledger la necesita para cerrar
--  contra sí mismo). Ambas patas origen='transferencia', cruzadas por referencia.
CREATE OR REPLACE FUNCTION crear_transferencia(
  p_cuenta_origen_id  integer,
  p_cuenta_destino_id integer,
  p_monto             numeric,
  p_fecha             date DEFAULT NULL,
  p_concepto          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_tipo_id   integer;
  v_fecha     date := COALESCE(p_fecha, CURRENT_DATE);
  v_debito_id integer;
  v_credito_id integer;
BEGIN
  IF p_cuenta_origen_id IS NULL OR p_cuenta_destino_id IS NULL THEN
    RAISE EXCEPTION 'Cuenta origen y destino son obligatorias.';
  END IF;
  IF p_cuenta_origen_id = p_cuenta_destino_id THEN
    RAISE EXCEPTION 'La cuenta origen y destino deben ser distintas.';
  END IF;
  IF p_monto IS NULL OR p_monto <= 0 THEN
    RAISE EXCEPTION 'El monto debe ser mayor a cero.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cuentas_bancarias WHERE id = p_cuenta_origen_id) THEN
    RAISE EXCEPTION 'Cuenta origen % inexistente.', p_cuenta_origen_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cuentas_bancarias WHERE id = p_cuenta_destino_id) THEN
    RAISE EXCEPTION 'Cuenta destino % inexistente.', p_cuenta_destino_id;
  END IF;

  SELECT id INTO v_tipo_id FROM tipos_comprobante_tesoreria WHERE codigo = 'TRANSF';
  IF v_tipo_id IS NULL THEN
    RAISE EXCEPTION 'Falta el tipo de comprobante TRANSF.';
  END IF;

  -- Pata débito (-1) sobre origen
  INSERT INTO movimientos_tesoreria
    (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
     origen, referencia_tipo, concepto)
  VALUES
    (v_fecha, p_cuenta_origen_id, v_tipo_id, -1, round(p_monto, 2),
     'transferencia', 'movimientos_tesoreria',
     COALESCE(p_concepto, 'Transferencia a cuenta '||p_cuenta_destino_id))
  RETURNING id INTO v_debito_id;

  -- Pata crédito (+1) sobre destino, referenciando la pata débito
  INSERT INTO movimientos_tesoreria
    (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
     origen, referencia_tipo, referencia_id, concepto)
  VALUES
    (v_fecha, p_cuenta_destino_id, v_tipo_id, 1, round(p_monto, 2),
     'transferencia', 'movimientos_tesoreria', v_debito_id,
     COALESCE(p_concepto, 'Transferencia desde cuenta '||p_cuenta_origen_id))
  RETURNING id INTO v_credito_id;

  -- Cruzar la referencia de la pata débito hacia la de crédito
  UPDATE movimientos_tesoreria SET referencia_id = v_credito_id, updated_at = NOW()
  WHERE id = v_debito_id;

  RETURN jsonb_build_object('debito_id', v_debito_id, 'credito_id', v_credito_id);
END;
$$;

REVOKE ALL ON FUNCTION crear_transferencia(integer, integer, numeric, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_transferencia(integer, integer, numeric, date, text) TO authenticated;
