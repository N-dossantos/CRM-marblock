-- =============================================================
-- CRM — Fase E / migración 0302: RPC de asientos manuales  §3/§4
-- crear_asiento (alta manual balanceada) + anular_asiento (estado='anulado', no DELETE).
-- Estas dos SÍ funcionan sin la matriz de imputación (§3): permiten cargar contabilidad a
-- mano. La generación automática (generar_asiento_desde_*) va en 0303 y queda bloqueada.
-- Patrón de las demás RPC de escritura: SECURITY DEFINER, valida server-side, numera con
-- siguiente_numero('asiento').
-- =============================================================

-- ── crear_asiento: alta manual de un asiento balanceado ───────────
--    p_lineas: [{cuenta_id, debe, haber, detalle?, orden?}, ...]
--    Valida: >=2 líneas, cada cuenta imputable+activa, debe XOR haber por línea,
--    SUM(debe)=SUM(haber) y > 0. Numera y devuelve la cabecera.
CREATE OR REPLACE FUNCTION crear_asiento(
  p_fecha           date,
  p_descripcion     text,
  p_lineas          jsonb,
  p_origen          text    DEFAULT 'manual',
  p_referencia_tipo text    DEFAULT NULL,
  p_referencia_id   integer DEFAULT NULL
)
RETURNS asientos_contables
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num     record;
  v_debe    numeric;
  v_haber   numeric;
  v_asiento asientos_contables;
BEGIN
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'La fecha del asiento es obligatoria.';
  END IF;
  IF COALESCE(btrim(p_descripcion), '') = '' THEN
    RAISE EXCEPTION 'La descripción del asiento es obligatoria.';
  END IF;
  IF p_lineas IS NULL OR jsonb_array_length(p_lineas) < 2 THEN
    RAISE EXCEPTION 'Un asiento requiere al menos dos líneas (partida doble).';
  END IF;

  -- Cada línea debe referenciar una cuenta imputable y activa.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_lineas) AS l
    LEFT JOIN plan_de_cuentas c ON c.id = NULLIF(l->>'cuenta_id', '')::int
    WHERE c.id IS NULL OR c.imputable = FALSE OR c.activo = FALSE
  ) THEN
    RAISE EXCEPTION 'Todas las líneas deben referenciar una cuenta imputable y activa.';
  END IF;

  -- Una línea es debe O haber, y nunca cero-cero.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_lineas) AS l
    WHERE COALESCE((l->>'debe')::numeric, 0) > 0 AND COALESCE((l->>'haber')::numeric, 0) > 0
  ) THEN
    RAISE EXCEPTION 'Una línea no puede tener debe y haber a la vez.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_lineas) AS l
    WHERE COALESCE((l->>'debe')::numeric, 0) = 0 AND COALESCE((l->>'haber')::numeric, 0) = 0
  ) THEN
    RAISE EXCEPTION 'Cada línea debe tener importe en el debe o en el haber.';
  END IF;

  -- Balance: SUM(debe) = SUM(haber), y no todo cero.
  SELECT COALESCE(SUM((l->>'debe')::numeric), 0), COALESCE(SUM((l->>'haber')::numeric), 0)
    INTO v_debe, v_haber
  FROM jsonb_array_elements(p_lineas) AS l;

  IF round(v_debe, 2) <> round(v_haber, 2) THEN
    RAISE EXCEPTION 'El asiento no balancea: debe=% haber=%.', round(v_debe, 2), round(v_haber, 2);
  END IF;
  IF round(v_debe, 2) = 0 THEN
    RAISE EXCEPTION 'El asiento no puede tener importe cero.';
  END IF;

  SELECT * INTO v_num FROM siguiente_numero('asiento');

  INSERT INTO asientos_contables
    (numero, fecha, descripcion, origen, referencia_tipo, referencia_id)
  VALUES
    (v_num.numero, p_fecha, btrim(p_descripcion), COALESCE(p_origen, 'manual'),
     p_referencia_tipo, p_referencia_id)
  RETURNING * INTO v_asiento;

  INSERT INTO asiento_items (asiento_id, cuenta_id, debe, haber, detalle, orden)
  SELECT
    v_asiento.id,
    (l->>'cuenta_id')::int,
    round(COALESCE((l->>'debe')::numeric, 0), 2),
    round(COALESCE((l->>'haber')::numeric, 0), 2),
    NULLIF(l->>'detalle', ''),
    COALESCE(NULLIF(l->>'orden', '')::int, (ord - 1)::int)
  FROM jsonb_array_elements(p_lineas) WITH ORDINALITY AS arr(l, ord);

  RETURN v_asiento;
END;
$$;

-- ── anular_asiento: marca estado='anulado' (nunca DELETE) ─────────
CREATE OR REPLACE FUNCTION anular_asiento(p_id integer)
RETURNS asientos_contables
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_asiento asientos_contables;
BEGIN
  SELECT * INTO v_asiento FROM asientos_contables WHERE id = p_id;
  IF v_asiento.id IS NULL THEN
    RAISE EXCEPTION 'Asiento no encontrado.';
  END IF;
  IF v_asiento.estado = 'anulado' THEN
    RAISE EXCEPTION 'El asiento ya está anulado.';
  END IF;

  UPDATE asientos_contables
  SET estado = 'anulado', updated_at = NOW()
  WHERE id = p_id
  RETURNING * INTO v_asiento;

  RETURN v_asiento;
END;
$$;

-- ── Permisos: sólo staff autenticado; anon denegado ──────────────
REVOKE ALL ON FUNCTION crear_asiento(date, text, jsonb, text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_asiento(date, text, jsonb, text, text, integer) TO authenticated;
REVOKE ALL ON FUNCTION anular_asiento(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION anular_asiento(integer) TO authenticated;
