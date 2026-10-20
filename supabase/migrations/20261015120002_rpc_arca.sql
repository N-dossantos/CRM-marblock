-- =============================================================
-- ARCA — RPCs de emisión (PLAN_ARCA.md §4, Fase 2)
--
-- Las llama la Edge Function `arca` con la service-role, después de validar la sesión del usuario.
-- Ninguna es alcanzable por anon ni authenticated, salvo arca_solicitud_ultimo (una proyección
-- sin request/response ni credenciales). Todas SECURITY DEFINER sin FORCE RLS: escriben en las
-- tablas deny-all de 20261015120000_arca_schema.sql.
--
-- Flujo de una emisión (§2 y §4):
--   arca_token_get / arca_token_set                     ticket WSAA compartido entre isolates
--   arca_reclamar_serie        borrador|rechazado → en_proceso, toma la serie (PV, tipo ARCA)
--   FECompUltimoAutorizado  →  arca_reservar_numero     último + 1 como número tentativo
--   FECAESolicitar          →  arca_registrar_cae       A: número + CAE + efectos comerciales
--                           →  arca_registrar_rechazo   R: rechazado, libera la serie
--                           →  arca_registrar_incierto  sin respuesta: conserva serie y número
--   antes de enviar         →  arca_registrar_error_previo   vuelve a borrador, libera la serie
--   reconciliación          →  FECompConsultar: arca_registrar_cae o arca_confirmar_no_autorizado
--
-- Las transiciones son UPDATE condicionados al estado: una respuesta tardía no pisa un
-- autorizado ni registra dos veces el mismo comprobante.
-- =============================================================

-- ── Helpers ──────────────────────────────────────────────────────

-- Dígito verificador de CUIT (módulo 11). El 00000000000 del consumidor final genérico pasa el
-- cálculo, pero no es un CUIT.
CREATE FUNCTION crm_cuit_valido(p_cuit text)
RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_cuit !~ '^[0-9]{11}$' OR p_cuit = '00000000000' THEN false ELSE (
    SELECT CASE 11 - s % 11 WHEN 11 THEN 0 WHEN 10 THEN -1 ELSE 11 - s % 11 END
    FROM (SELECT SUM(substr(p_cuit, i, 1)::int * (ARRAY[5,4,3,2,7,6,5,4,3,2])[i]) AS s
          FROM generate_series(1, 10) AS i) x
  ) = substr(p_cuit, 11, 1)::int END;
$$;

-- Tipo de comprobante ARCA (§3.1). Cada código es una serie independiente.
CREATE FUNCTION arca_cbte_tipo(p_comprobante text, p_letra text)
RETURNS smallint
LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT (CASE p_comprobante || ' ' || p_letra
    WHEN 'FAC A' THEN 1 WHEN 'ND A' THEN 2 WHEN 'NC A' THEN 3
    WHEN 'FAC B' THEN 6 WHEN 'ND B' THEN 7 WHEN 'NC B' THEN 8
  END)::smallint;
$$;

-- Id de alícuota de IVA de ARCA (§3.1). El 0 % del catálogo es EXENTO: va a ImpOpEx y nunca al
-- array Iva (Id 3 sería "gravado a tasa 0", otra cosa), así que no tiene código acá.
CREATE FUNCTION arca_iva_id(p_porcentaje numeric)
RETURNS smallint
LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT (CASE p_porcentaje WHEN 10.5 THEN 4 WHEN 21 THEN 5 WHEN 27 THEN 6 END)::smallint;
$$;

