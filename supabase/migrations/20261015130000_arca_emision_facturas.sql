-- =============================================================
-- ARCA — emisión de Factura A/B (PLAN_ARCA.md §4, Fase 3)
--
-- La factura nace como borrador, sin número fiscal, y recién cuenta para el negocio cuando ARCA le
-- da el CAE: arca_registrar_cae (20261015120002) le pone número, marca los remitos facturados, el
-- presupuesto convertido y genera el asiento, todo en una transacción. Hasta entonces no suma a
-- saldos, cuenta corriente, informes ni contabilidad, y no se le imputan cobros.
--
-- 1) Totales: el neto es la suma de las bases por alícuota ya redondeadas, como exige ARCA.
-- 2) crear_factura → borrador; actualizar_factura, factura_anular y el descarte según estado_fiscal.
-- 3) Remitos tomados por un borrador: no se editan ni se anulan.
-- 4) Cobros y saldos: crear_recibo y recalcular_estado_factura, sólo con comprobantes fiscales.
-- 5) Asientos: el trigger y la generación masiva saltean lo que no está autorizado.
-- 6) Lecturas: saldos e informes filtran estado_fiscal IN ('historico','autorizado').
-- 7) arca_para_reconciliar: lo que la Edge Function compara contra FECompConsultar.
--
-- "Fiscal" = historico (cargado antes del CRM fiscal) o autorizado (con CAE). Las notas siguen
-- naciendo `historico` hasta la Fase 4, pero las lecturas ya las filtran igual: así no hay que
-- reescribirlas otra vez.
-- =============================================================

-- ── 1) Totales ───────────────────────────────────────────────────
-- Misma firma y cálculo que 20260820120000, salvo el neto: pasa a ser la suma de las bases por
-- alícuota ya redondeadas. ARCA exige ImpNeto + ImpOpEx = Σ BaseImp e ImpTotal = neto + IVA, al
-- centavo. Con una sola alícuota no cambia nada (la base del grupo es el neto entero); con varias,
-- el redondeo por grupo puede mover un centavo. La usan también presupuestos y compras: así un
-- presupuesto y su factura dan el mismo total, y una factura de compra cuadra igual que la armó el
-- sistema del proveedor.
CREATE OR REPLACE FUNCTION crm_calc_totales_multi_alicuota(
  p_items             jsonb,
  p_descuento_general numeric DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_subtotal          numeric := 0;
  v_subtotal_desc     numeric := 0;   -- base descontable: excluye pallet vacío / transporte
  v_desc              numeric := 0;
  v_neto              numeric := 0;
  v_iva               numeric := 0;
  v_detalle           jsonb;
BEGIN
  SELECT
    COALESCE(SUM(neto), 0),
    COALESCE(SUM(neto) FILTER (WHERE NOT excluido), 0)
    INTO v_subtotal, v_subtotal_desc
  FROM (
    SELECT
      (it->>'cantidad')::numeric * (it->>'precio_unitario')::numeric
        * (1 - COALESCE((it->>'descuento_item')::numeric, 0) / 100) AS neto,
      COALESCE((it->>'es_pallet_vacio')::boolean, false)
        OR COALESCE((it->>'es_transporte')::boolean, false) AS excluido
    FROM jsonb_array_elements(p_items) AS it
  ) x;

  v_desc := v_subtotal_desc * (COALESCE(p_descuento_general, 0) / 100);

  -- Desglose por alícuota: cada grupo pasa entero el neto de las líneas excluidas y prorratea el
  -- % del cliente sólo sobre las demás. El neto es la suma de las bases redondeadas.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'alicuota_iva_id', g.alicuota_iva_id,
           'porcentaje',      g.porcentaje,
           'neto_gravado',    round(g.neto_grp, 2),
           'iva_monto',       round(g.neto_grp * g.porcentaje / 100, 2)
         ) ORDER BY g.porcentaje), '[]'::jsonb),
         COALESCE(SUM(round(g.neto_grp, 2)), 0),
         COALESCE(SUM(round(g.neto_grp * g.porcentaje / 100, 2)), 0)
    INTO v_detalle, v_neto, v_iva
  FROM (
    SELECT a.id AS alicuota_iva_id, a.porcentaje,
           SUM(
             CASE WHEN x.excluido THEN x.neto
                  ELSE x.neto * (1 - COALESCE(p_descuento_general, 0) / 100)
             END
           ) AS neto_grp
    FROM (
      SELECT
        it,
        (it->>'cantidad')::numeric * (it->>'precio_unitario')::numeric
          * (1 - COALESCE((it->>'descuento_item')::numeric, 0) / 100) AS neto,
        COALESCE((it->>'es_pallet_vacio')::boolean, false)
          OR COALESCE((it->>'es_transporte')::boolean, false) AS excluido
      FROM jsonb_array_elements(p_items) AS it
    ) x
    JOIN alicuotas_iva a
      ON a.id = COALESCE(NULLIF(x.it->>'alicuota_iva_id', '')::int,
                         (SELECT id FROM alicuotas_iva WHERE porcentaje = 21))
    GROUP BY a.id, a.porcentaje
  ) g;

  RETURN jsonb_build_object(
    'subtotal',        round(v_subtotal, 2),
    'descuento_monto', round(v_desc, 2),
    'neto_gravado',    v_neto,
    'iva_monto',       v_iva,
    'total',           v_neto + v_iva,
    'detalle',         v_detalle
  );
END;
$$;

