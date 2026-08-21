-- =============================================================
-- CRM — Cuenta 2: registrar el pago al proveedor desde el mismo formulario del Remito X.
--
-- En la operatoria real el remito de compra y su pago pasan en el mismo acto (se retira el
-- material y se paga en el momento), pero hasta ahora había que cargar el remito, ir a la tab de
-- cuenta corriente, buscar el proveedor y recién ahí registrar el pago.
--
-- Por qué una RPC nueva y no dos llamadas desde el browser: PostgREST no abarca una transacción
-- multi-llamada, así que dos `.rpc()` seguidas pueden dejar el remito cargado y el pago no si la
-- segunda falla — el saldo del proveedor quedaría inflado sin que nadie se entere. Esta función
-- envuelve las dos escrituras en una sola transacción reusando las funciones que ya existen
-- (crear_remito_cuenta2 + registrar_movimiento_cuenta2): toda la validación de entidad, cheques,
-- signo del movimiento y recálculo de totales sigue viviendo en un solo lugar.
--
-- No se le agregan parámetros a crear_remito_cuenta2 porque sumar argumentos crea una sobrecarga
-- (no reemplaza la función) y PostgREST no sabría cuál elegir.
--
-- p_pago (NULL = sin pago, el comportamiento de siempre):
--   { monto, fecha, medio, concepto, cheque, cheque_id }  — mismas reglas que §1.5/§1.6.
-- Idempotente (CREATE OR REPLACE).
-- =============================================================

CREATE OR REPLACE FUNCTION crear_remito_cuenta2_con_pago(
  p_tipo_sector       varchar,
  p_entidad_id        integer,
  p_numero            varchar,
  p_items             jsonb,
  p_fecha             date    DEFAULT NULL,
  p_descuento_general numeric DEFAULT 0,
  p_observaciones     text    DEFAULT NULL,
  p_pago              jsonb   DEFAULT NULL
)
RETURNS cuenta2_remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_rem   cuenta2_remitos;
  v_monto numeric;
BEGIN
  SELECT * INTO v_rem FROM crear_remito_cuenta2(
    p_tipo_sector, p_entidad_id, p_numero, p_items,
    p_fecha, p_descuento_general, p_observaciones
  );

  IF p_pago IS NULL THEN
    RETURN v_rem;
  END IF;

  v_monto := COALESCE(NULLIF(p_pago->>'monto', '')::numeric, 0);
  IF v_monto <= 0 THEN
    RAISE EXCEPTION 'El monto del pago debe ser mayor a cero.';
  END IF;

  -- El tipo lo decide el sector, no el browser: en compra sale plata (PAGO), en venta entra
  -- (COBRO). registrar_movimiento_cuenta2 rechaza la combinación cruzada de todos modos.
  PERFORM registrar_movimiento_cuenta2(
    p_tipo_sector := p_tipo_sector,
    p_entidad_id  := p_entidad_id,
    p_tipo        := CASE WHEN p_tipo_sector = 'compra' THEN 'PAGO' ELSE 'COBRO' END,
    p_monto       := v_monto,
    p_fecha       := COALESCE(NULLIF(p_pago->>'fecha', '')::date, v_rem.fecha),
    p_medio       := NULLIF(p_pago->>'medio', ''),
    -- Sin concepto propio queda la referencia al remito, para poder rastrear el pago en la
    -- cuenta corriente sin abrir el comprobante.
    p_concepto    := COALESCE(NULLIF(p_pago->>'concepto', ''), 'Remito X ' || v_rem.numero),
    p_cheque      := CASE WHEN jsonb_typeof(p_pago->'cheque') = 'object' THEN p_pago->'cheque' END,
    p_cheque_id   := NULLIF(p_pago->>'cheque_id', '')::integer
  );

  RETURN v_rem;
END;
$$;

REVOKE ALL ON FUNCTION crear_remito_cuenta2_con_pago(varchar, integer, varchar, jsonb, date, numeric, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_remito_cuenta2_con_pago(varchar, integer, varchar, jsonb, date, numeric, text, jsonb) TO authenticated;