-- ── arca_comprobante_para_emitir ─────────────────────────────────
-- El comprobante en la forma de FECAEDetRequest (sin CbteDesde/CbteHasta, que salen del número
-- que da ARCA) más los datos que la Edge Function necesita para la cabecera y la reconciliación.
-- Rechaza todo lo que ARCA rebotaría o que el CRM no sabe informar todavía (§3.3).
--
-- Los importes no se recalculan en la función: se recalculan acá desde los ítems guardados con la
-- misma crm_calc_totales_multi_alicuota que los generó, y tienen que coincidir con la cabecera
-- (una edición directa por PostgREST no llega a ARCA). Del desglose por alícuota salen ImpNeto
-- (gravado) e ImpOpEx (exento): neto_gravado del CRM suma los dos.
CREATE FUNCTION arca_comprobante_para_emitir(p_tabla text, p_id integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_hoy    date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v        record;
  v_cli    record;
  v_fac    facturas;
  v_items  jsonb;
  v_tot    jsonb;
  v_tipo   smallint;
  v_iva    jsonb;
  v_neto   numeric;
  v_exento numeric;
  v_sin_id text;
  v_asoc   jsonb;
  v_pv     integer;
BEGIN
  IF p_tabla = 'facturas' THEN
    SELECT 'FAC'::text AS comprobante, f.tipo::text AS letra, f.fecha, f.cliente_id,
           f.estado::text AS estado, f.estado_fiscal::text AS estado_fiscal, f.descuento_general,
           f.neto_gravado, f.iva_monto, f.percepciones_monto, f.total, f.arca_nro_tentativo,
           NULL::integer AS factura_id
      INTO v FROM facturas f WHERE f.id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Factura no encontrada';
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
             'cantidad', i.cantidad, 'precio_unitario', i.precio_unitario,
             'descuento_item', i.descuento_item, 'alicuota_iva_id', i.alicuota_iva_id,
             'es_pallet_vacio', COALESCE(pr.es_pallet_vacio, false),
             'es_transporte', COALESCE(pr.es_transporte, false)))
      INTO v_items
    FROM factura_items i LEFT JOIN productos pr ON pr.id = i.producto_id
    WHERE i.factura_id = p_id;
  ELSIF p_tabla = 'notas' THEN
    SELECT n.tipo::text AS comprobante, n.tipo_letra::text AS letra, n.fecha,
           COALESCE(n.cliente_id, f.cliente_id) AS cliente_id,
           NULL::text AS estado, n.estado_fiscal::text AS estado_fiscal, 0::numeric AS descuento_general,
           n.neto_gravado, n.iva_monto, n.percepciones_monto, n.total, n.arca_nro_tentativo,
           n.factura_id
      INTO v FROM notas n LEFT JOIN facturas f ON f.id = n.factura_id WHERE n.id = p_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Nota no encontrada';
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
             'cantidad', i.cantidad, 'precio_unitario', i.precio_unitario,
             'descuento_item', i.descuento_item, 'alicuota_iva_id', i.alicuota_iva_id,
             'es_pallet_vacio', COALESCE(pr.es_pallet_vacio, false),
             'es_transporte', COALESCE(pr.es_transporte, false)))
      INTO v_items
    FROM nota_items i LEFT JOIN productos pr ON pr.id = i.producto_id
    WHERE i.nota_id = p_id;
  ELSE
    RAISE EXCEPTION 'Tabla inválida: %', p_tabla;
  END IF;

  -- Estado
  IF v.estado_fiscal = 'historico' THEN
    RAISE EXCEPTION 'Es un comprobante histórico: no se emite desde el CRM.';
  ELSIF v.estado_fiscal = 'autorizado' THEN
    RAISE EXCEPTION 'El comprobante ya tiene CAE.';
  END IF;
  IF v.estado = 'anulada' THEN
    RAISE EXCEPTION 'La factura está anulada.';
  END IF;
  IF v.percepciones_monto <> 0 THEN
    RAISE EXCEPTION 'El comprobante tiene percepciones ($ %) y la emisión desde el CRM todavía no '
      'las informa a ARCA. Emitilo según el procedimiento fiscal vigente.', v.percepciones_monto;
  END IF;
  IF v.total <= 0 OR v_items IS NULL THEN
    RAISE EXCEPTION 'El comprobante no tiene importe para emitir.';
  END IF;

  v_tipo := arca_cbte_tipo(v.comprobante, v.letra);
  IF v_tipo IS NULL THEN
    RAISE EXCEPTION 'Comprobante sin tipo ARCA: % %.', v.comprobante, v.letra;
  END IF;

  -- Receptor (§3.2 y §3.3)
  SELECT c.doc_tipo, c.doc_nro, c.condicion_iva_afip_id, ci.clase, ci.descripcion
    INTO v_cli
  FROM clientes c JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
  WHERE c.id = v.cliente_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El comprobante no tiene cliente.';
  END IF;
  IF v_cli.clase <> v.letra THEN
    RAISE EXCEPTION 'El cliente es %: le corresponde comprobante %, no %.',
      v_cli.descripcion, v_cli.clase, v.letra;
  END IF;
  IF v_cli.doc_tipo = 80 AND NOT crm_cuit_valido(v_cli.doc_nro) THEN
    RAISE EXCEPTION 'El CUIT del cliente (%) no es válido.', v_cli.doc_nro;
  END IF;
  IF v.letra = 'A' AND v_cli.doc_tipo <> 80 THEN
    RAISE EXCEPTION 'Un comprobante A requiere el CUIT del receptor.';
  END IF;

  -- Fecha (concepto 1): hasta 5 días antes o después de hoy en Argentina, sin pasar el mes en
  -- curso. Sólo antes de enviar: un envío incierto se reconcilia con la fecha que se mandó.
  IF v.estado_fiscal IN ('borrador','rechazado') AND (
       v.fecha NOT BETWEEN v_hoy - 5 AND v_hoy + 5
       OR v.fecha > (date_trunc('month', v_hoy) + interval '1 month - 1 day')::date) THEN
    RAISE EXCEPTION 'La fecha % está fuera de la ventana que admite ARCA (hasta 5 días antes o '
      'después de hoy, dentro del mes).', to_char(v.fecha, 'DD/MM/YYYY');
  END IF;

  -- Importes
  v_tot := crm_calc_totales_multi_alicuota(v_items, v.descuento_general);
  IF (v_tot->>'neto_gravado')::numeric <> v.neto_gravado
     OR (v_tot->>'iva_monto')::numeric <> v.iva_monto
     OR (v_tot->>'total')::numeric <> v.total THEN
    RAISE EXCEPTION 'Los importes guardados (neto %, IVA %, total %) no coinciden con los ítems '
      '(neto %, IVA %, total %). Volvé a guardar el comprobante.',
      v.neto_gravado, v.iva_monto, v.total,
      v_tot->>'neto_gravado', v_tot->>'iva_monto', v_tot->>'total';
  END IF;

  SELECT
    jsonb_agg(jsonb_build_object('Id', arca_iva_id(d.porcentaje), 'BaseImp', d.neto_gravado,
                                 'Importe', d.iva_monto) ORDER BY d.porcentaje)
      FILTER (WHERE d.porcentaje <> 0),
    COALESCE(SUM(d.neto_gravado) FILTER (WHERE d.porcentaje <> 0), 0),
    COALESCE(SUM(d.neto_gravado) FILTER (WHERE d.porcentaje = 0), 0),
    string_agg(d.porcentaje::text || '%', ', ') FILTER (WHERE d.porcentaje <> 0 AND arca_iva_id(d.porcentaje) IS NULL)
    INTO v_iva, v_neto, v_exento, v_sin_id
  FROM jsonb_to_recordset(v_tot->'detalle') AS d(porcentaje numeric, neto_gravado numeric, iva_monto numeric);

  IF v_sin_id IS NOT NULL THEN
    RAISE EXCEPTION 'Alícuota de IVA sin código ARCA: %.', v_sin_id;
  END IF;
  -- ImpTotal = ImpTotConc + ImpNeto + ImpOpEx + ImpTrib + ImpIVA, exacto. Con varias alícuotas el
  -- redondeo por grupo puede diferir en un centavo del neto redondeado de la cabecera.
  IF v_neto + v_exento + v.iva_monto <> v.total THEN
    RAISE EXCEPTION 'Los importes por alícuota (gravado %, exento %, IVA %) no suman el total %: '
      'ARCA lo rechazaría por redondeo.', v_neto, v_exento, v.iva_monto, v.total;
  END IF;

  -- Comprobante asociado: las NC/ND lo exigen y la letra tiene que coincidir (§3.3). Una factura
  -- histórica no tiene CAE local: la Edge Function tiene que verificarla con FECompConsultar.
  IF p_tabla = 'notas' THEN
    IF v.factura_id IS NULL THEN
      RAISE EXCEPTION 'Una nota de crédito o débito necesita la factura asociada para emitirse.';
    END IF;
    SELECT * INTO v_fac FROM facturas WHERE id = v.factura_id;
    IF v_fac.tipo <> v.letra THEN
      RAISE EXCEPTION 'Una % % no puede asociarse a una Factura %.', v.comprobante, v.letra, v_fac.tipo;
    END IF;
    IF v_fac.estado_fiscal NOT IN ('autorizado','historico') THEN
      RAISE EXCEPTION 'La factura asociada todavía no está autorizada por ARCA.';
    END IF;
    v_asoc := jsonb_build_array(jsonb_build_object(
      'Tipo', arca_cbte_tipo('FAC', v_fac.tipo), 'PtoVta', v_fac.punto_venta::integer,
      'Nro', v_fac.numero_comp, 'CbteFch', to_char(v_fac.fecha, 'YYYYMMDD')));
  END IF;

  SELECT s.punto_venta INTO v_pv
  FROM arca_series_en_curso s WHERE s.tabla = p_tabla AND s.comprobante_id = p_id;

  RETURN jsonb_build_object(
    'tabla', p_tabla, 'id', p_id, 'estado_fiscal', v.estado_fiscal,
    'cbte_tipo', v_tipo, 'punto_venta', v_pv, 'nro_tentativo', v.arca_nro_tentativo,
    'verificar_asociado', COALESCE(v_fac.estado_fiscal = 'historico', false),
    -- jsonb_strip_nulls: un comprobante todo exento no manda Iva; una factura no manda CbtesAsoc.
    'det', jsonb_strip_nulls(jsonb_build_object(
      'Concepto', 1,
      'DocTipo', v_cli.doc_tipo, 'DocNro', v_cli.doc_nro::bigint,
      'CbteFch', to_char(v.fecha, 'YYYYMMDD'),
      'ImpTotal', v.total, 'ImpTotConc', 0, 'ImpNeto', v_neto, 'ImpOpEx', v_exento,
      'ImpTrib', 0, 'ImpIVA', v.iva_monto,
      'MonId', 'PES', 'MonCotiz', 1,
      'CondicionIVAReceptorId', v_cli.condicion_iva_afip_id,
      'Iva', v_iva, 'CbtesAsoc', v_asoc)));