-- ── 2) Facturas: borrador, edición, anulación y descarte ─────────
-- Misma firma que 20261015120001. Cambia lo fiscal:
--   · nace `borrador`, sin número (lo da ARCA al autorizar; ya no usa los contadores factura_a/b);
--   · la fecha es la de hoy en Argentina (CURRENT_DATE es UTC: después de las 21 h da mañana). Al
--     emitir, arca_reclamar_serie la vuelve a poner con la fecha del envío;
--   · los remitos quedan `pendiente` con factura_id cargado y el presupuesto sin convertir: lo hace
--     arca_registrar_cae. Un remito o presupuesto que ya está en otro borrador se rechaza.
CREATE OR REPLACE FUNCTION crear_factura(
  p_cliente_id        integer,
  p_items             jsonb,
  p_tipo              varchar   DEFAULT 'A',
  p_descuento_general numeric   DEFAULT 0,
  p_remito_ids        integer[] DEFAULT NULL,
  p_presupuesto_id    integer   DEFAULT NULL,
  p_observaciones     text      DEFAULT NULL,
  p_percepciones      jsonb     DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_tot      jsonb;
  v_perc     jsonb;
  v_fac      facturas;
  v_iva_alic numeric;
  v_rems     integer[];
  v_cant     integer;
  v_primero  integer;
  v_malo     text;
  v_otra     integer;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;
  IF p_tipo NOT IN ('A','B') THEN
    RAISE EXCEPTION 'Tipo de factura inválido (A o B).';
  END IF;
  PERFORM crm_validar_letra_cliente(p_cliente_id, p_tipo);

  -- Normaliza la lista: sin NULLs y sin repetidos (marcar dos veces el mismo remito
  -- en la grilla no puede contar doble).
  SELECT array_agg(DISTINCT x) INTO v_rems
  FROM unnest(COALESCE(p_remito_ids, ARRAY[]::integer[])) AS x
  WHERE x IS NOT NULL;
  v_rems := COALESCE(v_rems, ARRAY[]::integer[]);
  v_cant := array_length(v_rems, 1);

  IF v_cant > 0 THEN
    -- Un remito inexistente, de otro cliente, ya facturado/anulado o tomado por otro borrador
    -- invalida la factura entera.
    SELECT string_agg(t.detalle, '; ') INTO v_malo
    FROM (
      SELECT CASE
               WHEN r.id IS NULL             THEN 'remito id=' || e.rid || ' inexistente'
               WHEN r.cliente_id <> p_cliente_id THEN 'el remito ' || r.numero || ' es de otro cliente'
               WHEN r.estado <> 'pendiente'  THEN 'el remito ' || r.numero || ' no está pendiente (' || r.estado || ')'
               ELSE 'el remito ' || r.numero || ' ya está en otra factura sin emitir (id ' || r.factura_id || ')'
             END AS detalle
      FROM unnest(v_rems) AS e(rid)
      LEFT JOIN remitos r ON r.id = e.rid
      WHERE r.id IS NULL OR r.cliente_id <> p_cliente_id OR r.estado <> 'pendiente'
         OR r.factura_id IS NOT NULL
    ) t;

    IF v_malo IS NOT NULL THEN
      RAISE EXCEPTION 'No se puede facturar: %.', v_malo;
    END IF;

    SELECT r.id INTO v_primero
    FROM remitos r WHERE r.id = ANY(v_rems)
    ORDER BY r.numero LIMIT 1;
  END IF;

  IF p_presupuesto_id IS NOT NULL THEN
    SELECT f.id INTO v_otra FROM facturas f
    WHERE f.presupuesto_id = p_presupuesto_id
      AND f.estado_fiscal IN ('borrador','en_proceso','resultado_incierto','rechazado')
    LIMIT 1;
    IF v_otra IS NOT NULL THEN
      RAISE EXCEPTION 'El presupuesto ya está en otra factura sin emitir (id %).', v_otra;
    END IF;
  END IF;

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  -- tasa legacy de cabecera: única alícuota → su %; varias → tasa efectiva (iva/neto).
  v_iva_alic := CASE
    WHEN jsonb_array_length(v_tot->'detalle') = 1 THEN (v_tot->'detalle'->0->>'porcentaje')::numeric
    WHEN (v_tot->>'neto_gravado')::numeric > 0
      THEN round((v_tot->>'iva_monto')::numeric / (v_tot->>'neto_gravado')::numeric * 100, 2)
    ELSE 21
  END;

  -- Percepciones sobre el neto gravado ya descontado. Una factura con percepciones se guarda, pero
  -- arca_comprobante_para_emitir no la deja emitir todavía (§3.3).
  v_perc := crm_calc_percepciones(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  INSERT INTO facturas
    (tipo, fecha, cliente_id, remito_id, presupuesto_id,
     descuento_general, subtotal, descuento_monto, neto_gravado, iva_alicuota, iva_monto,
     percepciones_monto, total, estado, estado_fiscal, observaciones)
  VALUES
    (p_tipo, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, p_cliente_id,
     v_primero, p_presupuesto_id, COALESCE(p_descuento_general, 0),
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric, (v_tot->>'neto_gravado')::numeric,
     v_iva_alic, (v_tot->>'iva_monto')::numeric,
     (v_perc->>'total')::numeric,
     round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
     'pendiente', 'borrador', p_observaciones)
  RETURNING * INTO v_fac;

  PERFORM crm_insert_factura_items(v_fac.id, p_items);
  PERFORM crm_insert_percepciones(v_fac.id, NULL, v_perc->'detalle');

  -- Sólo el vínculo: el remito pasa a `facturado` cuando la factura tiene CAE.
  IF v_cant > 0 THEN
    UPDATE remitos SET factura_id = v_fac.id, updated_at = NOW()
    WHERE id = ANY(v_rems);
  END IF;

  RETURN v_fac;
END;
$$;

-- Misma firma y cuerpo que 20261015120001, pero sólo para lo que todavía no se emitió: borrador o
-- rechazado. Un comprobante en emisión, con resultado incierto o con CAE es inmutable. Guardar un
-- rechazado lo vuelve a borrador (el rechazo queda en arca_solicitudes).
CREATE OR REPLACE FUNCTION actualizar_factura(
  p_id integer, p_cliente_id integer, p_items jsonb, p_descuento_general numeric DEFAULT 0,
  p_observaciones text DEFAULT NULL, p_percepciones jsonb DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur      facturas;
  v_tot      jsonb;
  v_perc     jsonb;
  v_fac      facturas;
  v_iva_alic numeric;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_cur FROM facturas WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura no encontrada';
  END IF;
  IF v_cur.estado_fiscal NOT IN ('borrador','rechazado') THEN
    RAISE EXCEPTION '%', CASE v_cur.estado_fiscal
      WHEN 'autorizado'         THEN 'La factura ya tiene CAE: no se puede modificar. Corregila con una Nota de Crédito o Débito.'
      WHEN 'en_proceso'         THEN 'La factura se está emitiendo: no se puede modificar.'
      WHEN 'resultado_incierto' THEN 'La factura tiene un resultado incierto en ARCA: consultá el estado antes de modificarla.'
      ELSE                           'Es un comprobante histórico: no se puede modificar.'
    END;
  END IF;
  PERFORM crm_validar_letra_cliente(p_cliente_id, v_cur.tipo);

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  v_iva_alic := CASE
    WHEN jsonb_array_length(v_tot->'detalle') = 1 THEN (v_tot->'detalle'->0->>'porcentaje')::numeric
    WHEN (v_tot->>'neto_gravado')::numeric > 0
      THEN round((v_tot->>'iva_monto')::numeric / (v_tot->>'neto_gravado')::numeric * 100, 2)
    ELSE 21
  END;

  -- NULL ⇒ se recalculan como vacías y se borra el detalle: editar una factura sin mandar
  -- percepciones las quita, igual que pasa con los ítems (DELETE + re-insert).
  v_perc := crm_calc_percepciones(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  UPDATE facturas SET
    cliente_id         = p_cliente_id,
    descuento_general  = COALESCE(p_descuento_general, 0),
    subtotal           = (v_tot->>'subtotal')::numeric,
    descuento_monto    = (v_tot->>'descuento_monto')::numeric,
    neto_gravado       = (v_tot->>'neto_gravado')::numeric,
    iva_alicuota       = v_iva_alic,
    iva_monto          = (v_tot->>'iva_monto')::numeric,
    percepciones_monto = (v_perc->>'total')::numeric,
    total              = round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
    observaciones      = p_observaciones,
    estado_fiscal      = 'borrador',
    updated_at         = NOW()
  WHERE id = p_id
  RETURNING * INTO v_fac;

  DELETE FROM factura_items WHERE factura_id = p_id;
  PERFORM crm_insert_factura_items(p_id, p_items);

  DELETE FROM percepciones WHERE factura_id = p_id;
  PERFORM crm_insert_percepciones(p_id, NULL, v_perc->'detalle');

  RETURN v_fac;
END;
$$;

-- Misma firma que 20260727120006. Anular sólo aplica a lo histórico: ARCA no permite anular un
-- comprobante autorizado (se corrige con una Nota de Crédito) y lo que no se emitió se descarta.
CREATE OR REPLACE FUNCTION factura_anular(p_id integer)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_fac    facturas;
  v_fiscal text;
BEGIN
  SELECT estado_fiscal INTO v_fiscal FROM facturas WHERE id = p_id;
  IF v_fiscal = 'autorizado' THEN
    RAISE EXCEPTION 'ARCA no permite anular una factura autorizada: emití una Nota de Crédito.';
  ELSIF v_fiscal IN ('borrador','rechazado') THEN
    RAISE EXCEPTION 'La factura no se emitió: descartá el borrador.';
  ELSIF v_fiscal IN ('en_proceso','resultado_incierto') THEN
    RAISE EXCEPTION 'La factura se está emitiendo o tiene un resultado incierto en ARCA: no se puede anular.';
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

-- Borra una factura que nunca llegó a ARCA (borrador o rechazada) con sus ítems y percepciones, y
-- libera sus remitos. No toca lo que está en emisión o incierto: ARCA pudo haberlo autorizado. El
-- rastro queda en audit_log y, si hubo intentos, en arca_solicitudes.
CREATE FUNCTION factura_borrador_descartar(p_id integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_fiscal text;
BEGIN
  SELECT estado_fiscal INTO v_fiscal FROM facturas WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura no encontrada';
  END IF;
  IF v_fiscal NOT IN ('borrador','rechazado') THEN
    RAISE EXCEPTION '%', CASE v_fiscal
      WHEN 'autorizado'         THEN 'La factura ya tiene CAE: no se puede descartar.'
      WHEN 'en_proceso'         THEN 'La factura se está emitiendo: no se puede descartar.'
      WHEN 'resultado_incierto' THEN 'La factura tiene un resultado incierto en ARCA: consultá el estado antes de descartarla.'
      ELSE                           'Es un comprobante histórico: no se descarta.'
    END;
  END IF;

  UPDATE remitos SET factura_id = NULL, updated_at = NOW() WHERE factura_id = p_id;
  DELETE FROM percepciones  WHERE factura_id = p_id;
  DELETE FROM factura_items WHERE factura_id = p_id;
  DELETE FROM facturas      WHERE id = p_id;
END;
$$;

-- ── 3) Remitos tomados por un borrador ───────────────────────────
-- Un remito pendiente con factura_id cargado está en una factura que todavía no tiene CAE: sus
-- ítems ya se copiaron a la factura, así que no se edita ni se anula hasta emitirla o descartarla.

-- Misma firma y cuerpo que 20260727120005, más ese chequeo.
CREATE OR REPLACE FUNCTION remito_anular(p_id integer)
RETURNS remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_rem remitos;
BEGIN
  IF EXISTS (SELECT 1 FROM remitos WHERE id = p_id AND estado = 'pendiente' AND factura_id IS NOT NULL) THEN
    RAISE EXCEPTION 'El remito está en una factura sin emitir: emitila o descartala antes de anularlo.';
  END IF;

  UPDATE remitos SET estado = 'anulado', updated_at = NOW()
  WHERE id = p_id AND estado = 'pendiente'
  RETURNING * INTO v_rem;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remito no encontrado o no se puede anular.';
  END IF;
  RETURN v_rem;
END;
$$;

-- Misma firma y cuerpo que 20260820120002, más ese chequeo.
CREATE OR REPLACE FUNCTION actualizar_remito(
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
  IF v_cur.factura_id IS NOT NULL THEN
    RAISE EXCEPTION 'El remito está en una factura sin emitir: emitila o descartala antes de editarlo.';
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

-- ── 4) Cobros y saldos ───────────────────────────────────────────

-- Misma firma y cuerpo que 20261009130000; una factura sin CAE no recibe cobros.
CREATE OR REPLACE FUNCTION crear_recibo(
  p_cliente_id    integer,
  p_medios        jsonb,
  p_factura_ids   jsonb   DEFAULT '[]'::jsonb,
  p_observaciones text    DEFAULT NULL,
  p_numero        varchar DEFAULT NULL
)
RETURNS recibos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num    record;
  v_numero varchar;
  v_pv     CHAR(5);
  v_comp   INTEGER;
  v_recibo recibos;
  v_total  numeric;
  v_bad    text;
  v_fid    integer;
  v_fiscal text;
  v_m      jsonb;
  v_rm_id  integer;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_medios IS NULL OR jsonb_array_length(p_medios) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un medio de pago.';
  END IF;

  SELECT COALESCE(SUM((m->>'monto')::numeric), 0) INTO v_total
  FROM jsonb_array_elements(p_medios) AS m;
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'El total debe ser mayor a cero.';
  END IF;

  SELECT (m->>'tipo') INTO v_bad
  FROM jsonb_array_elements(p_medios) AS m
  WHERE (m->>'tipo') NOT IN ('efectivo','transferencia','cheque','echeq')
  LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Medio de pago inválido: %', v_bad;
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_medios) AS m
    WHERE COALESCE((m->>'monto')::numeric, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'El monto de cada medio debe ser mayor a cero.';
  END IF;

  v_numero := NULLIF(trim(p_numero), '');
  IF v_numero IS NULL THEN
    SELECT * INTO v_num FROM siguiente_numero('recibo');
    v_numero := v_num.numero_formateado;
    v_pv     := v_num.punto_venta;
    v_comp   := v_num.numero;
  ELSE
    IF v_numero !~ '^\d{5}-\d{8}$' THEN
      RAISE EXCEPTION 'El número % no tiene el formato PPPPP-NNNNNNNN (ej. 00001-00004289).', v_numero;
    END IF;
    v_pv   := split_part(v_numero, '-', 1);
    v_comp := split_part(v_numero, '-', 2)::INTEGER;
  END IF;

  BEGIN
    INSERT INTO recibos (numero, punto_venta, numero_comp, fecha, cliente_id, total, observaciones)
    VALUES (v_numero, v_pv, v_comp, CURRENT_DATE, p_cliente_id, v_total, p_observaciones)
    RETURNING * INTO v_recibo;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'El recibo % ya fue emitido.', v_numero;
  END;

  -- Número manual: el contador sigue al talonario y nunca vuelve atrás — cargar un número salteado
  -- (la copia que apareció) no hace que la próxima sugerencia repita hojas ya usadas.
  IF p_numero IS NOT NULL THEN
    UPDATE contadores
       SET ultimo_numero = v_comp,
           punto_venta   = v_pv
     WHERE tipo = 'recibo'
       AND (punto_venta <> v_pv OR ultimo_numero < v_comp);
  END IF;

  FOR v_fid IN SELECT value::integer FROM jsonb_array_elements_text(p_factura_ids) LOOP
    SELECT estado_fiscal INTO v_fiscal FROM facturas
      WHERE id = v_fid AND cliente_id = p_cliente_id AND estado <> 'anulada';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Factura % inválida.', v_fid;
    END IF;
    IF v_fiscal NOT IN ('historico','autorizado') THEN
      RAISE EXCEPTION 'La factura id % todavía no tiene CAE: no se le pueden imputar cobros.', v_fid;
    END IF;
    INSERT INTO recibo_facturas (recibo_id, factura_id) VALUES (v_recibo.id, v_fid);
  END LOOP;

  FOR v_m IN SELECT value FROM jsonb_array_elements(p_medios) LOOP
    INSERT INTO recibo_medios
      (recibo_id, tipo, detalle, numero_cheque, banco, titular, cuit_titular,
       fecha_emision, fecha_vcto, monto)
    VALUES
      (v_recibo.id, v_m->>'tipo', v_m->>'detalle', v_m->>'numero_cheque', v_m->>'banco',
       v_m->>'titular', v_m->>'cuit_titular',
       NULLIF(v_m->>'fecha_emision','')::date, NULLIF(v_m->>'fecha_vcto','')::date,
       (v_m->>'monto')::numeric)
    RETURNING id INTO v_rm_id;

    IF v_m->>'tipo' IN ('cheque','echeq') AND NULLIF(v_m->>'numero_cheque','') IS NOT NULL THEN
      INSERT INTO cheques
        (numero, tipo, banco, titular, cuit_titular, fecha_emision, fecha_vcto, monto, cliente_id, estado)
      VALUES
        (v_m->>'numero_cheque',
         CASE WHEN v_m->>'tipo' = 'cheque' THEN 'fisico' ELSE 'echeq' END,
         v_m->>'banco', v_m->>'titular', v_m->>'cuit_titular',
         NULLIF(v_m->>'fecha_emision','')::date, NULLIF(v_m->>'fecha_vcto','')::date,
         (v_m->>'monto')::numeric, p_cliente_id, 'en_cartera')
      ON CONFLICT DO NOTHING;
    END IF;

    IF v_m->>'tipo' IN ('efectivo','transferencia')
       AND NULLIF(v_m->>'cuenta_bancaria_id','') IS NOT NULL THEN
      PERFORM tes_emitir_cobranza(v_rm_id, NULLIF(v_m->>'cuenta_bancaria_id','')::int);
    END IF;
  END LOOP;

  FOR v_fid IN SELECT value::integer FROM jsonb_array_elements_text(p_factura_ids) LOOP
    PERFORM recalcular_estado_factura(v_fid);
  END LOOP;

  RETURN v_recibo;
END;
$$;

-- Misma firma y cuerpo que 20261006120000; sólo restan las NC fiscales (una NC en borrador no
-- ajusta el saldo hasta tener CAE).
CREATE OR REPLACE FUNCTION recalcular_estado_factura(p_factura_id INTEGER)
RETURNS VOID AS $$
DECLARE
  v_total    DECIMAL(14,2);
  v_cobrado  DECIMAL(14,2);
  v_nc_total DECIMAL(14,2);
BEGIN
  SELECT total INTO v_total FROM facturas WHERE id = p_factura_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT COALESCE(SUM(COALESCE(rf.importe,
           (SELECT COALESCE(SUM(rm.monto), 0) FROM recibo_medios rm WHERE rm.recibo_id = rf.recibo_id))), 0)
    INTO v_cobrado
  FROM recibo_facturas rf
  WHERE rf.factura_id = p_factura_id;

  SELECT COALESCE(SUM(total), 0) INTO v_nc_total
  FROM notas WHERE factura_id = p_factura_id AND tipo = 'NC'
    AND estado_fiscal IN ('historico','autorizado');

  v_cobrado := v_cobrado + v_nc_total;

  UPDATE facturas SET
    estado = CASE
      WHEN v_cobrado <= 0              THEN 'pendiente'
      WHEN v_cobrado >= v_total - 0.01 THEN 'cobrada'
      ELSE                                  'parcial'
    END,
    updated_at = NOW()
  WHERE id = p_factura_id AND estado != 'anulada';
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

-- ── 5) Asientos ──────────────────────────────────────────────────
-- Mismo cuerpo que 20260803120000. Lo que no es fiscal no genera asiento: el de un comprobante
-- emitido lo genera arca_registrar_cae al autorizarlo.
CREATE OR REPLACE FUNCTION trg_generar_asiento_venta()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT contabilidad_auto_asientos_on() THEN
    RETURN NULL;                                  -- flag 'off' ⇒ no-op (el caso de hoy)
  END IF;
  IF NEW.estado_fiscal NOT IN ('historico','autorizado') THEN
    RETURN NULL;                                  -- borrador: el asiento va al autorizar
  END IF;
  IF asiento_existe_para(TG_TABLE_NAME::text, NEW.id) THEN
    RETURN NULL;                                  -- idempotente
  END IF;

  IF TG_TABLE_NAME = 'facturas' THEN
    -- Una factura anulada no genera asiento. `notas` no tiene columna estado (no se anulan),
    -- por eso el chequeo va acá adentro y no antes del IF.
    IF NEW.estado = 'anulada' THEN
      RETURN NULL;
    END IF;
    PERFORM generar_asiento_desde_factura(NEW.id);
  ELSE
    PERFORM generar_asiento_desde_nota(NEW.id);
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION generar_asientos_ventas_pendientes(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r            record;
  v_facturas   integer := 0;
  v_notas      integer := 0;
BEGIN
  FOR r IN
    SELECT f.id FROM facturas f
    WHERE f.estado <> 'anulada'
      AND f.estado_fiscal IN ('historico','autorizado')
      AND (p_desde IS NULL OR f.fecha >= p_desde)
      AND (p_hasta IS NULL OR f.fecha <= p_hasta)
      AND NOT asiento_existe_para('facturas', f.id)
    ORDER BY f.fecha, f.id
  LOOP
    PERFORM generar_asiento_desde_factura(r.id);
    v_facturas := v_facturas + 1;
  END LOOP;

  -- notas no tiene columna `estado` (no se anulan en este esquema): sin filtro de estado.
  FOR r IN
    SELECT n.id FROM notas n
    WHERE n.estado_fiscal IN ('historico','autorizado')
      AND (p_desde IS NULL OR n.fecha >= p_desde)
      AND (p_hasta IS NULL OR n.fecha <= p_hasta)
      AND NOT asiento_existe_para('notas', n.id)
    ORDER BY n.fecha, n.id
  LOOP
    PERFORM generar_asiento_desde_nota(r.id);
    v_notas := v_notas + 1;
  END LOOP;

  RETURN jsonb_build_object('facturas', v_facturas, 'notas', v_notas);
END;
$$;

-- ── 6) Lecturas ──────────────────────────────────────────────────
-- Mismas firmas y cuerpos que la última versión de cada una (CREATE OR REPLACE conserva los
-- grants), más el filtro fiscal donde se suman saldos o importes. facturas_list y notas_list siguen
-- mostrando todo: son donde se ven los borradores.

-- 20261015120001
CREATE OR REPLACE FUNCTION clientes_list(
  p_q text DEFAULT NULL, p_activo boolean DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.*, ci.descripcion AS condicion_iva, ci.clase,
      COALESCE(SUM(f.total) FILTER (WHERE f.estado <> 'anulada'), 0)               AS total_facturado,
      COALESCE(SUM(f.total) FILTER (WHERE f.estado IN ('pendiente','parcial')), 0) AS saldo_pendiente
    FROM clientes c
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN facturas f ON f.cliente_id = c.id AND f.estado_fiscal IN ('historico','autorizado')
    WHERE (p_q IS NULL OR c.razon_social ILIKE '%'||p_q||'%'
           OR (regexp_replace(p_q, '\D', '', 'g') <> ''
               AND c.doc_nro LIKE '%'||regexp_replace(p_q, '\D', '', 'g')||'%'))
      AND (p_activo IS NULL OR c.activo = p_activo)
    GROUP BY c.id, ci.id
    ORDER BY c.razon_social
  ) t;
$$;

-- 20261015120001
CREATE OR REPLACE FUNCTION informe_ranking_clientes(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.id, c.razon_social, c.doc_tipo, c.doc_nro,
      COUNT(f.id) AS cantidad_facturas, SUM(f.total) AS total_facturado,
      SUM(CASE WHEN f.estado IN ('pendiente','parcial') THEN f.total ELSE 0 END) AS saldo_pendiente,
      MAX(f.fecha) AS ultima_compra
    FROM clientes c
    LEFT JOIN facturas f ON f.cliente_id = c.id AND f.estado <> 'anulada'
      AND f.estado_fiscal IN ('historico','autorizado')
      AND (p_desde IS NULL OR p_hasta IS NULL OR f.fecha BETWEEN p_desde AND p_hasta)
    GROUP BY c.id
    HAVING SUM(f.total) > 0
    ORDER BY SUM(f.total) DESC LIMIT 50
  ) t;
$$;

-- 20261015120001
CREATE OR REPLACE FUNCTION informe_ranking_deudores()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.id, c.razon_social, c.doc_tipo, c.doc_nro, c.telefono, c.email,
      COUNT(f.id) AS facturas_pendientes, SUM(f.total) AS total_pendiente,
      MIN(f.fecha) AS factura_mas_antigua,
      (CURRENT_DATE - MIN(f.fecha)::date) AS dias_deuda
    FROM clientes c
    JOIN facturas f ON f.cliente_id = c.id AND f.estado IN ('pendiente','parcial')
      AND f.estado_fiscal IN ('historico','autorizado')
    GROUP BY c.id
    ORDER BY SUM(f.total) DESC
  ) t;
$$;

-- 20261015120001
CREATE OR REPLACE FUNCTION informe_ventas(
  p_desde date, p_hasta date, p_cliente_id integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'Parámetros desde y hasta son obligatorios.';
  END IF;
  SELECT jsonb_build_object(
    'totales', (SELECT jsonb_build_object(
      'cantidad_facturas', COUNT(f.id),
      'subtotal',          SUM(f.subtotal),
      'descuento_total',   SUM(f.descuento_monto),
      'neto_gravado',      SUM(f.neto_gravado),
      'iva_total',         SUM(f.iva_monto),
      'total_facturado',   SUM(f.total),
      'total_cobrado',     SUM(CASE WHEN f.estado = 'cobrada' THEN f.total ELSE 0 END),
      'total_pendiente',   SUM(CASE WHEN f.estado IN ('pendiente','parcial') THEN f.total ELSE 0 END))
      FROM facturas f
      WHERE f.estado <> 'anulada' AND f.estado_fiscal IN ('historico','autorizado')
        AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)),
    'por_cliente', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT c.id, c.razon_social, c.doc_tipo, c.doc_nro,
        COUNT(f.id) AS cantidad_facturas, SUM(f.total) AS total_facturado,
        SUM(CASE WHEN f.estado IN ('pendiente','parcial') THEN f.total ELSE 0 END) AS pendiente
      FROM facturas f JOIN clientes c ON c.id = f.cliente_id
      WHERE f.estado <> 'anulada' AND f.estado_fiscal IN ('historico','autorizado')
        AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      GROUP BY c.id
      ORDER BY SUM(f.total) DESC) x),
    'por_mes', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT TO_CHAR(f.fecha, 'YYYY-MM') AS mes, COUNT(f.id) AS cantidad, SUM(f.total) AS total
      FROM facturas f
      WHERE f.estado <> 'anulada' AND f.estado_fiscal IN ('historico','autorizado')
        AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      GROUP BY TO_CHAR(f.fecha, 'YYYY-MM') ORDER BY mes) x),
    'por_producto', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT p.codigo, p.descripcion, SUM(fi.cantidad) AS total_cantidad, SUM(fi.subtotal) AS total_neto
      FROM factura_items fi JOIN facturas f ON f.id = fi.factura_id
      LEFT JOIN productos p ON p.id = fi.producto_id
      WHERE f.estado <> 'anulada' AND f.estado_fiscal IN ('historico','autorizado')
        AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      GROUP BY p.codigo, p.descripcion
      ORDER BY SUM(fi.subtotal) DESC LIMIT 20) x)
  ) INTO v;
  RETURN v;
