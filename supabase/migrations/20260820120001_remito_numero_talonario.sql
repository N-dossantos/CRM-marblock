-- =============================================================
-- CRM Ventas — remitos de venta: el número lo da el talonario preimpreso
--
-- Los remitos de venta se emiten sobre formularios preimpresos que YA vienen
-- numerados de imprenta. El número del comprobante pasa a ser el de la hoja
-- física, no uno generado por el sistema: `siguiente_numero('remito')` deja de
-- usarse acá y `contadores` cambia de rol — de ASIGNAR el número a SUGERIRLO.
--
-- Por qué no se puede usar siguiente_numero() para sugerir: hace
-- `UPDATE ultimo_numero + 1` y devuelve el valor, o sea CONSUME el número. Si el
-- operador abre el formulario y lo cierra sin guardar, se quema una hoja del
-- talonario. De ahí `remito_numero_sugerido()`, que es un peek de sólo lectura.
--
-- Hojas arruinadas: se anulan con `remito_anular()` (ya existente) y se reemite
-- con el número siguiente. El UNIQUE de remitos.numero deja el número anulado
-- ocupado para siempre — es el equivalente exacto de la hoja tachada que queda
-- pegada en el talonario, y documenta el hueco para auditoría.
--
-- Esto sigue el patrón de numeración ajena que ya usan `crear_remito_compra`
-- (0730120007) y `crear_remito_cuenta2` (0815120002).
--
-- NO afecta la numeración del resto de los comprobantes: facturas, presupuestos,
-- notas y recibos siguen usando siguiente_numero() sin cambios.
-- =============================================================

-- ──────────────────────────────────────────────────────────────
-- remito_numero_sugerido — peek de sólo lectura sobre contadores.
--   Devuelve la misma forma que siguiente_numero() para que el frontend no tenga
--   que distinguir, pero NO incrementa nada: llamarla N veces da siempre lo mismo.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION remito_numero_sugerido()
RETURNS TABLE (punto_venta CHAR(5), numero INTEGER, numero_formateado VARCHAR)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_pv  CHAR(5);
  v_num INTEGER;
BEGIN
  SELECT c.punto_venta, c.ultimo_numero + 1
    INTO v_pv, v_num
    FROM contadores c
   WHERE c.tipo = 'remito';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No hay contador configurado para remitos.';
  END IF;

  RETURN QUERY SELECT
    v_pv,
    v_num,
    (v_pv || '-' || LPAD(v_num::TEXT, 8, '0'))::VARCHAR;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- crear_remito — ahora recibe el número de la hoja del talonario.
--   Se DROPea la firma vieja en vez de CREATE OR REPLACE: agregar un parámetro
--   crea una SOBRECARGA, y dos overloads de crear_remito dejarían a PostgREST sin
--   poder resolver a cuál llamar.
-- ──────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS crear_remito(integer, jsonb, text, integer);

CREATE FUNCTION crear_remito(
  p_cliente_id     integer,
  p_numero         varchar,
  p_items          jsonb,
  p_observaciones  text    DEFAULT NULL,
  p_presupuesto_id integer DEFAULT NULL
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
  -- Formato del talonario: PPPPP-NNNNNNNN. Se valida porque de acá salen
  -- punto_venta y numero_comp, que son columnas propias de la tabla.
  IF v_numero !~ '^\d{5}-\d{8}$' THEN
    RAISE EXCEPTION 'El número % no tiene el formato PPPPP-NNNNNNNN (ej. 00002-00000123).', v_numero;
  END IF;

  v_pv   := split_part(v_numero, '-', 1);
  v_comp := split_part(v_numero, '-', 2)::INTEGER;

  BEGIN
    INSERT INTO remitos
      (numero, punto_venta, numero_comp, fecha, cliente_id, presupuesto_id, estado, observaciones)
    VALUES
      (v_numero, v_pv, v_comp, CURRENT_DATE,
       p_cliente_id, p_presupuesto_id, 'pendiente', p_observaciones)
    RETURNING * INTO v_rem;
  EXCEPTION WHEN unique_violation THEN
    -- El UNIQUE de remitos.numero es el control real de duplicados; acá sólo se
    -- traduce a un mensaje que el operador entienda al ver el toast.
    RAISE EXCEPTION 'El remito % ya fue emitido.', v_numero;
  END;

  PERFORM crm_insert_remito_items(v_rem.id, p_items);

  IF p_presupuesto_id IS NOT NULL THEN
    UPDATE presupuestos SET estado = 'convertido', updated_at = NOW() WHERE id = p_presupuesto_id;
  END IF;

  -- El contador sigue al talonario, nunca lo empuja hacia atrás: corregir un
  -- número salteado no debe hacer que la próxima sugerencia repita hojas ya
  -- usadas. Si cambia el punto de venta es un talonario nuevo y se adopta entero.
  UPDATE contadores
     SET ultimo_numero = v_comp,
         punto_venta   = v_pv
   WHERE tipo = 'remito'
     AND (punto_venta <> v_pv OR ultimo_numero < v_comp);

  RETURN v_rem;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- Fila de contadores para remitos.
--   Se crea vacía a propósito: el punto de venta y el último número reales salen
--   del talonario físico que esté en uso, y se cargan con un UPDATE (mismo
--   criterio que el resto de los contadores — ver CLAUDE.md), no desde el código:
--     UPDATE contadores SET punto_venta = '0001', ultimo_numero = 12344 WHERE tipo = 'remito';
-- ──────────────────────────────────────────────────────────────
INSERT INTO contadores (tipo, punto_venta, ultimo_numero, descripcion)
VALUES ('remito', '00002', 0, 'Remitos de venta — numeración del talonario preimpreso')
ON CONFLICT (tipo) DO NOTHING;

-- ── Permisos ───────────────────────────────────────────────────
REVOKE ALL ON FUNCTION remito_numero_sugerido()                              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_remito(integer, varchar, jsonb, text, integer)  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION remito_numero_sugerido()                             TO authenticated;
GRANT EXECUTE ON FUNCTION crear_remito(integer, varchar, jsonb, text, integer) TO authenticated;