END;
$$;

-- ── arca_reclamar_serie ──────────────────────────────────────────
-- Toma el comprobante (borrador|rechazado → en_proceso) y el único envío activo de su serie
-- (PV, tipo ARCA). Una segunda llamada al mismo comprobante o a la misma serie falla en vez de
-- iniciar otro envío. El PV llega de la Edge Function (secret ARCA_PUNTO_VENTA, §2): la base no lo
-- duplica.
--
-- La fecha fiscal es la del envío, en hora argentina: un borrador de ayer o un rechazado que se
-- corrige hoy se emite con fecha de hoy. Así CbteFch nunca queda fuera de la ventana de ARCA ni es
-- anterior al último comprobante autorizado de la serie.
CREATE FUNCTION arca_reclamar_serie(p_tabla text, p_id integer, p_punto_venta integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_estado text;
  v_pay    jsonb;
  v_otro   arca_series_en_curso;
  v_n      integer;
BEGIN
  IF p_tabla NOT IN ('facturas','notas') THEN
    RAISE EXCEPTION 'Tabla inválida: %', p_tabla;
  END IF;
  IF p_punto_venta IS NULL OR p_punto_venta < 1 THEN
    RAISE EXCEPTION 'Punto de venta inválido.';
  END IF;

  EXECUTE format('SELECT estado_fiscal FROM %I WHERE id = $1 FOR UPDATE', p_tabla)
    INTO v_estado USING p_id;
  IF v_estado IS NULL THEN
    RAISE EXCEPTION 'Comprobante no encontrado';
  END IF;
  IF v_estado NOT IN ('borrador','rechazado') THEN
    RAISE EXCEPTION '%', CASE v_estado
      WHEN 'en_proceso'         THEN 'El comprobante ya se está emitiendo.'
      WHEN 'resultado_incierto' THEN 'El último envío quedó sin respuesta: consultá el estado en ARCA antes de reintentar.'
      WHEN 'autorizado'         THEN 'El comprobante ya tiene CAE.'
      ELSE                           'Es un comprobante histórico: no se emite desde el CRM.'
    END;
  END IF;

  EXECUTE format('UPDATE %I SET fecha = $2 WHERE id = $1', p_tabla)
    USING p_id, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;

  v_pay := arca_comprobante_para_emitir(p_tabla, p_id);

  INSERT INTO arca_series_en_curso (punto_venta, cbte_tipo, tabla, comprobante_id)
  VALUES (p_punto_venta, (v_pay->>'cbte_tipo')::smallint, p_tabla, p_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    SELECT * INTO v_otro FROM arca_series_en_curso
    WHERE punto_venta = p_punto_venta AND cbte_tipo = (v_pay->>'cbte_tipo')::smallint;
    RAISE EXCEPTION 'Hay otra emisión en curso en esta serie (% id %): esperá a que termine.',
      v_otro.tabla, v_otro.comprobante_id;
  END IF;

  EXECUTE format('UPDATE %I SET estado_fiscal = ''en_proceso'' WHERE id = $1', p_tabla) USING p_id;

  RETURN v_pay || jsonb_build_object('estado_fiscal', 'en_proceso', 'punto_venta', p_punto_venta);
END;
$$;

-- ── arca_reservar_numero ─────────────────────────────────────────
-- Deja constancia del número que se va a pedir (FECompUltimoAutorizado + 1) antes de enviar
-- FECAESolicitar: es lo que se consulta si la respuesta se pierde.
CREATE FUNCTION arca_reservar_numero(p_tabla text, p_id integer, p_nro integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_n integer;
BEGIN
  IF p_tabla NOT IN ('facturas','notas') THEN
    RAISE EXCEPTION 'Tabla inválida: %', p_tabla;
  END IF;
  IF p_nro IS NULL OR p_nro < 1 THEN
    RAISE EXCEPTION 'Número tentativo inválido.';
  END IF;

  EXECUTE format($q$
    UPDATE %I SET arca_nro_tentativo = $2
    WHERE id = $1 AND estado_fiscal = 'en_proceso'
      AND EXISTS (SELECT 1 FROM arca_series_en_curso s
                  WHERE s.tabla = %L AND s.comprobante_id = $1)$q$, p_tabla, p_tabla)
    USING p_id, p_nro;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'El comprobante no está en emisión.';
  END IF;
END;
$$;

-- ── arca_registrar_cae ───────────────────────────────────────────
-- Atómica: número + CAE + afip_* + autorizado, libera la serie, aplica los efectos comerciales y
-- audita. Acepta en_proceso y resultado_incierto (la reconciliación recupera el CAE por acá).
--
-- Un CAE nunca se pierde: si el comprobante no está como se esperaba (otro estado, otro número,
-- una restricción que salta) no se aborta, se audita con el motivo, la serie queda bloqueada y se
-- devuelve registrado = false para que alguien lo resuelva a mano.
CREATE FUNCTION arca_registrar_cae(
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
        UPDATE remitos SET estado = 'facturado', updated_at = NOW()
        WHERE factura_id = p_id AND estado = 'pendiente';
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

-- ── arca_registrar_error_previo ──────────────────────────────────
-- Falla antes de enviar FECAESolicitar (token, último autorizado, validación): ARCA no recibió
-- nada, así que se audita, se vuelve a borrador y se libera la serie. Si todavía no se había
-- reclamado la serie, sólo audita.
CREATE FUNCTION arca_registrar_error_previo(p_tabla text, p_id integer, p_error text, p_request jsonb DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_n      integer;
  v_estado text;
BEGIN
  IF p_tabla NOT IN ('facturas','notas') THEN
    RAISE EXCEPTION 'Tabla inválida: %', p_tabla;
  END IF;

  EXECUTE format($q$
    UPDATE %I SET estado_fiscal = 'borrador', arca_nro_tentativo = NULL
    WHERE id = $1 AND estado_fiscal = 'en_proceso'$q$, p_tabla) USING p_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 THEN
    DELETE FROM arca_series_en_curso WHERE tabla = p_tabla AND comprobante_id = p_id;
  END IF;

  INSERT INTO arca_solicitudes (tabla, comprobante_id, resultado, request, errores)
  VALUES (p_tabla, p_id, 'error_previo', p_request, jsonb_build_array(jsonb_build_object('Msg', p_error)));

  EXECUTE format('SELECT estado_fiscal FROM %I WHERE id = $1', p_tabla) INTO v_estado USING p_id;
  RETURN v_estado;
END;
$$;

-- ── arca_registrar_rechazo ───────────────────────────────────────
-- Sólo para Resultado = R explícito. Un rechazo tardío sobre algo que ya no está en_proceso se
-- audita y no cambia el estado.
CREATE FUNCTION arca_registrar_rechazo(
  p_tabla text, p_id integer, p_errores jsonb, p_observaciones jsonb, p_request jsonb, p_response jsonb
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_n      integer;
  v_estado text;
BEGIN
  IF p_tabla NOT IN ('facturas','notas') THEN
    RAISE EXCEPTION 'Tabla inválida: %', p_tabla;
  END IF;

  EXECUTE format($q$
    UPDATE %I SET estado_fiscal = 'rechazado', arca_nro_tentativo = NULL
    WHERE id = $1 AND estado_fiscal = 'en_proceso'$q$, p_tabla) USING p_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 THEN
    DELETE FROM arca_series_en_curso WHERE tabla = p_tabla AND comprobante_id = p_id;
  END IF;

  INSERT INTO arca_solicitudes (tabla, comprobante_id, resultado, request, response, errores, observaciones)
  VALUES (p_tabla, p_id, 'rechazado', p_request, p_response, p_errores, p_observaciones);

  EXECUTE format('SELECT estado_fiscal FROM %I WHERE id = $1', p_tabla) INTO v_estado USING p_id;
  RETURN v_estado;
END;
$$;

-- ── arca_registrar_incierto ──────────────────────────────────────
-- FECAESolicitar salió y no hay respuesta utilizable (timeout, desconexión, HTTP, SOAP
-- incompleto). NO es un rechazo: se conservan el número tentativo y la serie hasta reconciliar.
-- También convierte un en_proceso que quedó colgado (la función murió a mitad del envío) para
-- poder reconciliarlo; sin número tentativo no se envió nada y corresponde error_previo.
CREATE FUNCTION arca_registrar_incierto(
  p_tabla text, p_id integer, p_request jsonb, p_response jsonb, p_error text
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_estado text;
BEGIN
  IF p_tabla NOT IN ('facturas','notas') THEN
    RAISE EXCEPTION 'Tabla inválida: %', p_tabla;
  END IF;

  EXECUTE format($q$
    UPDATE %I SET estado_fiscal = 'resultado_incierto'
    WHERE id = $1 AND estado_fiscal = 'en_proceso' AND arca_nro_tentativo IS NOT NULL$q$, p_tabla)
    USING p_id;

  INSERT INTO arca_solicitudes (tabla, comprobante_id, resultado, request, response, errores)
  VALUES (p_tabla, p_id, 'incierto', p_request, p_response, jsonb_build_array(jsonb_build_object('Msg', p_error)));

  EXECUTE format('SELECT estado_fiscal FROM %I WHERE id = $1', p_tabla) INTO v_estado USING p_id;
  RETURN v_estado;
END;
$$;

-- ── arca_confirmar_no_autorizado ─────────────────────────────────
-- Sólo tras una consulta concluyente: FECompConsultar no encontró el tentativo y
-- FECompUltimoAutorizado sigue por debajo. El último autorizado se pasa para que la base lo
-- verifique también: si ARCA ya llegó al tentativo, ese número pudo usarse y no se libera nada.
CREATE FUNCTION arca_confirmar_no_autorizado(
  p_tabla text, p_id integer, p_ultimo_autorizado integer, p_request jsonb, p_response jsonb
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_estado text;
  v_tent   integer;
BEGIN
  IF p_tabla NOT IN ('facturas','notas') THEN
    RAISE EXCEPTION 'Tabla inválida: %', p_tabla;
  END IF;

  EXECUTE format('SELECT estado_fiscal, arca_nro_tentativo FROM %I WHERE id = $1 FOR UPDATE', p_tabla)
    INTO v_estado, v_tent USING p_id;
  IF v_estado IS DISTINCT FROM 'resultado_incierto' THEN
    RAISE EXCEPTION 'Sólo un resultado incierto se puede dar por no autorizado.';
  END IF;
  IF p_ultimo_autorizado IS NULL OR p_ultimo_autorizado >= v_tent THEN
    RAISE EXCEPTION 'ARCA ya autorizó hasta el N° %: el tentativo % pudo haberse usado.',
      p_ultimo_autorizado, v_tent;
  END IF;

  EXECUTE format($q$
    UPDATE %I SET estado_fiscal = 'borrador', arca_nro_tentativo = NULL WHERE id = $1$q$, p_tabla)
    USING p_id;
  DELETE FROM arca_series_en_curso WHERE tabla = p_tabla AND comprobante_id = p_id;

  INSERT INTO arca_solicitudes (tabla, comprobante_id, resultado, request, response)
  VALUES (p_tabla, p_id, 'no_autorizado', p_request, p_response);
END;
$$;

-- ── Ticket WSAA ──────────────────────────────────────────────────
-- arca_token_get devuelve el TA si le quedan más de p_margen_segundos. Si no, da el turno de
-- renovarlo a un solo llamador por minuto ({renovar: true}); los demás reciben {esperar: true}.
-- Así dos isolates no piden dos TA a la vez (el segundo pedido rebota con alreadyAuthenticated y
-- el TA del primero se perdería). El turno vence solo: si quien lo tomó falla, otro reintenta.
CREATE FUNCTION arca_token_get(p_servicio text, p_margen_segundos integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v arca_tokens;
BEGIN
  INSERT INTO arca_tokens (servicio) VALUES (p_servicio) ON CONFLICT DO NOTHING;
  SELECT * INTO v FROM arca_tokens WHERE servicio = p_servicio FOR UPDATE;

  IF v.token IS NOT NULL AND v.expira_en > NOW() + make_interval(secs => p_margen_segundos) THEN
    RETURN jsonb_build_object('token', v.token, 'sign', v.sign, 'expira_en', v.expira_en);
  END IF;
  IF v.pedido_hasta > NOW() THEN
    RETURN jsonb_build_object('esperar', true, 'hasta', v.pedido_hasta);
  END IF;

  UPDATE arca_tokens SET pedido_hasta = NOW() + interval '1 minute', updated_at = NOW()
  WHERE servicio = p_servicio;
  RETURN jsonb_build_object('renovar', true);
END;
$$;

CREATE FUNCTION arca_token_set(p_servicio text, p_token text, p_sign text, p_expira_en timestamptz)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO arca_tokens (servicio, token, sign, expira_en, pedido_hasta, updated_at)
  VALUES (p_servicio, p_token, p_sign, p_expira_en, NULL, NOW())
  ON CONFLICT (servicio) DO UPDATE SET
    token = EXCLUDED.token, sign = EXCLUDED.sign, expira_en = EXCLUDED.expira_en,
    pedido_hasta = NULL, updated_at = NOW();
END;
$$;

-- ── arca_solicitud_ultimo ────────────────────────────────────────
-- Lo que la UI necesita para operar (§5): estado fiscal, CAE y el último intento con los errores
-- y observaciones de ARCA tal cual. Sin request/response ni nada de arca_tokens.
CREATE FUNCTION arca_solicitud_ultimo(p_tabla text, p_id integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_tabla NOT IN ('facturas','notas') THEN
    RAISE EXCEPTION 'Tabla inválida: %', p_tabla;
  END IF;

  EXECUTE format($q$
    SELECT jsonb_build_object(
      'estado_fiscal', c.estado_fiscal, 'arca_nro_tentativo', c.arca_nro_tentativo,
      'cae', c.cae, 'cae_vencimiento', c.cae_vencimiento,
      'ultimo', (SELECT jsonb_build_object('resultado', s.resultado, 'errores', s.errores,
                                           'observaciones', s.observaciones, 'fecha', s.created_at)
                 FROM arca_solicitudes s
                 WHERE s.tabla = %L AND s.comprobante_id = c.id
                 ORDER BY s.id DESC LIMIT 1))
    FROM %I c WHERE c.id = $1$q$, p_tabla, p_tabla)
    INTO v USING p_id;
  IF v IS NULL THEN
    RAISE EXCEPTION 'Comprobante no encontrado';
  END IF;
  RETURN v;
END;
$$;

-- ── Permisos ─────────────────────────────────────────────────────
-- REVOKE explícito por función (lección de 0004/0010: los DEFAULT PRIVILEGES de Supabase le dan
-- EXECUTE a anon y authenticated a toda función nueva).
REVOKE ALL ON FUNCTION crm_cuit_valido(text)                                  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_cbte_tipo(text, text)                             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_iva_id(numeric)                                   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_comprobante_para_emitir(text, integer)            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_reclamar_serie(text, integer, integer)            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_reservar_numero(text, integer, integer)           FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_registrar_cae(text, integer, integer, text, date, integer, integer, text, jsonb, jsonb, jsonb)
                                                                              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_registrar_error_previo(text, integer, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_registrar_rechazo(text, integer, jsonb, jsonb, jsonb, jsonb)
                                                                              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_registrar_incierto(text, integer, jsonb, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_confirmar_no_autorizado(text, integer, integer, jsonb, jsonb)
                                                                              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_token_get(text, integer)                          FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_token_set(text, text, text, timestamptz)          FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION arca_solicitud_ultimo(text, integer)                   FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION arca_comprobante_para_emitir(text, integer)            TO service_role;
GRANT EXECUTE ON FUNCTION arca_reclamar_serie(text, integer, integer)            TO service_role;
GRANT EXECUTE ON FUNCTION arca_reservar_numero(text, integer, integer)           TO service_role;
GRANT EXECUTE ON FUNCTION arca_registrar_cae(text, integer, integer, text, date, integer, integer, text, jsonb, jsonb, jsonb)
                                                                                 TO service_role;
GRANT EXECUTE ON FUNCTION arca_registrar_error_previo(text, integer, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION arca_registrar_rechazo(text, integer, jsonb, jsonb, jsonb, jsonb)
                                                                                 TO service_role;
GRANT EXECUTE ON FUNCTION arca_registrar_incierto(text, integer, jsonb, jsonb, text) TO service_role;
GRANT EXECUTE ON FUNCTION arca_confirmar_no_autorizado(text, integer, integer, jsonb, jsonb)
                                                                                 TO service_role;
GRANT EXECUTE ON FUNCTION arca_token_get(text, integer)                          TO service_role;
GRANT EXECUTE ON FUNCTION arca_token_set(text, text, text, timestamptz)          TO service_role;
GRANT EXECUTE ON FUNCTION arca_solicitud_ultimo(text, integer)                   TO authenticated, service_role;
