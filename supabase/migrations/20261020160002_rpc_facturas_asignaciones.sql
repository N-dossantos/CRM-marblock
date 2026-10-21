-- =============================================================
-- CRM Ventas — remitos contra facturas pendientes de remitir (PLAN_MAESTRO §3.11), 3 de 4:
-- facturas armadas desde remitos (asignaciones 'factura') y su liberación.
--
-- 1) Helpers de escritura, sólo para las RPC:
--    - crm_factura_asignar_remitos: le asigna a la factura lo que le falta facturar a cada renglón
--      de los remitos, hasta la cantidad de la factura en cada producto (origen 'factura');
--    - crm_factura_soltar_remitos: borra las asignaciones a la factura, de cualquier origen, y
--      recalcula los remitos;
--    - crm_remitos_recalcular_de_factura: recalcula los remitos asignados a la factura.
-- 2) crear_factura / actualizar_factura con p_remito_ids: un remito parcial entra con lo que le
--    falta facturar; uno sin nada pendiente se rechaza (E6). El borrador reserva lo asignado, y
--    facturas.remito_id es el primer remito con alguna asignación a la factura.
-- 3) factura_borrador_descartar y factura_anular liberan los remitos; arca_registrar_cae los
--    recalcula (facturado sólo si todo el remito está en facturas con CAE o históricas).
--
-- Sin BEGIN/COMMIT: se ensaya dentro de una transacción (supabase/remitos/ensayo.sql).
-- =============================================================

-- ── 1) Helpers ───────────────────────────────────────────────────

