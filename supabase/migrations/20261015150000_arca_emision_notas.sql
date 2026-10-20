-- =============================================================
-- ARCA — emisión de Notas de Crédito y Débito A/B (PLAN_ARCA.md §4, Fase 4)
--
-- Igual que la factura en la Fase 3: la nota nace como borrador, sin número fiscal, y recién
-- cuenta cuando ARCA le da su propio CAE. arca_registrar_cae (20261015120002) le pone número y, en
-- la misma transacción, bloquea la factura asociada y recalcula su saldo. La emisión, la
-- reconciliación, CbtesAsoc y el control de letra ya cubren las notas (Fases 2 y 3); saldos,
-- informes y asientos ya filtran estado_fiscal también para ellas (20261015130000).
--
-- 1) crear_nota → borrador, sólo sobre una factura fiscal (autorizada o histórica).
-- 2) actualizar_nota y nota_borrador_descartar, sólo para lo que no se emitió.
-- 3) factura_anular: no anula una factura con notas sin emitir.
--
-- Una NC/ND sobre una factura histórica (PV 00002, web de ARCA) se emite igual; esa factura se
-- verifica a mano en la web de ARCA cuando haga falta: FECompConsultar no responde para ese PV
-- (11002, §4). Los contadores nota_credito/nota_debito (y sus _b) quedan sin uso: el número de
-- una nota lo da ARCA.
-- =============================================================

-- ── 1) Letra de la nota ──────────────────────────────────────────
-- La nota hereda la letra de la factura, pero ARCA la valida contra la condición IVA del cliente
-- al momento de emitirla (CondicionIVAReceptorId de la clase del comprobante, §3.2). Si el cliente
-- cambió de condición desde la factura, la nota rebotaría: se avisa al cargarla.
CREATE FUNCTION crm_validar_letra_nota(p_cliente_id integer, p_letra text)
RETURNS void
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_clase char(1);
  v_cond  text;
BEGIN
  SELECT ci.clase, ci.descripcion INTO v_clase, v_cond
  FROM clientes c JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
  WHERE c.id = p_cliente_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La factura no tiene cliente.';
  END IF;
  IF v_clase <> p_letra THEN
    RAISE EXCEPTION 'La factura es % y el cliente hoy es % (le corresponden comprobantes %): ARCA '
      'rechazaría la nota. Revisá la condición IVA del cliente.', p_letra, v_cond, v_clase;
  END IF;
END;
$$;

-- ── 2) crear_nota → borrador ─────────────────────────────────────
-- Misma firma que 20261006140002. Cambia lo fiscal:
--   · nace `borrador`, sin número (ya no usa siguiente_numero) y con la fecha de hoy en Argentina;
--     al emitir, arca_reclamar_serie la vuelve a poner con la fecha del envío;
--   · sólo sobre una factura con CAE o histórica: ARCA exige el comprobante asociado (CbtesAsoc) y
--     una factura sin emitir todavía no tiene número;
--   · no recalcula el saldo de la factura: lo hace arca_registrar_cae al autorizar la nota;
--   · los ítems se redondean a la escala de sus columnas antes de calcular (20261015140000).
-- La factura se lee FOR SHARE: factura_anular la bloquea antes de buscar notas sin emitir, así
-- que no puede anularse mientras se le está creando una.
CREATE OR REPLACE FUNCTION crear_nota(
  p_factura_id integer, p_tipo varchar, p_items jsonb, p_motivo text DEFAULT NULL,
  p_observaciones text DEFAULT NULL, p_percepciones jsonb DEFAULT NULL
)
RETURNS notas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_fac  facturas;
  v_tot  jsonb;
  v_perc jsonb;
  v_nota notas;
