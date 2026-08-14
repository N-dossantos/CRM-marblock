-- =============================================================
-- CRM — Fase E / migración 0304: reads + informes contables  §5
-- Espeja el formato de 0011/0110/0206: jsonb con cabecera+detalle+totales, SECURITY INVOKER,
-- cierre de grants por bucle (anon revocado). Todos read-only sobre asientos_contables +
-- asiento_items + plan_de_cuentas. Sólo cuentan asientos 'confirmado' (borrador = no
-- imputado, anulado = reversado).
--   * informe_libro_diario   — asientos cronológicos con sus líneas + totales.
--   * informe_libro_mayor    — una cuenta, con SALDO CORRIDO (debe-haber acumulado).
--   * informe_sumas_y_saldos — balance de comprobación (saldo inicial | debe | haber | saldo final).
-- La "Consulta > contabilidad" de cada sector = informe_libro_diario / mayor filtrado por
-- (referencia_tipo, referencia_id) del comprobante mirado (idx_asientos_referencia) — se
-- enchufa en las fichas 360° de Fases B/D (§5).
-- =============================================================

-- ── INFORME: libro diario (asientos cronológicos con líneas) ──────
CREATE OR REPLACE FUNCTION informe_libro_diario(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH asi AS (
    SELECT a.id, a.numero, a.fecha, a.descripcion, a.origen,
      a.referencia_tipo, a.referencia_id,
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'cuenta_id', ai.cuenta_id, 'codigo', c.codigo, 'cuenta', c.descripcion,
          'debe', ai.debe, 'haber', ai.haber, 'detalle', ai.detalle
        ) ORDER BY ai.orden, ai.id), '[]')
       FROM asiento_items ai JOIN plan_de_cuentas c ON c.id = ai.cuenta_id
       WHERE ai.asiento_id = a.id) AS lineas,
      (SELECT COALESCE(SUM(ai.debe), 0)  FROM asiento_items ai WHERE ai.asiento_id = a.id) AS total_debe,
      (SELECT COALESCE(SUM(ai.haber), 0) FROM asiento_items ai WHERE ai.asiento_id = a.id) AS total_haber
    FROM asientos_contables a
    WHERE a.estado = 'confirmado'
      AND (p_desde IS NULL OR a.fecha >= p_desde)
      AND (p_hasta IS NULL OR a.fecha <= p_hasta)
  )
  SELECT jsonb_build_object(
    'asientos', COALESCE(jsonb_agg(jsonb_build_object(
        'id', asi.id, 'numero', asi.numero, 'fecha', asi.fecha,
        'descripcion', asi.descripcion, 'origen', asi.origen,
        'referencia_tipo', asi.referencia_tipo, 'referencia_id', asi.referencia_id,
        'lineas', asi.lineas, 'total_debe', asi.total_debe, 'total_haber', asi.total_haber
      ) ORDER BY asi.fecha, asi.numero), '[]'),
    'totales', jsonb_build_object(
      'cantidad', COUNT(*),
      'debe',  COALESCE(SUM(asi.total_debe), 0),
      'haber', COALESCE(SUM(asi.total_haber), 0))
  ) FROM asi;
$$;

