-- =============================================================
-- CRM Ventas — remitos de venta: campos que exige el formulario preimpreso
--
-- El talonario tiene tres recuadros que el modelo no podía completar:
-- "Condiciones de Venta", "Domicilio de obra" y "Teléfono". Hasta ahora se
-- llenaban a mano; para poder imprimirlos, pasan a ser columnas del remito.
--
-- El teléfono se llama `telefono_entrega` y NO `telefono` a propósito:
-- `remitos_list` hace `SELECT r.*, ..., c.telefono` (el del cliente), así que una
-- columna `remitos.telefono` produciría DOS claves `telefono` en el mismo jsonb y
-- la del cliente pisaría a la del remito sin error visible. El nombre además es
-- más honesto: es el teléfono de la entrega, que rara vez es el de administración.
--
-- Los tres son nullable: hay entregas donde no aplican y un recuadro vacío no
-- puede bloquear un remito.
-- =============================================================

ALTER TABLE remitos
  ADD COLUMN IF NOT EXISTS condiciones_venta VARCHAR(100),
  ADD COLUMN IF NOT EXISTS domicilio_obra    VARCHAR(200),
  ADD COLUMN IF NOT EXISTS telefono_entrega  VARCHAR(50);

-- ──────────────────────────────────────────────────────────────
-- crear_remito — suma los tres campos del formulario.
--   DROP + CREATE otra vez: cambiar la lista de parámetros crea una sobrecarga y
--   PostgREST no podría resolver la llamada (mismo motivo que en 20260820120001).
-- ──────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS crear_remito(integer, varchar, jsonb, text, integer);

CREATE FUNCTION crear_remito(
  p_cliente_id        integer,
  p_numero            varchar,
  p_items             jsonb,
  p_observaciones     text    DEFAULT NULL,
  p_presupuesto_id    integer DEFAULT NULL,
  p_condiciones_venta varchar DEFAULT NULL,
  p_domicilio_obra    varchar DEFAULT NULL,
  p_telefono_entrega  varchar DEFAULT NULL
)
RETURNS remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_numero varchar;
  v_pv     CHAR(5);
  v_comp   INTEGER;
  v_rem    remitos;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  v_numero := NULLIF(trim(p_numero), '');
  IF v_numero IS NULL THEN
    RAISE EXCEPTION 'El número del remito es obligatorio.';
  END IF;
  IF v_numero !~ '^\d{5}-\d{8}$' THEN
    RAISE EXCEPTION 'El número % no tiene el formato PPPPP-NNNNNNNN (ej. 00002-00000123).', v_numero;
  END IF;

  v_pv   := split_part(v_numero, '-', 1);
  v_comp := split_part(v_numero, '-', 2)::INTEGER;

  BEGIN
    INSERT INTO remitos
      (numero, punto_venta, numero_comp, fecha, cliente_id, presupuesto_id, estado, observaciones,
       condiciones_venta, domicilio_obra, telefono_entrega)
    VALUES
      (v_numero, v_pv, v_comp, CURRENT_DATE,
       p_cliente_id, p_presupuesto_id, 'pendiente', p_observaciones,
       NULLIF(trim(p_condiciones_venta), ''), NULLIF(trim(p_domicilio_obra), ''),
       NULLIF(trim(p_telefono_entrega), ''))
    RETURNING * INTO v_rem;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'El remito % ya fue emitido.', v_numero;
  END;

  PERFORM crm_insert_remito_items(v_rem.id, p_items);

  IF p_presupuesto_id IS NOT NULL THEN
    UPDATE presupuestos SET estado = 'convertido', updated_at = NOW() WHERE id = p_presupuesto_id;
  END IF;

  UPDATE contadores
     SET ultimo_numero = v_comp,
         punto_venta   = v_pv
   WHERE tipo = 'remito'
     AND (punto_venta <> v_pv OR ultimo_numero < v_comp);

  RETURN v_rem;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- actualizar_remito — idem, sin tocar el número (hoja arruinada = anular y reemitir).
-- ──────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS actualizar_remito(integer, integer, jsonb, text);

CREATE FUNCTION actualizar_remito(
  p_id                integer,
  p_cliente_id        integer,
  p_items             jsonb,
  p_observaciones     text    DEFAULT NULL,
  p_condiciones_venta varchar DEFAULT NULL,
  p_domicilio_obra    varchar DEFAULT NULL,
  p_telefono_entrega  varchar DEFAULT NULL
)
RETURNS remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur remitos;
  v_rem remitos;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_cur FROM remitos WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remito no encontrado';
  END IF;
  IF v_cur.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'Solo se pueden editar remitos en estado pendiente.';
  END IF;

  UPDATE remitos SET
    cliente_id        = p_cliente_id,
    observaciones     = p_observaciones,
    condiciones_venta = NULLIF(trim(p_condiciones_venta), ''),
    domicilio_obra    = NULLIF(trim(p_domicilio_obra), ''),
    telefono_entrega  = NULLIF(trim(p_telefono_entrega), ''),
    updated_at        = NOW()
  WHERE id = p_id
  RETURNING * INTO v_rem;

  DELETE FROM remito_items WHERE remito_id = p_id;
  PERFORM crm_insert_remito_items(p_id, p_items);
  RETURN v_rem;
END;
$$;

-- ── Permisos ───────────────────────────────────────────────────
REVOKE ALL ON FUNCTION crear_remito(integer, varchar, jsonb, text, integer, varchar, varchar, varchar) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_remito(integer, integer, jsonb, text, varchar, varchar, varchar)     FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_remito(integer, varchar, jsonb, text, integer, varchar, varchar, varchar) TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_remito(integer, integer, jsonb, text, varchar, varchar, varchar)     TO authenticated;

-- ──────────────────────────────────────────────────────────────
-- Talonario en uso (AGEE, rango 00001-00010101 al 00010400, CAI vence 25/11/2026).
-- La próxima hoja sin usar es la 00010325, y remito_numero_sugerido() devuelve
-- ultimo_numero + 1 — por eso va 10324, no 10325.
-- ──────────────────────────────────────────────────────────────
UPDATE contadores
   SET punto_venta = '00001', ultimo_numero = 10324
 WHERE tipo = 'remito';