BEGIN
  IF p_factura_id IS NULL THEN
    RAISE EXCEPTION 'La factura de referencia es obligatoria.';
  END IF;
  IF p_tipo NOT IN ('NC','ND') THEN
    RAISE EXCEPTION 'Tipo inválido (NC o ND).';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_fac FROM facturas WHERE id = p_factura_id FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura no encontrada';
  END IF;
  IF v_fac.estado_fiscal NOT IN ('historico','autorizado') THEN
    RAISE EXCEPTION '%', CASE v_fac.estado_fiscal
      WHEN 'borrador'   THEN 'La factura todavía no se emitió: emitila en ARCA antes de hacerle una nota.'
      WHEN 'rechazado'  THEN 'ARCA rechazó la factura: corregila y emitila antes de hacerle una nota.'
      WHEN 'en_proceso' THEN 'La factura se está emitiendo: esperá a que tenga CAE para hacerle una nota.'
      ELSE                   'La factura tiene un resultado incierto en ARCA: consultá el estado antes de hacerle una nota.'
    END;
  END IF;
  IF v_fac.estado = 'anulada' THEN
    RAISE EXCEPTION 'No se puede crear nota sobre una factura anulada.';
  END IF;
  PERFORM crm_validar_letra_nota(v_fac.cliente_id, v_fac.tipo);

  -- Los totales salen de los ítems tal como se guardan.
  p_items := crm_items_normalizados(p_items);

  v_tot  := crm_calc_totales_multi_alicuota(p_items, 0);
  -- Una nota con percepciones se guarda, pero arca_comprobante_para_emitir no la deja emitir
  -- todavía (§3.3).
  v_perc := crm_calc_percepciones(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  INSERT INTO notas
    (tipo, tipo_letra, fecha, factura_id, cliente_id, motivo,
     subtotal, descuento_monto, neto_gravado, iva_monto, percepciones_monto, total,
     estado_fiscal, observaciones)
  VALUES
    (p_tipo, v_fac.tipo, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date,
     p_factura_id, v_fac.cliente_id, p_motivo,
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric, (v_tot->>'neto_gravado')::numeric,
     (v_tot->>'iva_monto')::numeric,
     (v_perc->>'total')::numeric,
     round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
     'borrador', p_observaciones)
  RETURNING * INTO v_nota;

  PERFORM crm_insert_nota_items(v_nota.id, p_items);
  PERFORM crm_insert_percepciones(NULL, v_nota.id, v_perc->'detalle');

  RETURN v_nota;
END;
$$;

-- ── 3) Edición y descarte ────────────────────────────────────────
-- Como actualizar_factura: sólo lo que todavía no se emitió (borrador o rechazado). Guardar un
-- rechazado lo vuelve a borrador (el rechazo queda en arca_solicitudes). El tipo (NC/ND) y la
-- factura no cambian: para eso se descarta la nota y se crea otra.
CREATE FUNCTION actualizar_nota(
  p_id integer, p_items jsonb, p_motivo text DEFAULT NULL,
  p_observaciones text DEFAULT NULL, p_percepciones jsonb DEFAULT NULL
)
RETURNS notas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur  notas;
  v_tot  jsonb;
  v_perc jsonb;
  v_nota notas;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_cur FROM notas WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota no encontrada';
  END IF;
  IF v_cur.estado_fiscal NOT IN ('borrador','rechazado') THEN
    RAISE EXCEPTION '%', CASE v_cur.estado_fiscal
      WHEN 'autorizado'         THEN 'La nota ya tiene CAE: no se puede modificar.'
      WHEN 'en_proceso'         THEN 'La nota se está emitiendo: no se puede modificar.'
      WHEN 'resultado_incierto' THEN 'La nota tiene un resultado incierto en ARCA: consultá el estado antes de modificarla.'
      ELSE                           'Es un comprobante histórico: no se puede modificar.'
    END;
  END IF;
  -- La condición IVA del cliente pudo cambiar desde que se cargó la nota.
  PERFORM crm_validar_letra_nota(v_cur.cliente_id, v_cur.tipo_letra);

  p_items := crm_items_normalizados(p_items);

  v_tot  := crm_calc_totales_multi_alicuota(p_items, 0);
  -- NULL ⇒ sin percepciones: editar sin mandarlas las quita, igual que en actualizar_factura.
  v_perc := crm_calc_percepciones(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  UPDATE notas SET
    motivo             = p_motivo,
    subtotal           = (v_tot->>'subtotal')::numeric,
    descuento_monto    = (v_tot->>'descuento_monto')::numeric,
    neto_gravado       = (v_tot->>'neto_gravado')::numeric,
    iva_monto          = (v_tot->>'iva_monto')::numeric,
    percepciones_monto = (v_perc->>'total')::numeric,
    total              = round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
    observaciones      = p_observaciones,
    estado_fiscal      = 'borrador'
  WHERE id = p_id
  RETURNING * INTO v_nota;

  DELETE FROM nota_items WHERE nota_id = p_id;
  PERFORM crm_insert_nota_items(p_id, p_items);

  DELETE FROM percepciones WHERE nota_id = p_id;
  PERFORM crm_insert_percepciones(NULL, p_id, v_perc->'detalle');

  RETURN v_nota;
END;
$$;

-- Borra una nota que nunca llegó a ARCA (borrador o rechazada) con sus ítems y percepciones. No
-- toca lo que está en emisión o incierto: ARCA pudo haberlo autorizado. Si hubo intentos, el
-- rastro queda en arca_solicitudes.
CREATE FUNCTION nota_borrador_descartar(p_id integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_fiscal text;
BEGIN
  SELECT estado_fiscal INTO v_fiscal FROM notas WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota no encontrada';
  END IF;
  IF v_fiscal NOT IN ('borrador','rechazado') THEN
    RAISE EXCEPTION '%', CASE v_fiscal
      WHEN 'autorizado'         THEN 'La nota ya tiene CAE: no se puede descartar.'
      WHEN 'en_proceso'         THEN 'La nota se está emitiendo: no se puede descartar.'
      WHEN 'resultado_incierto' THEN 'La nota tiene un resultado incierto en ARCA: consultá el estado antes de descartarla.'
      ELSE                           'Es un comprobante histórico: no se descarta.'
    END;
  END IF;

  DELETE FROM percepciones WHERE nota_id = p_id;
  DELETE FROM nota_items   WHERE nota_id = p_id;
  DELETE FROM notas        WHERE id = p_id;
END;
$$;

-- ── 4) factura_anular ────────────────────────────────────────────
-- Misma firma y cuerpo que 20261015130000, más un control: una factura (histórica) con notas sin
-- CAE no se anula. Si no, la nota se podría emitir después contra una factura anulada. La fila se
-- bloquea antes de buscar las notas (crear_nota la lee FOR SHARE): una nota que se está creando
-- termina antes del control o encuentra la factura ya anulada.
CREATE OR REPLACE FUNCTION factura_anular(p_id integer)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_fac    facturas;
  v_fiscal text;
  v_nota   record;
BEGIN
  SELECT estado_fiscal INTO v_fiscal FROM facturas WHERE id = p_id FOR UPDATE;
  IF v_fiscal = 'autorizado' THEN
    RAISE EXCEPTION 'ARCA no permite anular una factura autorizada: emití una Nota de Crédito.';
  ELSIF v_fiscal IN ('borrador','rechazado') THEN
    RAISE EXCEPTION 'La factura no se emitió: descartá el borrador.';
  ELSIF v_fiscal IN ('en_proceso','resultado_incierto') THEN
    RAISE EXCEPTION 'La factura se está emitiendo o tiene un resultado incierto en ARCA: no se puede anular.';
  END IF;

  SELECT n.id, n.tipo, n.estado_fiscal INTO v_nota
  FROM notas n
  WHERE n.factura_id = p_id AND n.estado_fiscal NOT IN ('historico','autorizado')
  ORDER BY n.id LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'La factura tiene una % sin CAE (id %, %): emitila o descartala antes de anular la factura.',
      v_nota.tipo, v_nota.id, v_nota.estado_fiscal;
  END IF;

  UPDATE facturas SET estado = 'anulada', updated_at = NOW()
  WHERE id = p_id AND estado = 'pendiente' AND estado_fiscal = 'historico'
  RETURNING * INTO v_fac;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura no encontrada o no se puede anular.';
  END IF;

  UPDATE remitos SET estado = 'pendiente', factura_id = NULL, updated_at = NOW()
  WHERE factura_id = p_id;

  RETURN v_fac;
END;
$$;

-- ── Permisos ─────────────────────────────────────────────────────
-- crear_nota y factura_anular conservan sus grants. Las nuevas: REVOKE explícito (los DEFAULT
-- PRIVILEGES de Supabase le dan EXECUTE a anon y authenticated a toda función nueva).
REVOKE ALL ON FUNCTION crm_validar_letra_nota(integer, text)                      FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION actualizar_nota(integer, jsonb, text, text, jsonb)         FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION actualizar_nota(integer, jsonb, text, text, jsonb)      TO authenticated;

REVOKE ALL ON FUNCTION nota_borrador_descartar(integer)                           FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION nota_borrador_descartar(integer)                        TO authenticated;