END;
$$;

-- 20261015120001
CREATE OR REPLACE FUNCTION informe_facturas_pendientes_remitir()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT f.id, f.numero, f.fecha, f.total, f.estado, c.razon_social, c.doc_tipo, c.doc_nro,
      (CURRENT_DATE - f.fecha::date) AS dias_pendiente
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    WHERE f.remito_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM remitos rr WHERE rr.factura_id = f.id)
      AND f.estado <> 'anulada'
      AND f.estado_fiscal IN ('historico','autorizado')
    ORDER BY f.fecha ASC
  ) t;
$$;

-- 20261015120001. Sigue listando todo (los borradores se ven acá), salvo dos filtros: el estado de
-- cobranza sólo tiene sentido en una factura fiscal (el ReciboForm pide pendientes y parciales para
-- imputar), y una factura sin CAE no está pendiente de remitir.
CREATE OR REPLACE FUNCTION facturas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL, p_tipo text DEFAULT NULL,
  p_cliente_id integer DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_solo_sin_remito boolean DEFAULT false, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT f.id, count(*) OVER () AS total_filas
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    WHERE (p_id IS NULL OR f.id = p_id)
      AND (p_estado IS NULL OR (f.estado = p_estado AND f.estado_fiscal IN ('historico','autorizado')))
      AND (p_tipo IS NULL OR f.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      AND (p_desde IS NULL OR f.fecha >= p_desde)
      AND (p_hasta IS NULL OR f.fecha <= p_hasta)
      AND (NOT p_solo_sin_remito OR (
             f.remito_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM remitos rr WHERE rr.factura_id = f.id)
             AND f.estado <> 'anulada'
             AND f.estado_fiscal IN ('historico','autorizado')))
      AND (p_q IS NULL OR f.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR (regexp_replace(p_q, '\D', '', 'g') <> ''
                           AND c.doc_nro LIKE '%'||regexp_replace(p_q, '\D', '', 'g')||'%'))
    ORDER BY f.fecha DESC, f.numero DESC, f.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
  SELECT to_jsonb(t) FROM (
    SELECT f.*,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase, c.direccion, c.email, c.telefono,
      COALESCE(r.numero, (SELECT min(rr.numero) FROM remitos rr WHERE rr.factura_id = f.id))
        AS remito_numero,
      (SELECT json_agg(json_build_object('id', rr.id, 'numero', rr.numero) ORDER BY rr.numero)
         FROM remitos rr WHERE rr.factura_id = f.id) AS remitos,
      (SELECT json_agg(json_build_object(
                'id', pc.id, 'tipo_percepcion', pc.tipo_percepcion, 'jurisdiccion', pc.jurisdiccion,
                'base_imponible', pc.base_imponible, 'alicuota', pc.alicuota, 'monto', pc.monto
              ) ORDER BY pc.tipo_percepcion, pc.jurisdiccion)
         FROM percepciones pc WHERE pc.factura_id = f.id) AS percepciones,
      p.numero AS presupuesto_numero,
      json_agg(json_build_object(
        'id', fi.id, 'producto_id', fi.producto_id, 'codigo', pr.codigo, 'descripcion', fi.descripcion,
        'cantidad', fi.cantidad, 'precio_unitario', fi.precio_unitario,
        'descuento_item', fi.descuento_item, 'subtotal', fi.subtotal, 'orden', fi.orden,
        'alicuota_iva_id', fi.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', fi.pallets, 'unidades_por_pallet', fi.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
      ) ORDER BY fi.orden) FILTER (WHERE fi.id IS NOT NULL) AS items,
      pg.total_filas
    FROM pagina pg
    JOIN facturas f ON f.id = pg.id
    JOIN clientes c ON c.id = f.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN remitos r ON r.id = f.remito_id
    LEFT JOIN presupuestos p ON p.id = f.presupuesto_id
    LEFT JOIN factura_items fi ON fi.factura_id = f.id
    LEFT JOIN productos pr ON pr.id = fi.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = fi.alicuota_iva_id
    GROUP BY f.id, c.id, ci.id, r.numero, p.numero, pg.total_filas
    ORDER BY f.fecha DESC, f.numero DESC, f.id DESC
  ) t;