-- ── INFORME: libro mayor de una cuenta (saldo corrido) ────────────
CREATE OR REPLACE FUNCTION informe_libro_mayor(
  p_cuenta_id integer, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_cuenta  jsonb;
  v_opening numeric;
  v         jsonb;
BEGIN
  SELECT to_jsonb(c) INTO v_cuenta FROM plan_de_cuentas c WHERE c.id = p_cuenta_id;
  IF v_cuenta IS NULL THEN
    RAISE EXCEPTION 'Cuenta no encontrada.';
  END IF;

  -- saldo de arranque = Σ(debe-haber) de asientos confirmados anteriores a p_desde
  v_opening := (
    SELECT COALESCE(SUM(ai.debe - ai.haber), 0)
    FROM asiento_items ai JOIN asientos_contables a ON a.id = ai.asiento_id
    WHERE ai.cuenta_id = p_cuenta_id AND a.estado = 'confirmado'
      AND (p_desde IS NOT NULL AND a.fecha < p_desde));

  WITH movs AS (
    SELECT ai.id AS item_id, a.id AS asiento_id, a.numero, a.fecha, a.descripcion, a.origen,
      ai.debe, ai.haber, ai.detalle,
      v_opening + SUM(ai.debe - ai.haber)
        OVER (ORDER BY a.fecha, a.numero, ai.id ROWS UNBOUNDED PRECEDING) AS saldo
    FROM asiento_items ai JOIN asientos_contables a ON a.id = ai.asiento_id
    WHERE ai.cuenta_id = p_cuenta_id AND a.estado = 'confirmado'
      AND (p_desde IS NULL OR a.fecha >= p_desde)
      AND (p_hasta IS NULL OR a.fecha <= p_hasta)
  )
  SELECT jsonb_build_object(
    'cuenta', v_cuenta,
    'saldo_inicial', v_opening,
    'movimientos', (SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.fecha, m.numero, m.item_id), '[]') FROM movs m),
    'totales', jsonb_build_object(
      'debe',  (SELECT COALESCE(SUM(debe), 0)  FROM movs),
      'haber', (SELECT COALESCE(SUM(haber), 0) FROM movs),
      'saldo_final', COALESCE(
        (SELECT saldo FROM movs ORDER BY fecha DESC, numero DESC, item_id DESC LIMIT 1), v_opening))
  ) INTO v;

  RETURN v;
END;
$$;

-- ── INFORME: sumas y saldos (balance de comprobación) ─────────────
CREATE OR REPLACE FUNCTION informe_sumas_y_saldos(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH per_cuenta AS (
    SELECT c.id, c.codigo, c.descripcion, c.tipo_cuenta,
      COALESCE(SUM(ai.debe - ai.haber) FILTER (
        WHERE p_desde IS NOT NULL AND a.fecha < p_desde), 0) AS saldo_inicial,
      COALESCE(SUM(ai.debe) FILTER (
        WHERE (p_desde IS NULL OR a.fecha >= p_desde)
          AND (p_hasta IS NULL OR a.fecha <= p_hasta)), 0) AS debe,
      COALESCE(SUM(ai.haber) FILTER (
        WHERE (p_desde IS NULL OR a.fecha >= p_desde)
          AND (p_hasta IS NULL OR a.fecha <= p_hasta)), 0) AS haber
    FROM plan_de_cuentas c
    JOIN asiento_items ai      ON ai.cuenta_id = c.id
    JOIN asientos_contables a  ON a.id = ai.asiento_id AND a.estado = 'confirmado'
    WHERE c.imputable = TRUE
    GROUP BY c.id
  ),
  con_saldo AS (
    SELECT *, saldo_inicial + debe - haber AS saldo_final FROM per_cuenta
    WHERE saldo_inicial <> 0 OR debe <> 0 OR haber <> 0
  )
  SELECT jsonb_build_object(
    'cuentas', COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'codigo', codigo, 'descripcion', descripcion, 'tipo_cuenta', tipo_cuenta,
      'saldo_inicial', saldo_inicial, 'debe', debe, 'haber', haber, 'saldo_final', saldo_final
    ) ORDER BY codigo), '[]'),
    'totales', jsonb_build_object(
      'debe',  COALESCE(SUM(debe), 0),
      'haber', COALESCE(SUM(haber), 0),
      'saldo_final', COALESCE(SUM(saldo_final), 0))
  ) FROM con_saldo;
$$;

-- ── Permisos: sólo staff autenticado; anon denegado ──────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'informe_libro_diario','informe_libro_mayor','informe_sumas_y_saldos'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated;', r.sig);
  END LOOP;
END $$;
