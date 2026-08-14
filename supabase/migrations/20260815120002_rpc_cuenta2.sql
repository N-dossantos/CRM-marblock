-- =============================================================
-- CRM — Cuenta 2 / migración 0502: RPC de escritura del circuito informal
-- Mismo patrón de referencia que 20260727120003_rpc_presupuestos.sql: validar → totales →
-- INSERT cabecera → PERFORM helper de ítems → RETURN <rowtype>. Los totales SIEMPRE se
-- recalculan acá; el browser nunca manda un total.
--
-- Diferencias propias de Cuenta 2:
--   * NO se llama siguiente_numero(): el número de Remito X lo tipea el usuario (§1.3),
--     igual que en crear_remito_compra (numeración ajena).
--   * NO hay IVA: crm_calc_totales_cuenta2() es la versión sin impuestos de crm_calc_totales().
--   * NO hay comprobante de cobro/pago (§1.5): registrar_movimiento_cuenta2() impacta la
--     cuenta corriente directo.
-- Idempotente (CREATE OR REPLACE).
-- =============================================================

-- ──────────────────────────────────────────────────────────────
-- Helper: totales de un Remito X — SIN IVA (§1.3).
--   subtotal = Σ(cantidad · precio · (1 - dto_item/100)),  total = subtotal - dto general.
--   No reusa crm_calc_totales(): esa hardcodea el 21% y devuelve neto_gravado/iva_monto.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm_calc_totales_cuenta2(
  p_items             jsonb,
  p_descuento_general numeric DEFAULT 0
)
RETURNS TABLE (
  subtotal        numeric,
  descuento_monto numeric,
  total           numeric
)
LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_subtotal numeric := 0;
  v_desc     numeric := 0;
BEGIN
  SELECT COALESCE(SUM(
           (it->>'cantidad')::numeric
         * (it->>'precio_unitario')::numeric
         * (1 - COALESCE((it->>'descuento_item')::numeric, 0) / 100)
         ), 0)
    INTO v_subtotal
  FROM jsonb_array_elements(p_items) AS it;

  v_desc := v_subtotal * (COALESCE(p_descuento_general, 0) / 100);

  subtotal        := round(v_subtotal, 2);
  descuento_monto := round(v_desc, 2);
  total           := round(v_subtotal - v_desc, 2);
  RETURN NEXT;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- Helper interno: inserta los ítems de un Remito X desde jsonb.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm_insert_cuenta2_remito_items(
  p_remito_id integer,
  p_items     jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO cuenta2_remito_items
    (remito_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden)
  SELECT
    p_remito_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer                       -- orden 0-based, igual que el resto del sistema
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- Helper interno: valida que la entidad exista y esté en la tabla que corresponde al sector.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crm_check_entidad_cuenta2(
  p_tipo_sector varchar,
  p_entidad_id  integer
)
RETURNS void
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
BEGIN
  IF p_tipo_sector NOT IN ('venta','compra') THEN
    RAISE EXCEPTION 'Sector inválido: debe ser venta o compra.';
  END IF;
  IF p_entidad_id IS NULL THEN
    RAISE EXCEPTION 'El cliente/proveedor es obligatorio.';
  END IF;

  IF p_tipo_sector = 'venta' THEN
    IF NOT EXISTS (SELECT 1 FROM clientes_cuenta2 WHERE id = p_entidad_id) THEN
      RAISE EXCEPTION 'Cliente de Cuenta 2 no encontrado.';
    END IF;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM proveedores_cuenta2 WHERE id = p_entidad_id) THEN
      RAISE EXCEPTION 'Proveedor de Cuenta 2 no encontrado.';
    END IF;
  END IF;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- crear_remito_cuenta2  (§1.3) — número manual, precios netos, sin impacto en stock.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION crear_remito_cuenta2(
  p_tipo_sector       varchar,
  p_entidad_id        integer,
  p_numero            varchar,
  p_items             jsonb,
  p_fecha             date    DEFAULT NULL,
  p_descuento_general numeric DEFAULT 0,
  p_observaciones     text    DEFAULT NULL
)
RETURNS cuenta2_remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_tot record;
  v_rem cuenta2_remitos;
