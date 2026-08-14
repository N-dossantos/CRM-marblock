-- =============================================================
-- CRM — Fase C / migración 0204: RPC conciliación bancaria  §5.3
-- Conciliación por TILDADO MANUAL contra el extracto (la importación de extracto es backlog).
-- Abrir -> marcar movimientos -> cerrar (snapshot de saldo + diferencia).
-- =============================================================

-- ── Abrir una conciliación ────────────────────────────────────────
CREATE OR REPLACE FUNCTION abrir_conciliacion(
  p_cuenta_bancaria_id integer,
  p_desde              date,
  p_hasta              date,
  p_saldo_extracto     numeric
)
RETURNS conciliaciones_bancarias
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_c conciliaciones_bancarias;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cuentas_bancarias WHERE id = p_cuenta_bancaria_id) THEN
    RAISE EXCEPTION 'Cuenta % inexistente.', p_cuenta_bancaria_id;
  END IF;
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'Las fechas desde y hasta son obligatorias.';
  END IF;
  IF p_hasta < p_desde THEN
    RAISE EXCEPTION 'La fecha hasta no puede ser anterior a desde.';
  END IF;

  INSERT INTO conciliaciones_bancarias
    (cuenta_bancaria_id, fecha_desde, fecha_hasta, saldo_extracto, estado)
  VALUES
    (p_cuenta_bancaria_id, p_desde, p_hasta, COALESCE(p_saldo_extracto, 0), 'abierta')
  RETURNING * INTO v_c;

  RETURN v_c;
END;
$$;

REVOKE ALL ON FUNCTION abrir_conciliacion(integer, date, date, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION abrir_conciliacion(integer, date, date, numeric) TO authenticated;

-- ── Marcar el conjunto de movimientos conciliados (idempotente por set) ──
-- Recibe el set completo de ids tildados: primero limpia las marcas previas de ESTA
-- conciliación, luego aplica el nuevo set (sólo movimientos de la cuenta, no anulados,
-- que no estén tomados por otra conciliación).
CREATE OR REPLACE FUNCTION marcar_conciliado(
  p_conciliacion_id integer,
  p_movimiento_ids  integer[]
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_c conciliaciones_bancarias;
BEGIN
  SELECT * INTO v_c FROM conciliaciones_bancarias WHERE id = p_conciliacion_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conciliación % inexistente.', p_conciliacion_id;
  END IF;
  IF v_c.estado <> 'abierta' THEN
    RAISE EXCEPTION 'La conciliación % está cerrada; no admite cambios.', p_conciliacion_id;
  END IF;

  -- Limpiar marcas previas de esta conciliación
  UPDATE movimientos_tesoreria
  SET conciliado = FALSE, conciliacion_id = NULL, updated_at = NOW()
  WHERE conciliacion_id = p_conciliacion_id;

  -- Aplicar el nuevo set
  UPDATE movimientos_tesoreria
  SET conciliado = TRUE, conciliacion_id = p_conciliacion_id, updated_at = NOW()
  WHERE id = ANY(COALESCE(p_movimiento_ids, ARRAY[]::integer[]))
    AND cuenta_bancaria_id = v_c.cuenta_bancaria_id
    AND anulado = FALSE
    AND conciliacion_id IS NULL;
END;
$$;

REVOKE ALL ON FUNCTION marcar_conciliado(integer, integer[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION marcar_conciliado(integer, integer[]) TO authenticated;

-- ── Cerrar la conciliación (snapshot de saldo + diferencia) ───────
-- saldo_sistema = saldo_inicial de la cuenta + SUM(monto_con_signo) de los conciliados.
CREATE OR REPLACE FUNCTION cerrar_conciliacion(p_conciliacion_id integer)
RETURNS conciliaciones_bancarias
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_c        conciliaciones_bancarias;
  v_inicial  numeric;
  v_sum      numeric;
  v_sistema  numeric;
BEGIN
  SELECT * INTO v_c FROM conciliaciones_bancarias WHERE id = p_conciliacion_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conciliación % inexistente.', p_conciliacion_id;
  END IF;
  IF v_c.estado = 'cerrada' THEN
    RETURN v_c;  -- idempotente
  END IF;

  SELECT COALESCE(saldo_inicial, 0) INTO v_inicial
  FROM cuentas_bancarias WHERE id = v_c.cuenta_bancaria_id;

  SELECT COALESCE(SUM(monto_con_signo), 0) INTO v_sum
  FROM movimientos_tesoreria
  WHERE conciliacion_id = p_conciliacion_id AND anulado = FALSE;

  v_sistema := v_inicial + v_sum;

  UPDATE conciliaciones_bancarias
  SET saldo_sistema = v_sistema,
      diferencia    = COALESCE(saldo_extracto, 0) - v_sistema,
      estado        = 'cerrada',
      updated_at    = NOW()
  WHERE id = p_conciliacion_id
  RETURNING * INTO v_c;

  RETURN v_c;
END;
$$;

REVOKE ALL ON FUNCTION cerrar_conciliacion(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cerrar_conciliacion(integer) TO authenticated;