-- Reparte entre los renglones de los remitos la cantidad de la factura: por clave, el tope es lo
-- que la factura tiene de ese producto. Los renglones van por número de remito y orden del renglón,
-- y cada uno se lleva lo que le falta facturar hasta agotar el tope:
--   min(sin facturar, tope − lo que ya se llevaron los anteriores de la misma clave).
-- Lo que no entra queda pendiente de facturar. Supone que la factura no tiene otras asignaciones:
-- es nueva (crear_factura) o actualizar_factura acaba de borrarlas. Un remito anulado no aporta.
-- Al final fija facturas.remito_id (denormalización de compatibilidad, §2.3): el primer remito,
-- por número, que tiene alguna asignación a la factura, o NULL. Un remito que no comparte
-- productos con la factura no recibe nada y no queda como su remito.
CREATE FUNCTION crm_factura_asignar_remitos(p_factura_id integer, p_remito_ids integer[])
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF COALESCE(array_length(p_remito_ids, 1), 0) > 0 THEN
    -- Bloquea los remitos, siempre en el mismo orden. Va en su propia sentencia, antes de leer lo
    -- que les falta facturar: dos facturas armadas a la vez desde el mismo remito no asignan dos
    -- veces lo mismo (la segunda espera y, en READ COMMITTED, la lectura de abajo ve lo que grabó
    -- la primera).
    PERFORM 1 FROM remitos WHERE id = ANY(p_remito_ids) ORDER BY id FOR UPDATE;

    INSERT INTO remito_item_facturas (remito_item_id, factura_id, cantidad, origen)
    SELECT x.remito_item_id, p_factura_id, x.cantidad, 'factura'
    FROM (
      SELECT s.remito_item_id,
             least(s.sin_facturar, greatest(t.tope - COALESCE(sum(s.sin_facturar) OVER (
               PARTITION BY s.clave ORDER BY r.numero, r.id, ri.orden, ri.id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0), 0)) AS cantidad,
             row_number() OVER (ORDER BY r.numero, r.id, ri.orden, ri.id) AS n
      FROM remitos r
      CROSS JOIN LATERAL crm_remito_items_sin_facturar(r.id) s
      JOIN remito_items ri ON ri.id = s.remito_item_id
      JOIN (
        SELECT crm_clave_item(fi.producto_id, fi.descripcion) AS clave, sum(fi.cantidad) AS tope
        FROM factura_items fi
        WHERE fi.factura_id = p_factura_id
        GROUP BY 1
      ) t ON t.clave = s.clave
      WHERE r.id = ANY(p_remito_ids) AND r.estado <> 'anulado' AND s.sin_facturar > 0
    ) x
    WHERE x.cantidad > 0
    ORDER BY x.n;

    PERFORM crm_remito_recalcular(r.id) FROM remitos r WHERE r.id = ANY(p_remito_ids) ORDER BY r.id;
  END IF;

  UPDATE facturas f SET remito_id = x.remito_id
  FROM (SELECT (
    SELECT r.id
    FROM remito_item_facturas a
    JOIN remito_items ri ON ri.id = a.remito_item_id
    JOIN remitos r ON r.id = ri.remito_id
    WHERE a.factura_id = p_factura_id
    ORDER BY r.numero, r.id
    LIMIT 1) AS remito_id) x
  WHERE f.id = p_factura_id AND f.remito_id IS DISTINCT FROM x.remito_id;
END;
$$;

-- Libera los remitos de una factura que se descarta o se anula: borra todas sus asignaciones,
-- de cualquier origen ('factura', 'tango' y también las 'remito' de una factura histórica), y
-- recalcula esos remitos (vuelven a pendiente con lo liberado).
CREATE FUNCTION crm_factura_soltar_remitos(p_factura_id integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_rems integer[];
BEGIN
  SELECT array_agg(DISTINCT ri.remito_id) INTO v_rems
  FROM remito_item_facturas a
  JOIN remito_items ri ON ri.id = a.remito_item_id
  WHERE a.factura_id = p_factura_id;

  DELETE FROM remito_item_facturas WHERE factura_id = p_factura_id;

  PERFORM crm_remito_recalcular(x) FROM unnest(v_rems) AS x ORDER BY x;
END;
$$;

-- Recalcula los remitos con asignaciones a la factura (al registrar el CAE).
CREATE FUNCTION crm_remitos_recalcular_de_factura(p_factura_id integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM crm_remito_recalcular(x.remito_id)
  FROM (
    SELECT DISTINCT ri.remito_id
    FROM remito_item_facturas a
    JOIN remito_items ri ON ri.id = a.remito_item_id
    WHERE a.factura_id = p_factura_id
  ) x
  ORDER BY x.remito_id;
END;
$$;

-- ── 2) crear_factura ─────────────────────────────────────────────
-- Misma firma y cuerpo que 20261015140000. La validación de remitos ya no exige 'pendiente' sin
-- factura_id: rechaza los inexistentes, los de otro cliente y los anulados (mensaje de siempre) y
-- los que no tienen nada sin facturar (E6: ya facturados o reservados por otro borrador). En vez
-- de cargar remitos.factura_id, le asigna a la factura lo que le falta facturar a cada renglón.
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

  -- Los totales salen de los ítems tal como se guardan.
  p_items := crm_items_normalizados(p_items);

  -- Normaliza la lista: sin NULLs y sin repetidos (marcar dos veces el mismo remito
  -- en la grilla no puede contar doble).
  SELECT array_agg(DISTINCT x) INTO v_rems
  FROM unnest(COALESCE(p_remito_ids, ARRAY[]::integer[])) AS x
  WHERE x IS NOT NULL;
  v_rems := COALESCE(v_rems, ARRAY[]::integer[]);
  v_cant := array_length(v_rems, 1);

  IF v_cant > 0 THEN
    -- Bloquea los remitos antes de leer lo que les falta facturar (ver crm_factura_asignar_remitos):
    -- de dos facturas armadas a la vez desde el mismo remito, la segunda espera y ya ve la reserva
    -- de la primera (E6 si no queda nada).
    PERFORM 1 FROM remitos WHERE id = ANY(v_rems) ORDER BY id FOR UPDATE;

    -- Un remito inexistente, de otro cliente o anulado invalida la factura entera.
    SELECT string_agg(t.detalle, '; ') INTO v_malo
    FROM (
      SELECT CASE
               WHEN r.id IS NULL             THEN 'remito id=' || e.rid || ' inexistente'
               WHEN r.cliente_id <> p_cliente_id THEN 'el remito ' || r.numero || ' es de otro cliente'
               ELSE 'el remito ' || r.numero || ' no está pendiente (' || r.estado || ')'
             END AS detalle
      FROM unnest(v_rems) AS e(rid)
      LEFT JOIN remitos r ON r.id = e.rid
      WHERE r.id IS NULL OR r.cliente_id <> p_cliente_id OR r.estado = 'anulado'
    ) t;

    IF v_malo IS NOT NULL THEN
      RAISE EXCEPTION 'No se puede facturar: %.', v_malo;
    END IF;

    -- E6: no le queda nada sin facturar (lo asignado a un borrador cuenta como reservado).
    SELECT r.numero INTO v_malo
    FROM remitos r
    WHERE r.id = ANY(v_rems)
      AND NOT EXISTS (SELECT 1 FROM crm_remito_items_sin_facturar(r.id) s WHERE s.sin_facturar > 0)
    ORDER BY r.numero
    LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El remito % no tiene nada pendiente de facturar.', v_malo;
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

  -- Asignaciones 'factura': el borrador reserva lo que tomó de cada remito, que pasa a `facturado`
  -- cuando la factura tiene CAE (si quedó entero facturado). remito_id arrancó en el primer remito
  -- por número; si ése no recibió nada, crm_factura_asignar_remitos lo corrige.
  IF v_cant > 0 THEN
    PERFORM crm_factura_asignar_remitos(v_fac.id, v_rems);
  END IF;

  RETURN v_fac;
END;
$$;

-- ── actualizar_factura ───────────────────────────────────────────
-- Misma firma y cuerpo que 20261015140000, más las asignaciones: los remitos de los que se armó
-- se vuelven a repartir con los ítems nuevos (si se baja una cantidad, lo demás queda pendiente
-- de facturar) y remito_id pasa al primero que conserva alguna asignación.
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
  v_rems     integer[];
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

  -- Los totales salen de los ítems tal como se guardan.
  p_items := crm_items_normalizados(p_items);

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

  -- Los remitos de los que se armó la factura, antes de cambiar los ítems.
  SELECT array_agg(DISTINCT ri.remito_id) INTO v_rems
  FROM remito_item_facturas a
  JOIN remito_items ri ON ri.id = a.remito_item_id
  WHERE a.factura_id = p_id;

  DELETE FROM factura_items WHERE factura_id = p_id;
  PERFORM crm_insert_factura_items(p_id, p_items);

  DELETE FROM percepciones WHERE factura_id = p_id;
  PERFORM crm_insert_percepciones(p_id, NULL, v_perc->'detalle');

  -- Se vuelven a repartir con los ítems nuevos (recalcula los remitos).
  DELETE FROM remito_item_facturas WHERE factura_id = p_id;
  PERFORM crm_factura_asignar_remitos(p_id, v_rems);

  RETURN v_fac;
END;
$$;

-- ── 3) factura_borrador_descartar ────────────────────────────────
-- Misma firma y cuerpo que 20261015130000. Liberar los remitos ahora es borrar las asignaciones a
-- la factura (de cualquier origen: el backfill dio 'tango' a remitos tomados por un borrador) y
-- recalcularlos. Va antes del DELETE de la factura: remito_item_facturas.factura_id no tiene CASCADE.
CREATE OR REPLACE FUNCTION factura_borrador_descartar(p_id integer)
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

  PERFORM crm_factura_soltar_remitos(p_id);
  DELETE FROM percepciones  WHERE factura_id = p_id;
  DELETE FROM factura_items WHERE factura_id = p_id;
  DELETE FROM facturas      WHERE id = p_id;
END;
$$;

-- ── factura_anular ───────────────────────────────────────────────
-- Misma firma y cuerpo que 20261015150000. Los remitos se liberan borrando todas las asignaciones
-- a la factura, también las 'remito': esos remitos quedan pendientes de facturar.
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

  PERFORM crm_factura_soltar_remitos(p_id);

  RETURN v_fac;
END;
$$;

-- ── arca_registrar_cae ───────────────────────────────────────────
-- Misma firma y cuerpo que 20261015120002. Entre los efectos comerciales de una factura, los
-- remitos ya no pasan a facturado por tener factura_id: se recalculan con sus asignaciones, una vez
-- que la factura quedó autorizada (crm_remito_recalcular sólo cuenta las históricas o con CAE).
CREATE OR REPLACE FUNCTION arca_registrar_cae(
  p_tabla text, p_id integer, p_numero integer, p_cae text, p_vto date,
  p_afip_tipo integer, p_doc_tipo integer, p_doc_nro text,
  p_request jsonb, p_response jsonb, p_observaciones jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_estado  text;
  v_tent    integer;
  v_cae     text;
  v_pv      integer;
  v_numero  text;
  v_motivo  text;
  v_factura integer;
BEGIN
  IF p_tabla NOT IN ('facturas','notas') THEN
    RAISE EXCEPTION 'Tabla inválida: %', p_tabla;
  END IF;

  EXECUTE format('SELECT estado_fiscal, arca_nro_tentativo, cae FROM %I WHERE id = $1 FOR UPDATE', p_tabla)
    INTO v_estado, v_tent, v_cae USING p_id;

  -- La misma respuesta registrada dos veces (reintento de la función): no hay nada que hacer.
  IF v_estado = 'autorizado' AND v_cae = p_cae THEN
    RETURN jsonb_build_object('registrado', true, 'estado_fiscal', v_estado);
  END IF;

  SELECT s.punto_venta INTO v_pv
  FROM arca_series_en_curso s WHERE s.tabla = p_tabla AND s.comprobante_id = p_id;

  IF v_estado IS NULL THEN
    v_motivo := 'el comprobante no existe';
  ELSIF v_estado NOT IN ('en_proceso','resultado_incierto') THEN
    v_motivo := format('el comprobante estaba %s', v_estado);
  ELSIF v_tent IS DISTINCT FROM p_numero THEN
    v_motivo := format('ARCA autorizó el número %s y el tentativo era %s', p_numero, v_tent);
  ELSIF v_pv IS NULL THEN
    v_motivo := 'el comprobante no tenía la serie reclamada';
  ELSE
    v_numero := lpad(v_pv::text, 5, '0') || '-' || lpad(p_numero::text, 8, '0');
    BEGIN
      EXECUTE format($q$
        UPDATE %I SET estado_fiscal = 'autorizado', punto_venta = $2, numero_comp = $3, numero = $4,
          cae = $5, cae_vencimiento = $6, afip_tipo_comprobante = $7, afip_doc_tipo = $8,
          afip_doc_nro = $9, arca_nro_tentativo = NULL
        WHERE id = $1$q$, p_tabla)
        USING p_id, lpad(v_pv::text, 5, '0'), p_numero, v_numero, p_cae, p_vto,
              lpad(p_afip_tipo::text, 3, '0'), p_doc_tipo::text, p_doc_nro;

      DELETE FROM arca_series_en_curso WHERE tabla = p_tabla AND comprobante_id = p_id;

      -- Efectos comerciales, una sola vez y en la misma transacción (§4).
      IF p_tabla = 'facturas' THEN
        PERFORM crm_remitos_recalcular_de_factura(p_id);
        UPDATE presupuestos p SET estado = 'convertido', updated_at = NOW()
        FROM facturas f
        WHERE f.id = p_id AND p.id = f.presupuesto_id AND p.estado <> 'convertido';
      ELSE
        -- La nota ajusta el saldo de su factura recién al autorizarse; la fila de la factura se
        -- bloquea para no perder actualizaciones entre notas concurrentes.
        SELECT factura_id INTO v_factura FROM notas WHERE id = p_id;
        IF v_factura IS NOT NULL THEN
          PERFORM 1 FROM facturas WHERE id = v_factura FOR UPDATE;
          PERFORM recalcular_estado_factura(v_factura);
        END IF;
      END IF;

      IF contabilidad_auto_asientos_on() AND NOT asiento_existe_para(p_tabla, p_id) THEN
        IF p_tabla = 'facturas' THEN
          PERFORM generar_asiento_desde_factura(p_id);
        ELSE
          PERFORM generar_asiento_desde_nota(p_id);
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_motivo := SQLERRM;
      v_numero := NULL;
    END;
  END IF;

  INSERT INTO arca_solicitudes (tabla, comprobante_id, resultado, request, response, observaciones, errores)
  VALUES (p_tabla, p_id, 'autorizado', p_request, p_response, p_observaciones,
          CASE WHEN v_motivo IS NOT NULL THEN jsonb_build_array(jsonb_build_object(
            'Msg', format('ARCA otorgó el CAE %s (N° %s) pero el CRM no pudo registrarlo: %s',
                          p_cae, p_numero, v_motivo))) END);

  RETURN jsonb_build_object(
    'registrado', v_motivo IS NULL,
    'estado_fiscal', CASE WHEN v_motivo IS NULL THEN 'autorizado' ELSE v_estado END,
    'numero', v_numero, 'motivo', v_motivo);
END;
$$;

-- ── Permisos ─────────────────────────────────────────────────────
-- REVOKE explícito en las nuevas: los DEFAULT PRIVILEGES de Supabase le dan EXECUTE a anon y
-- authenticated a toda función nueva. Las tres escriben: sólo desde otras RPC.
REVOKE ALL ON FUNCTION crm_factura_asignar_remitos(integer, integer[])  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_factura_soltar_remitos(integer)              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_remitos_recalcular_de_factura(integer)       FROM PUBLIC, anon, authenticated;

-- Las reemplazadas conservan sus grants; se reafirman por la convención del proyecto.
REVOKE ALL ON FUNCTION crear_factura(integer, jsonb, varchar, numeric, integer[], integer, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_factura(integer, integer, jsonb, numeric, text, jsonb)                FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION factura_borrador_descartar(integer)                                              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION factura_anular(integer)                                                          FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION arca_registrar_cae(text, integer, integer, text, date, integer, integer, text, jsonb, jsonb, jsonb)
                                                                                                        FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION crear_factura(integer, jsonb, varchar, numeric, integer[], integer, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_factura(integer, integer, jsonb, numeric, text, jsonb)                TO authenticated;
GRANT EXECUTE ON FUNCTION factura_borrador_descartar(integer)                                              TO authenticated;
GRANT EXECUTE ON FUNCTION factura_anular(integer)                                                          TO authenticated;
GRANT EXECUTE ON FUNCTION arca_registrar_cae(text, integer, integer, text, date, integer, integer, text, jsonb, jsonb, jsonb)
                                                                                                           TO service_role;