BEGIN
  PERFORM crm_check_entidad_cuenta2(p_tipo_sector, p_entidad_id);

  IF NULLIF(trim(p_numero), '') IS NULL THEN
    RAISE EXCEPTION 'El número de remito es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_tot FROM crm_calc_totales_cuenta2(p_items, p_descuento_general);

  INSERT INTO cuenta2_remitos
    (tipo_sector, cliente_id, proveedor_id, numero, fecha, descuento_porcentaje,
     subtotal, descuento_monto, total, observaciones)
  VALUES
    (p_tipo_sector,
     CASE WHEN p_tipo_sector = 'venta'  THEN p_entidad_id END,
     CASE WHEN p_tipo_sector = 'compra' THEN p_entidad_id END,
     trim(p_numero), COALESCE(p_fecha, CURRENT_DATE), COALESCE(p_descuento_general, 0),
     v_tot.subtotal, v_tot.descuento_monto, v_tot.total, p_observaciones)
  RETURNING * INTO v_rem;

  PERFORM crm_insert_cuenta2_remito_items(v_rem.id, p_items);
  RETURN v_rem;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- actualizar_remito_cuenta2 — borra e reinserta los ítems, igual que actualizar_remito.
--   No permite cambiar de sector: eso sería otro comprobante.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION actualizar_remito_cuenta2(
  p_id                integer,
  p_entidad_id        integer,
  p_numero            varchar,
  p_items             jsonb,
  p_fecha             date    DEFAULT NULL,
  p_descuento_general numeric DEFAULT 0,
  p_observaciones     text    DEFAULT NULL
)
RETURNS cuenta2_remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur cuenta2_remitos;
  v_tot record;
  v_rem cuenta2_remitos;
BEGIN
  SELECT * INTO v_cur FROM cuenta2_remitos WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remito X no encontrado.';
  END IF;

  PERFORM crm_check_entidad_cuenta2(v_cur.tipo_sector, p_entidad_id);

  IF NULLIF(trim(p_numero), '') IS NULL THEN
    RAISE EXCEPTION 'El número de remito es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_tot FROM crm_calc_totales_cuenta2(p_items, p_descuento_general);

  UPDATE cuenta2_remitos SET
    cliente_id           = CASE WHEN v_cur.tipo_sector = 'venta'  THEN p_entidad_id END,
    proveedor_id         = CASE WHEN v_cur.tipo_sector = 'compra' THEN p_entidad_id END,
    numero               = trim(p_numero),
    fecha                = COALESCE(p_fecha, fecha),
    descuento_porcentaje = COALESCE(p_descuento_general, 0),
    subtotal             = v_tot.subtotal,
    descuento_monto      = v_tot.descuento_monto,
    total                = v_tot.total,
    observaciones        = p_observaciones,
    updated_at           = NOW()
  WHERE id = p_id
  RETURNING * INTO v_rem;

  DELETE FROM cuenta2_remito_items WHERE remito_id = p_id;
  PERFORM crm_insert_cuenta2_remito_items(p_id, p_items);
  RETURN v_rem;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- eliminar_remito_cuenta2 — borrado real (ítems por CASCADE).