$$;

-- 20261015120001. El libro IVA es exactamente lo que se informó a ARCA (o lo histórico).
CREATE OR REPLACE FUNCTION informe_libro_iva_ventas(p_desde date, p_hasta date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'Parámetros desde y hasta son obligatorios.';
  END IF;

  WITH libro AS (
    SELECT f.id, f.fecha, 'FAC'::text AS comprobante, f.tipo::text AS letra,
      f.punto_venta, f.numero_comp, f.numero,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      f.estado = 'anulada' AS anulada,
      f.neto_gravado, f.iva_monto, COALESCE(f.percepciones_monto, 0) AS percepciones_monto, f.total
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    WHERE f.fecha BETWEEN p_desde AND p_hasta
      AND f.estado_fiscal IN ('historico','autorizado')
    UNION ALL
    SELECT n.id, n.fecha, n.tipo::text, n.tipo_letra::text,
      n.punto_venta, n.numero_comp, n.numero,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion,
      n.total = 0 AS anulada,
      s.signo * n.neto_gravado, s.signo * n.iva_monto,
      s.signo * COALESCE(n.percepciones_monto, 0), s.signo * n.total
    FROM notas n
    JOIN clientes c ON c.id = n.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    CROSS JOIN LATERAL (SELECT CASE WHEN n.tipo = 'NC' THEN -1 ELSE 1 END AS signo) s
    WHERE n.fecha BETWEEN p_desde AND p_hasta
      AND n.estado_fiscal IN ('historico','autorizado')
  )
  SELECT jsonb_build_object(
    'comprobantes', (SELECT COALESCE(jsonb_agg(to_jsonb(l)
                       ORDER BY l.fecha, l.punto_venta, l.comprobante, l.letra, l.numero_comp), '[]')
                     FROM libro l),
    -- Una fila por comprobante y letra (FAC A, FAC B, NC A, …) para el resumen del libro.
    'resumen', (SELECT COALESCE(jsonb_agg(r ORDER BY r.comprobante, r.letra), '[]') FROM (
      SELECT comprobante, letra, COUNT(*) AS cantidad,
        SUM(neto_gravado) AS neto_gravado, SUM(iva_monto) AS iva_monto,
        SUM(percepciones_monto) AS percepciones_monto, SUM(total) AS total
      FROM libro GROUP BY comprobante, letra
    ) r),
    'totales', (SELECT jsonb_build_object(
      'cantidad',           COUNT(*),
      'neto_gravado',       COALESCE(SUM(neto_gravado), 0),
      'iva_monto',          COALESCE(SUM(iva_monto), 0),
      'percepciones_monto', COALESCE(SUM(percepciones_monto), 0),
      'total',              COALESCE(SUM(total), 0))
      FROM libro)
  ) INTO v;
  RETURN v;
END;
$$;

-- 20261015120001
CREATE OR REPLACE FUNCTION informe_cta_cte(
  p_cliente_id integer, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_cli      jsonb;
  v_movs     jsonb;
  v_anterior numeric;
  v_saldo    numeric;
BEGIN
  SELECT to_jsonb(c) || jsonb_build_object('condicion_iva', ci.descripcion, 'clase', ci.clase)
    INTO v_cli
  FROM clientes c JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
  WHERE c.id = p_cliente_id;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'Cliente no encontrado';
  END IF;

  WITH movs AS (
    SELECT f.id, f.fecha, f.numero AS comprobante, 'FACTURA'::text AS tipo,
           f.total AS debe, 0::numeric AS haber
    FROM facturas f
    WHERE f.cliente_id = p_cliente_id AND f.estado <> 'anulada'
      AND f.estado_fiscal IN ('historico','autorizado')
    UNION ALL
    SELECT r.id, r.fecha, r.numero, 'RECIBO', 0::numeric, r.total
    FROM recibos r
    WHERE r.cliente_id = p_cliente_id
    UNION ALL
    SELECT n.id, n.fecha, n.numero, 'NOTA CRED.', 0::numeric, n.total
    FROM notas n LEFT JOIN facturas f ON f.id = n.factura_id
    WHERE COALESCE(n.cliente_id, f.cliente_id) = p_cliente_id AND n.tipo = 'NC'
      AND n.estado_fiscal IN ('historico','autorizado')
    UNION ALL
    SELECT n.id, n.fecha, n.numero, 'NOTA DEB.', n.total, 0::numeric
    FROM notas n LEFT JOIN facturas f ON f.id = n.factura_id
    WHERE COALESCE(n.cliente_id, f.cliente_id) = p_cliente_id AND n.tipo = 'ND'
      AND n.estado_fiscal IN ('historico','autorizado')
  ),
  anterior AS (
    SELECT COALESCE(SUM(m.debe - m.haber), 0) AS saldo
    FROM movs m WHERE p_desde IS NOT NULL AND m.fecha < p_desde
  ),
  ordered AS (
    SELECT m.*,
      (SELECT saldo FROM anterior) + SUM(m.debe - m.haber) OVER (
        ORDER BY m.fecha ASC, m.comprobante ASC, m.tipo ASC, m.id ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS saldo
    FROM movs m
    WHERE (p_desde IS NULL OR m.fecha >= p_desde)
      AND (p_hasta IS NULL OR m.fecha <= p_hasta)
  )
  SELECT
    COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.fecha, o.comprobante, o.tipo, o.id), '[]'),
    (SELECT saldo FROM anterior),
    (SELECT saldo FROM anterior) + COALESCE(SUM(o.debe - o.haber), 0)
  INTO v_movs, v_anterior, v_saldo
  FROM ordered o;

  IF p_desde IS NOT NULL THEN
    v_movs := jsonb_build_array(jsonb_build_object(
      'id', NULL, 'fecha', p_desde, 'comprobante', '—', 'tipo', 'SALDO ANTERIOR',
      'debe', 0, 'haber', 0, 'saldo', v_anterior)) || v_movs;
  END IF;

  RETURN jsonb_build_object(
    'cliente', v_cli, 'movimientos', v_movs, 'saldo_total', v_saldo,
    'saldo_anterior', v_anterior, 'desde', p_desde, 'hasta', p_hasta);
END;
$$;

-- 20261009120000
CREATE OR REPLACE FUNCTION informe_dashboard()
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  -- Saldo de cada factura impaga. `rf.importe` NULL = imputación vieja de un recibo a una sola
  -- factura: cuenta el recibo entero (igual que recalcular_estado_factura).
  WITH saldos AS (
    SELECT f.id, f.cliente_id,
      GREATEST(f.total
        - COALESCE((SELECT SUM(COALESCE(rf.importe,
              (SELECT COALESCE(SUM(rm.monto), 0) FROM recibo_medios rm WHERE rm.recibo_id = rf.recibo_id)))
            FROM recibo_facturas rf WHERE rf.factura_id = f.id), 0)
        - COALESCE((SELECT SUM(n.total) FROM notas n WHERE n.factura_id = f.id AND n.tipo = 'NC'
                      AND n.estado_fiscal IN ('historico','autorizado')), 0),
        0) AS saldo
    FROM facturas f
    WHERE f.estado IN ('pendiente','parcial') AND f.estado_fiscal IN ('historico','autorizado')
  )
  SELECT jsonb_build_object(
    'kpis', jsonb_build_object(
      'total_clientes',       (SELECT COUNT(*) FROM clientes WHERE activo),
      'total_productos',      (SELECT COUNT(*) FROM productos WHERE activo),
      'total_por_cobrar',     (SELECT COALESCE(SUM(saldo),0) FROM saldos),
      'remitos_pendientes',   (SELECT COUNT(*) FROM remitos WHERE estado = 'pendiente'),
      'presupuestos_activos', (SELECT COUNT(*) FROM presupuestos WHERE estado IN ('borrador','enviado')),
      'cheques_vencidos',     (SELECT COUNT(*) FROM cheques WHERE estado = 'en_cartera' AND fecha_vcto < CURRENT_DATE)
    ),
    'ultimas_facturas', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT f.id, f.numero, f.fecha, f.total, f.estado, f.tipo, c.razon_social
      FROM facturas f JOIN clientes c ON c.id = f.cliente_id
      WHERE f.estado <> 'anulada' AND f.estado_fiscal IN ('historico','autorizado')
      ORDER BY f.fecha DESC, f.numero DESC, f.id DESC LIMIT 8) x),
    'top_deudores', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT c.id, c.razon_social, SUM(s.saldo) AS saldo_pendiente
      FROM clientes c JOIN saldos s ON s.cliente_id = c.id
      GROUP BY c.id, c.razon_social
      HAVING SUM(s.saldo) > 0
      ORDER BY SUM(s.saldo) DESC LIMIT 5) x),
    'cheques_por_vencer', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT ch.numero, ch.banco, ch.monto, ch.fecha_vcto, ch.estado, c.razon_social AS cliente_razon_social
      FROM cheques ch LEFT JOIN clientes c ON c.id = ch.cliente_id
      WHERE ch.estado = 'en_cartera' AND ch.fecha_vcto BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '7 days'
      ORDER BY ch.fecha_vcto LIMIT 5) x)
  );
