-- =============================================================
-- CRM — Fase C / migración 0206: RPC reads + informes de Tesorería  §5.5
-- Espeja el formato de 0011/0110: SETOF jsonb (listados) o jsonb (informes con
-- cabecera+detalle+totales). SECURITY INVOKER; cierre de grants por bucle (anon revocado).
--   * movimientos_tesoreria_list  — listado filtrable (también get-by-id vía p_id).
--   * informe_saldos_tesoreria    — saldo por cuenta, agrupado + total general.
--   * informe_subdiario_cuenta    — ledger de una cuenta con SALDO CORRIDO.
--   * informe_mayor_tesoreria     — saldo inicial/débitos/créditos/saldo final por cuenta.
--   * informe_movimientos_por_operacion — agrupado por tipo de comprobante.
--   * informe_cheques_tesoreria   — UNIÓN terceros (cartera) + propios.
--   * informe_comprobantes_tesoreria — todos los movimientos del período + totales.
-- Histórico = movimientos_tesoreria_list con rango amplio (sin función nueva, §5.5).
-- =============================================================

-- ── LISTADO de movimientos (filtrable; get-by-id vía p_id) ────────
CREATE OR REPLACE FUNCTION movimientos_tesoreria_list(
  p_id      integer DEFAULT NULL,
  p_cuenta_id integer DEFAULT NULL,
  p_desde   date    DEFAULT NULL,
  p_hasta   date    DEFAULT NULL,
  p_tipo_id integer DEFAULT NULL,
  p_q       text    DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT mt.*,
      cb.descripcion AS cuenta_descripcion, cb.clase AS cuenta_clase,
      tc.codigo AS tipo_codigo, tc.descripcion AS tipo_descripcion
    FROM movimientos_tesoreria mt
    JOIN cuentas_bancarias cb ON cb.id = mt.cuenta_bancaria_id
    JOIN tipos_comprobante_tesoreria tc ON tc.id = mt.tipo_comprobante_tesoreria_id
    WHERE (p_id IS NULL OR mt.id = p_id)
      AND (p_cuenta_id IS NULL OR mt.cuenta_bancaria_id = p_cuenta_id)
      AND (p_desde IS NULL OR mt.fecha >= p_desde)
      AND (p_hasta IS NULL OR mt.fecha <= p_hasta)
      AND (p_tipo_id IS NULL OR mt.tipo_comprobante_tesoreria_id = p_tipo_id)
      AND (p_q IS NULL OR mt.concepto ILIKE '%'||p_q||'%'
                       OR mt.numero ILIKE '%'||p_q||'%'
                       OR cb.descripcion ILIKE '%'||p_q||'%')
    ORDER BY mt.fecha DESC, mt.id DESC
  ) t;
$$;

-- ── INFORME: saldos por cuenta (agrupado + total general) ─────────
CREATE OR REPLACE FUNCTION informe_saldos_tesoreria()
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH cuenta_saldos AS (
    SELECT cb.id, cb.descripcion, cb.clase, cb.agrupacion_id, cb.saldo_inicial,
      COALESCE(SUM(mt.monto) FILTER (WHERE mt.signo = 1  AND NOT mt.anulado), 0) AS entradas,
      COALESCE(SUM(mt.monto) FILTER (WHERE mt.signo = -1 AND NOT mt.anulado), 0) AS salidas,
      cb.saldo_inicial + COALESCE(SUM(mt.monto_con_signo) FILTER (WHERE NOT mt.anulado), 0) AS saldo_actual
    FROM cuentas_bancarias cb
    LEFT JOIN movimientos_tesoreria mt ON mt.cuenta_bancaria_id = cb.id
    GROUP BY cb.id
  )
  SELECT jsonb_build_object(
    'agrupaciones', (
      SELECT COALESCE(jsonb_agg(g ORDER BY g.orden, g.descripcion), '[]') FROM (
        SELECT
          COALESCE(ag.descripcion, 'Sin agrupación') AS descripcion,
          COALESCE(ag.orden, 999) AS orden,
          COALESCE(SUM(cs.saldo_actual), 0) AS subtotal,
          jsonb_agg(jsonb_build_object(
            'id', cs.id, 'descripcion', cs.descripcion, 'clase', cs.clase,
            'saldo_inicial', cs.saldo_inicial, 'entradas', cs.entradas,
            'salidas', cs.salidas, 'saldo_actual', cs.saldo_actual
          ) ORDER BY cs.descripcion) AS cuentas
        FROM cuenta_saldos cs
        LEFT JOIN agrupaciones_tesoreria ag ON ag.id = cs.agrupacion_id
        GROUP BY ag.id, ag.descripcion, ag.orden
      ) g
    ),
    'total_general', (SELECT COALESCE(SUM(saldo_actual), 0) FROM cuenta_saldos)
  );
$$;