--   No hay estado 'anulado' porque no hay comprobante fiscal que preservar, y como la cta.
--   cte. se calcula al leer, el borrado la limpia sola.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION eliminar_remito_cuenta2(p_id integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  DELETE FROM cuenta2_remitos WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remito X no encontrado.';
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- registrar_movimiento_cuenta2  (§1.5) — cobro / pago / ajuste directo a la cta. cte.
--   p_monto:  COBRO/PAGO exigen > 0 y van al HABER.
--             AJUSTE acepta signo: > 0 → DEBE (aumenta la deuda), < 0 → HABER.
--             Es el mecanismo para cargar un saldo inicial.
--   Cheques (§1.6): con p_medio = 'cheque' hay exactamente dos caminos —
--             p_cheque_id  → ENDOSO de un cheque que ya está en la cartera C2;
--             p_cheque     → alta de un cheque nuevo en la cartera C2.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION registrar_movimiento_cuenta2(
  p_tipo_sector varchar,
  p_entidad_id  integer,
  p_tipo        varchar,
  p_monto       numeric,
  p_fecha       date    DEFAULT NULL,
  p_medio       varchar DEFAULT NULL,
  p_concepto    text    DEFAULT NULL,
  p_cheque      jsonb   DEFAULT NULL,
  p_cheque_id   integer DEFAULT NULL
)
RETURNS cuenta2_movimientos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_debe      numeric := 0;
  v_haber     numeric := 0;
  v_chq       cuenta2_cheques;
  v_cheque_id integer := NULL;
  v_concepto  text;
  v_mov       cuenta2_movimientos;
BEGIN
  PERFORM crm_check_entidad_cuenta2(p_tipo_sector, p_entidad_id);

  IF p_tipo NOT IN ('COBRO','PAGO','AJUSTE') THEN
    RAISE EXCEPTION 'Tipo de movimiento inválido.';
  END IF;
  IF p_tipo = 'COBRO' AND p_tipo_sector <> 'venta' THEN
    RAISE EXCEPTION 'Un cobro solo aplica a un cliente de Cuenta 2.';
  END IF;
  IF p_tipo = 'PAGO' AND p_tipo_sector <> 'compra' THEN
    RAISE EXCEPTION 'Un pago solo aplica a un proveedor de Cuenta 2.';
  END IF;

  -- Signo: cobro/pago siempre acreditan; el ajuste elige según el signo del monto.
  IF p_tipo = 'AJUSTE' THEN
    IF COALESCE(p_monto, 0) = 0 THEN
      RAISE EXCEPTION 'El monto del ajuste no puede ser cero.';
    END IF;
    IF p_medio IS NOT NULL THEN
      RAISE EXCEPTION 'Un ajuste no lleva medio de pago.';
    END IF;
    IF p_monto > 0 THEN v_debe := p_monto; ELSE v_haber := -p_monto; END IF;
  ELSE
    IF COALESCE(p_monto, 0) <= 0 THEN
      RAISE EXCEPTION 'El monto debe ser mayor a cero.';
    END IF;
    IF p_medio NOT IN ('efectivo','transferencia','cheque') THEN
      RAISE EXCEPTION 'Medio de pago inválido: debe ser efectivo, transferencia o cheque.';
    END IF;
    v_haber := p_monto;
  END IF;

  -- Cheque: endoso desde la cartera C2, o alta de uno nuevo. Nunca las dos cosas.
  IF p_medio = 'cheque' THEN
    IF (p_cheque_id IS NULL) = (p_cheque IS NULL) THEN
      RAISE EXCEPTION 'Con medio cheque hay que elegir uno de la cartera Cuenta 2 o cargar los datos de uno nuevo.';
    END IF;

    IF p_cheque_id IS NOT NULL THEN
      SELECT * INTO v_chq FROM cuenta2_cheques WHERE id = p_cheque_id FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Cheque de Cuenta 2 no encontrado.';
      END IF;
      IF v_chq.estado <> 'en_cartera' THEN
        RAISE EXCEPTION 'El cheque no está en cartera (estado actual: %).', v_chq.estado;
      END IF;
      IF p_tipo <> 'PAGO' THEN
        RAISE EXCEPTION 'Solo un pago a proveedor puede endosar un cheque de la cartera Cuenta 2.';
      END IF;

      UPDATE cuenta2_cheques
         SET estado = 'entregado', proveedor_id = p_entidad_id, updated_at = NOW()
       WHERE id = p_cheque_id;
      v_cheque_id := p_cheque_id;
    ELSE
      IF NULLIF(trim(p_cheque->>'numero'), '') IS NULL
         OR NULLIF(trim(p_cheque->>'banco'), '') IS NULL THEN
        RAISE EXCEPTION 'El cheque necesita banco y número.';
      END IF;
      IF NULLIF(p_cheque->>'fecha_vcto', '') IS NULL THEN
        RAISE EXCEPTION 'El cheque necesita fecha de vencimiento.';
      END IF;
      IF COALESCE(NULLIF(p_cheque->>'monto', '')::numeric, 0) <= 0 THEN
        RAISE EXCEPTION 'El monto del cheque debe ser mayor a cero.';
      END IF;

      INSERT INTO cuenta2_cheques
        (numero, tipo, banco, titular, cuit_titular, fecha_emision, fecha_vcto, monto,
         cliente_id, proveedor_id, estado, observaciones)
      VALUES
        (p_cheque->>'numero',
         COALESCE(NULLIF(p_cheque->>'tipo', ''), 'fisico'),
         p_cheque->>'banco',
         NULLIF(p_cheque->>'titular', ''),
         NULLIF(p_cheque->>'cuit_titular', ''),
         COALESCE(NULLIF(p_cheque->>'fecha_emision','')::date, COALESCE(p_fecha, CURRENT_DATE)),
         NULLIF(p_cheque->>'fecha_vcto','')::date,
         (p_cheque->>'monto')::numeric,
         CASE WHEN p_tipo_sector = 'venta'  THEN p_entidad_id END,
         CASE WHEN p_tipo_sector = 'compra' THEN p_entidad_id END,
         CASE WHEN p_tipo = 'COBRO' THEN 'en_cartera' ELSE 'entregado' END,
         NULLIF(p_cheque->>'observaciones', ''))
      RETURNING id INTO v_cheque_id;
    END IF;
  END IF;

  v_concepto := COALESCE(
    NULLIF(trim(p_concepto), ''),
    CASE p_tipo WHEN 'COBRO' THEN 'Cobro' WHEN 'PAGO' THEN 'Pago' ELSE 'Ajuste' END
      || COALESCE(' ' || p_medio, '')
  );

  INSERT INTO cuenta2_movimientos
    (tipo_sector, cliente_id, proveedor_id, fecha, tipo, medio, debe, haber, cheque_id, concepto)
  VALUES
    (p_tipo_sector,
     CASE WHEN p_tipo_sector = 'venta'  THEN p_entidad_id END,
     CASE WHEN p_tipo_sector = 'compra' THEN p_entidad_id END,
     COALESCE(p_fecha, CURRENT_DATE), p_tipo, p_medio, v_debe, v_haber, v_cheque_id, v_concepto)
  RETURNING * INTO v_mov;

  -- Marca de origen: solo si este movimiento dio de alta el cheque (no si lo endosó).
  IF v_cheque_id IS NOT NULL AND p_cheque_id IS NULL THEN
    UPDATE cuenta2_cheques SET origen_movimiento_id = v_mov.id WHERE id = v_cheque_id;
  END IF;

  RETURN v_mov;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- eliminar_movimiento_cuenta2 — corrección de carga (no hay comprobante que anular).
--   Deshace el efecto sobre la cartera según origen_movimiento_id:
--     * cheque dado de alta por este movimiento → se borra;
--     * cheque endosado por este movimiento     → vuelve a 'en_cartera';
--     * cheque ya transferido a Cuenta 1        → no se puede deshacer.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION eliminar_movimiento_cuenta2(p_id integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_mov cuenta2_movimientos;
  v_chq cuenta2_cheques;
BEGIN
  SELECT * INTO v_mov FROM cuenta2_movimientos WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Movimiento no encontrado.';
  END IF;

  IF v_mov.cheque_id IS NOT NULL THEN
    SELECT * INTO v_chq FROM cuenta2_cheques WHERE id = v_mov.cheque_id FOR UPDATE;

    IF v_chq.estado = 'transferido_c1' THEN
      RAISE EXCEPTION 'El cheque de este movimiento ya fue transferido a Cuenta 1; no se puede eliminar.';
    END IF;

    IF v_chq.origen_movimiento_id = v_mov.id THEN
      DELETE FROM cuenta2_movimientos WHERE id = p_id;   -- primero: cheque_id lo referencia
      DELETE FROM cuenta2_cheques     WHERE id = v_chq.id;
      RETURN jsonb_build_object('ok', true, 'cheque', 'eliminado');
    END IF;

    -- Endoso: el cheque preexistía, vuelve a estar disponible en la cartera.
    UPDATE cuenta2_cheques
       SET estado = 'en_cartera', proveedor_id = NULL, updated_at = NOW()
     WHERE id = v_chq.id;
    DELETE FROM cuenta2_movimientos WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'cheque', 'devuelto a cartera');
  END IF;

  DELETE FROM cuenta2_movimientos WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- transferir_cheque_cuenta2_a_cuenta1  (§1.6 / §5.4) — el ÚNICO puente hacia Cuenta 1.
--   p_datos: ediciones opcionales antes de migrar (banco, numero, monto, fechas, titular, cuit).
--   El cheque nace en la cartera oficial 'en_cartera' y desde ahí sigue el circuito normal
--   (depositar_cheque_tercero / entregar). cliente_id va NULL a propósito: el cliente de
--   Cuenta 2 no existe en `clientes`, así que su nombre queda en observaciones.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION transferir_cheque_cuenta2_a_cuenta1(
  p_id    integer,
  p_datos jsonb DEFAULT NULL
)
RETURNS cheques
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_chq  cuenta2_cheques;
  v_nom  text;
  v_obs  text;
  v_new  cheques;
BEGIN
  SELECT * INTO v_chq FROM cuenta2_cheques WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cheque de Cuenta 2 no encontrado.';
  END IF;
  IF v_chq.estado = 'transferido_c1' THEN
    RAISE EXCEPTION 'El cheque ya fue transferido a Cuenta 1.';
  END IF;
  IF v_chq.estado <> 'en_cartera' THEN
    RAISE EXCEPTION 'Solo se puede transferir un cheque en cartera (estado actual: %).', v_chq.estado;
  END IF;

  -- Ediciones opcionales sobre la fila de Cuenta 2 antes de migrarla.
  IF p_datos IS NOT NULL THEN
    UPDATE cuenta2_cheques SET
      numero        = COALESCE(NULLIF(p_datos->>'numero', ''), numero),
      tipo          = COALESCE(NULLIF(p_datos->>'tipo', ''), tipo),
      banco         = COALESCE(NULLIF(p_datos->>'banco', ''), banco),
      titular       = COALESCE(NULLIF(p_datos->>'titular', ''), titular),
      cuit_titular  = COALESCE(NULLIF(p_datos->>'cuit_titular', ''), cuit_titular),
      fecha_emision = COALESCE(NULLIF(p_datos->>'fecha_emision','')::date, fecha_emision),
      fecha_vcto    = COALESCE(NULLIF(p_datos->>'fecha_vcto','')::date, fecha_vcto),
      monto         = COALESCE(NULLIF(p_datos->>'monto','')::numeric, monto),
      observaciones = COALESCE(NULLIF(p_datos->>'observaciones', ''), observaciones),
      updated_at    = NOW()
    WHERE id = p_id
    RETURNING * INTO v_chq;
  END IF;

  SELECT nombre INTO v_nom FROM clientes_cuenta2 WHERE id = v_chq.cliente_id;
  v_obs := 'Transferido desde Cuenta 2 (cheque #' || v_chq.id || ')'
        || COALESCE(' — recibido de ' || v_nom, '')
        || COALESCE(E'\n' || v_chq.observaciones, '');

  INSERT INTO cheques
    (numero, tipo, banco, titular, cuit_titular, fecha_emision, fecha_vcto, monto,
     cliente_id, observaciones, estado)
  VALUES
    (v_chq.numero, v_chq.tipo, v_chq.banco, v_chq.titular, v_chq.cuit_titular,
     v_chq.fecha_emision, v_chq.fecha_vcto, v_chq.monto,
     NULL,                              -- el cliente de Cuenta 2 no existe en `clientes`
     v_obs, 'en_cartera')
  RETURNING * INTO v_new;

  UPDATE cuenta2_cheques
     SET estado = 'transferido_c1', cheque_id = v_new.id, updated_at = NOW()
   WHERE id = p_id;

  RETURN v_new;
END;
$$;

-- ──────────────────────────────────────────────────────────────
-- anular_cheque_cuenta2 — baja lógica de un cheque de la cartera C2 (rechazo, error de carga).
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION anular_cheque_cuenta2(p_id integer)
RETURNS cuenta2_cheques
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_chq cuenta2_cheques;
BEGIN
  SELECT * INTO v_chq FROM cuenta2_cheques WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cheque de Cuenta 2 no encontrado.';
  END IF;
  IF v_chq.estado = 'transferido_c1' THEN
    RAISE EXCEPTION 'El cheque ya fue transferido a Cuenta 1; anularlo se hace en la cartera oficial.';
  END IF;

  UPDATE cuenta2_cheques SET estado = 'anulado', updated_at = NOW()
  WHERE id = p_id
  RETURNING * INTO v_chq;
  RETURN v_chq;
END;
$$;

-- ── Permisos: solo staff autenticado puede ejecutar las RPC ────
-- OJO: hay que revocar de `anon` explícitamente, no solo de PUBLIC (ver el comentario largo en
-- 20260727120003_rpc_presupuestos.sql). Los helpers internos además se revocan de
-- `authenticated`: no son endpoints y el advisor los marca si quedan ejecutables.
REVOKE ALL ON FUNCTION crm_calc_totales_cuenta2(jsonb, numeric)              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_insert_cuenta2_remito_items(integer, jsonb)       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_check_entidad_cuenta2(varchar, integer)           FROM PUBLIC, anon, authenticated;

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'crear_remito_cuenta2','actualizar_remito_cuenta2','eliminar_remito_cuenta2',
      'registrar_movimiento_cuenta2','eliminar_movimiento_cuenta2',
      'transferir_cheque_cuenta2_a_cuenta1','anular_cheque_cuenta2'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated;', r.sig);
  END LOOP;
END $$;