$$;

-- ── 7) Reconciliación ────────────────────────────────────────────
-- Lo que la Edge Function compara contra FECompConsultar para un comprobante en_proceso o con
-- resultado incierto: la serie reclamada, el número tentativo y los datos que ARCA devuelve (fecha,
-- total, documento). Sin las validaciones de arca_comprobante_para_emitir, que no deben trabar la
-- reconciliación de algo que ya pudo haberse autorizado.
--
-- `colgado`: la serie está reclamada hace más de 3 minutos, más que lo que puede durar una
-- invocación de la Edge Function. Sólo entonces un en_proceso se trata como interrumpido: antes,
-- todavía puede estar esperando la respuesta de ARCA.
CREATE FUNCTION arca_para_reconciliar(p_tabla text, p_id integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_estado  text;
  v_tent    integer;
  v_fecha   date;
  v_total   numeric;
  v_cliente integer;
  v_serie   arca_series_en_curso;
  v_doc     record;
BEGIN
  IF p_tabla = 'facturas' THEN
    SELECT f.estado_fiscal, f.arca_nro_tentativo, f.fecha, f.total, f.cliente_id
      INTO v_estado, v_tent, v_fecha, v_total, v_cliente
    FROM facturas f WHERE f.id = p_id;
  ELSIF p_tabla = 'notas' THEN
    SELECT n.estado_fiscal, n.arca_nro_tentativo, n.fecha, n.total, COALESCE(n.cliente_id, f.cliente_id)
      INTO v_estado, v_tent, v_fecha, v_total, v_cliente
    FROM notas n LEFT JOIN facturas f ON f.id = n.factura_id WHERE n.id = p_id;
  ELSE
    RAISE EXCEPTION 'Tabla inválida: %', p_tabla;
  END IF;
  IF v_estado IS NULL THEN
    RAISE EXCEPTION 'Comprobante no encontrado';
  END IF;

  SELECT * INTO v_serie FROM arca_series_en_curso WHERE tabla = p_tabla AND comprobante_id = p_id;
  SELECT c.doc_tipo, c.doc_nro INTO v_doc FROM clientes c WHERE c.id = v_cliente;

  RETURN jsonb_build_object(
    'estado_fiscal', v_estado, 'nro_tentativo', v_tent,
    'punto_venta', v_serie.punto_venta, 'cbte_tipo', v_serie.cbte_tipo,
    'colgado', COALESCE(v_serie.reclamada_en < NOW() - interval '3 minutes', false),
    'CbteFch', to_char(v_fecha, 'YYYYMMDD'), 'ImpTotal', v_total,
    'DocTipo', v_doc.doc_tipo, 'DocNro', v_doc.doc_nro);
END;
$$;

-- ── Permisos ─────────────────────────────────────────────────────
-- Las funciones reemplazadas conservan sus grants. Las nuevas: REVOKE explícito (los DEFAULT
-- PRIVILEGES de Supabase le dan EXECUTE a anon y authenticated a toda función nueva).
REVOKE ALL ON FUNCTION factura_borrador_descartar(integer)        FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION factura_borrador_descartar(integer)     TO authenticated;

REVOKE ALL ON FUNCTION arca_para_reconciliar(text, integer)       FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION arca_para_reconciliar(text, integer)    TO service_role;