-- ── INFORME: subdiario de una cuenta (saldo corrido) ──────────────
CREATE OR REPLACE FUNCTION informe_subdiario_cuenta(
  p_cuenta_id integer, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_cuenta  jsonb;
  v_opening numeric;
  v         jsonb;
BEGIN
  SELECT to_jsonb(cb) INTO v_cuenta FROM cuentas_bancarias cb WHERE cb.id = p_cuenta_id;
  IF v_cuenta IS NULL THEN
    RAISE EXCEPTION 'Cuenta no encontrada.';
  END IF;

  -- saldo de arranque = saldo_inicial + Σ movimientos anteriores a p_desde
  v_opening := (SELECT COALESCE(saldo_inicial, 0) FROM cuentas_bancarias WHERE id = p_cuenta_id)
    + (SELECT COALESCE(SUM(monto_con_signo), 0) FROM movimientos_tesoreria
       WHERE cuenta_bancaria_id = p_cuenta_id AND NOT anulado
         AND (p_desde IS NOT NULL AND fecha < p_desde));

  WITH movs AS (
    SELECT mt.id, mt.fecha, mt.numero, tc.codigo AS tipo_codigo, tc.descripcion AS tipo_descripcion,
      mt.concepto, mt.signo, mt.monto, mt.monto_con_signo, mt.origen,
      mt.conciliado, mt.anulado,
      v_opening + SUM(mt.monto_con_signo) FILTER (WHERE NOT mt.anulado)
        OVER (ORDER BY mt.fecha, mt.id ROWS UNBOUNDED PRECEDING) AS saldo_corrido
    FROM movimientos_tesoreria mt
    JOIN tipos_comprobante_tesoreria tc ON tc.id = mt.tipo_comprobante_tesoreria_id
    WHERE mt.cuenta_bancaria_id = p_cuenta_id
      AND (p_desde IS NULL OR mt.fecha >= p_desde)
      AND (p_hasta IS NULL OR mt.fecha <= p_hasta)
  )
  SELECT jsonb_build_object(
    'cuenta', v_cuenta,
    'saldo_inicial', v_opening,
    'movimientos', (SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.fecha, m.id), '[]') FROM movs m),
    'saldo_final', COALESCE(
      (SELECT m.saldo_corrido FROM movs m ORDER BY m.fecha DESC, m.id DESC LIMIT 1), v_opening)
  ) INTO v;

  RETURN v;
END;
$$;

-- ── INFORME: mayor de tesorería (por cuenta) ──────────────────────
CREATE OR REPLACE FUNCTION informe_mayor_tesoreria(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH cta AS (
    SELECT cb.id, cb.descripcion, cb.clase,
      cb.saldo_inicial + COALESCE((
        SELECT SUM(mt.monto_con_signo) FROM movimientos_tesoreria mt
        WHERE mt.cuenta_bancaria_id = cb.id AND NOT mt.anulado
          AND (p_desde IS NOT NULL AND mt.fecha < p_desde)), 0) AS saldo_inicial_periodo,
      COALESCE((SELECT SUM(mt.monto) FROM movimientos_tesoreria mt
        WHERE mt.cuenta_bancaria_id = cb.id AND NOT mt.anulado AND mt.signo = 1
          AND (p_desde IS NULL OR mt.fecha >= p_desde)
          AND (p_hasta IS NULL OR mt.fecha <= p_hasta)), 0) AS creditos,
      COALESCE((SELECT SUM(mt.monto) FROM movimientos_tesoreria mt
        WHERE mt.cuenta_bancaria_id = cb.id AND NOT mt.anulado AND mt.signo = -1
          AND (p_desde IS NULL OR mt.fecha >= p_desde)
          AND (p_hasta IS NULL OR mt.fecha <= p_hasta)), 0) AS debitos
    FROM cuentas_bancarias cb
  )
  SELECT jsonb_build_object(
    'cuentas', COALESCE(jsonb_agg(jsonb_build_object(
      'id', cta.id, 'descripcion', cta.descripcion, 'clase', cta.clase,
      'saldo_inicial', cta.saldo_inicial_periodo, 'debitos', cta.debitos, 'creditos', cta.creditos,
      'saldo_final', cta.saldo_inicial_periodo + cta.creditos - cta.debitos
    ) ORDER BY cta.descripcion), '[]'),
    'totales', jsonb_build_object(
      'debitos', COALESCE(SUM(cta.debitos), 0),
      'creditos', COALESCE(SUM(cta.creditos), 0),
      'saldo_final', COALESCE(SUM(cta.saldo_inicial_periodo + cta.creditos - cta.debitos), 0))
  ) FROM cta;
$$;

-- ── INFORME: movimientos por operación (tipo de comprobante) ──────
CREATE OR REPLACE FUNCTION informe_movimientos_por_operacion(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH ops AS (
    SELECT tc.codigo, tc.descripcion,
      COUNT(mt.id) AS cantidad,
      COALESCE(SUM(mt.monto) FILTER (WHERE mt.signo = 1), 0)  AS entradas,
      COALESCE(SUM(mt.monto) FILTER (WHERE mt.signo = -1), 0) AS salidas
    FROM tipos_comprobante_tesoreria tc
    LEFT JOIN movimientos_tesoreria mt
      ON mt.tipo_comprobante_tesoreria_id = tc.id AND NOT mt.anulado
        AND (p_desde IS NULL OR mt.fecha >= p_desde)
        AND (p_hasta IS NULL OR mt.fecha <= p_hasta)
    GROUP BY tc.id
    HAVING COUNT(mt.id) > 0
  )
  SELECT jsonb_build_object(
    'operaciones', COALESCE(jsonb_agg(jsonb_build_object(
      'codigo', codigo, 'descripcion', descripcion, 'cantidad', cantidad,
      'entradas', entradas, 'salidas', salidas, 'neto', entradas - salidas
    ) ORDER BY descripcion), '[]'),
    'totales', jsonb_build_object(
      'cantidad', COALESCE(SUM(cantidad), 0),
      'entradas', COALESCE(SUM(entradas), 0),
      'salidas', COALESCE(SUM(salidas), 0),
      'neto', COALESCE(SUM(entradas - salidas), 0))
  ) FROM ops;
$$;

-- ── INFORME: cheques (terceros cartera + propios) ─────────────────
CREATE OR REPLACE FUNCTION informe_cheques_tesoreria(
  p_estado text DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH ch AS (
    SELECT 'tercero'::text AS origen, c.id, c.numero, c.banco, c.tipo, c.monto,
      c.fecha_emision, c.fecha_vcto AS fecha_venc, c.estado, c.titular AS entidad
    FROM cheques c
    WHERE (p_estado IS NULL OR c.estado = p_estado)
      AND (p_desde IS NULL OR c.fecha_emision >= p_desde)
      AND (p_hasta IS NULL OR c.fecha_emision <= p_hasta)
    UNION ALL
    SELECT 'propio', cp.id, cp.numero, cb.descripcion AS banco, cp.tipo, cp.monto,
      cp.fecha_emision, cp.fecha_pago AS fecha_venc, cp.estado,
      COALESCE(cp.beneficiario, pr.razon_social) AS entidad
    FROM cheques_propios cp
    LEFT JOIN cuentas_bancarias cb ON cb.id = cp.cuenta_bancaria_id
    LEFT JOIN proveedores pr ON pr.id = cp.proveedor_id
    WHERE (p_estado IS NULL OR cp.estado = p_estado)
      AND (p_desde IS NULL OR cp.fecha_emision >= p_desde)
      AND (p_hasta IS NULL OR cp.fecha_emision <= p_hasta)
  )
  SELECT jsonb_build_object(
    'cheques', COALESCE(jsonb_agg(to_jsonb(ch) ORDER BY ch.fecha_emision DESC, ch.id DESC), '[]'),
    'totales', jsonb_build_object(
      'cantidad', COUNT(*),
      'monto',    COALESCE(SUM(monto), 0),
      'terceros', COALESCE(SUM(monto) FILTER (WHERE origen = 'tercero'), 0),
      'propios',  COALESCE(SUM(monto) FILTER (WHERE origen = 'propio'), 0))
  ) FROM ch;
$$;

-- ── INFORME: comprobantes de tesorería (todos los movimientos) ────
CREATE OR REPLACE FUNCTION informe_comprobantes_tesoreria(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH comps AS (
    SELECT mt.id, mt.fecha, mt.numero, cb.descripcion AS cuenta,
      tc.codigo AS tipo_codigo, tc.descripcion AS tipo_descripcion,
      mt.concepto, mt.signo, mt.monto, mt.monto_con_signo, mt.origen,
      mt.conciliado, mt.anulado
    FROM movimientos_tesoreria mt
    JOIN cuentas_bancarias cb ON cb.id = mt.cuenta_bancaria_id
    JOIN tipos_comprobante_tesoreria tc ON tc.id = mt.tipo_comprobante_tesoreria_id
    WHERE (p_desde IS NULL OR mt.fecha >= p_desde)
      AND (p_hasta IS NULL OR mt.fecha <= p_hasta)
  )
  SELECT jsonb_build_object(
    'movimientos', COALESCE(jsonb_agg(to_jsonb(comps) ORDER BY comps.fecha DESC, comps.id DESC), '[]'),
    'totales', jsonb_build_object(
      'cantidad', COUNT(*),
      'entradas', COALESCE(SUM(monto) FILTER (WHERE signo = 1  AND NOT anulado), 0),
      'salidas',  COALESCE(SUM(monto) FILTER (WHERE signo = -1 AND NOT anulado), 0),
      'neto',     COALESCE(SUM(monto_con_signo) FILTER (WHERE NOT anulado), 0))
  ) FROM comps;
$$;

-- ── Permisos: sólo staff autenticado; anon denegado ──────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'movimientos_tesoreria_list','informe_saldos_tesoreria','informe_subdiario_cuenta',
      'informe_mayor_tesoreria','informe_movimientos_por_operacion','informe_cheques_tesoreria',
      'informe_comprobantes_tesoreria'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated;', r.sig);
  END LOOP;
END $$;
