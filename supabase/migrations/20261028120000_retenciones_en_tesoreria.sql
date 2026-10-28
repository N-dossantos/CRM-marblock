-- Retenciones sufridas con el impacto que tenían en Tango (decisión de Nico del 2026-10-28,
-- PLAN_MAESTRO §3.12): cada retención suma saldo en la cuenta de su impuesto, dentro de la
-- agrupación "Retenciones". Las cuentas siguen inactivas: nunca se ofrecen para cobrar en efectivo
-- o transferencia. Reemplaza el "sin ingresar en Tesorería" de 20261020180000.

ALTER TABLE cuentas_bancarias
  ADD COLUMN tipo_retencion varchar(20) UNIQUE
    CHECK (tipo_retencion IN ('Ganancias', 'IVA', 'IIBB', 'SUSS'));

-- Prod ya tiene las cuentas de Tango; homologación no, y se crean igual que allá.
INSERT INTO cuentas_bancarias (descripcion, clase, activo, agrupacion_id)
SELECT v.descripcion, 'caja', false,
       (SELECT id FROM agrupaciones_tesoreria WHERE codigo = 'RETENCIONES')
FROM (VALUES ('RETENCIONES DE GANANCIAS SUFRIDAS'), ('RETENCIONES IIBR SUFRIDAS'),
             ('RETENCION IVA SUFRIDO'), ('RETENCIONES S.U.S.S. SUFRIDAS')) v(descripcion)
WHERE NOT EXISTS (SELECT 1 FROM cuentas_bancarias cb WHERE cb.descripcion = v.descripcion);

-- "RETENCION GANANCIAS GENERADAS" queda sin impuesto: sólo guarda las 5 históricas.
UPDATE cuentas_bancarias SET tipo_retencion = CASE descripcion
    WHEN 'RETENCIONES DE GANANCIAS SUFRIDAS' THEN 'Ganancias'
    WHEN 'RETENCIONES IIBR SUFRIDAS' THEN 'IIBB'
    WHEN 'RETENCION IVA SUFRIDO' THEN 'IVA'
    WHEN 'RETENCIONES S.U.S.S. SUFRIDAS' THEN 'SUSS'
  END
WHERE descripcion IN ('RETENCIONES DE GANANCIAS SUFRIDAS', 'RETENCIONES IIBR SUFRIDAS',
                      'RETENCION IVA SUFRIDO', 'RETENCIONES S.U.S.S. SUFRIDAS');

DO $$
BEGIN
  IF (SELECT count(*) FROM cuentas_bancarias WHERE tipo_retencion IS NOT NULL) <> 4 THEN
    RAISE EXCEPTION 'Falta la cuenta de tesorería de algún impuesto retenido.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION crear_recibo(
  p_cliente_id    integer,
  p_medios        jsonb,
  p_imputaciones  jsonb DEFAULT '[]'::jsonb,
  p_retenciones   jsonb DEFAULT '[]'::jsonb,
  p_observaciones text DEFAULT NULL,
  p_numero        varchar DEFAULT NULL
)
RETURNS recibos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num record;
  v_numero varchar;
  v_pv char(5);
  v_comp integer;
  v_recibo recibos;
  v_total_medios numeric;
  v_total_retenciones numeric;
  v_total numeric;
  v_total_imputado numeric;
  v_cuit varchar(11);
  v_m jsonb;
  v_ret jsonb;
  v_imp jsonb;
  v_cta cuentas_bancarias;
  v_fac facturas;
  v_saldo numeric;
  v_rm_id integer;
  v_rr_id integer;
BEGIN
  IF p_cliente_id IS NULL OR NOT EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id) THEN
    RAISE EXCEPTION 'Seleccioná un cliente válido.';
  END IF;
  IF jsonb_typeof(p_medios) IS DISTINCT FROM 'array'
     OR jsonb_typeof(p_imputaciones) IS DISTINCT FROM 'array'
     OR jsonb_typeof(p_retenciones) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Medios, imputaciones y retenciones deben ser listas.';
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_medios) m
             WHERE m->>'tipo' NOT IN ('efectivo', 'transferencia', 'cheque', 'echeq')
                OR m->>'tipo' IS NULL
                OR NULLIF(m->>'monto', '')::numeric <= 0
                OR NULLIF(m->>'monto', '') IS NULL
                OR round((m->>'monto')::numeric, 2) <> (m->>'monto')::numeric) THEN
    RAISE EXCEPTION 'Cada medio debe tener un tipo válido y un monto positivo con dos decimales como máximo.';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_retenciones) r
             WHERE r->>'tipo_retencion' NOT IN ('Ganancias', 'IVA', 'IIBB', 'SUSS')
                OR r->>'tipo_retencion' IS NULL
                OR NULLIF(btrim(r->>'numero_certificado'), '') IS NULL
                OR NULLIF(r->>'fecha', '') IS NULL
                OR NULLIF(r->>'monto', '')::numeric <= 0
                OR NULLIF(r->>'monto', '') IS NULL
                OR round((r->>'monto')::numeric, 2) <> (r->>'monto')::numeric
                OR (r->>'tipo_retencion' = 'IIBB' AND NULLIF(btrim(r->>'jurisdiccion'), '') IS NULL)) THEN
    RAISE EXCEPTION 'Cada retención necesita tipo, fecha, certificado y monto; IIBB también jurisdicción.';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_imputaciones) i
             WHERE NULLIF(i->>'factura_id', '') IS NULL
                OR NULLIF(i->>'importe', '')::numeric <= 0
                OR NULLIF(i->>'importe', '') IS NULL
                OR round((i->>'importe')::numeric, 2) <> (i->>'importe')::numeric) THEN
    RAISE EXCEPTION 'Cada imputación necesita una factura y un importe positivo.';
  END IF;
  IF (SELECT COUNT(*) FROM jsonb_array_elements(p_imputaciones)) <>
     (SELECT COUNT(DISTINCT (i->>'factura_id')::integer) FROM jsonb_array_elements(p_imputaciones) i) THEN
    RAISE EXCEPTION 'Una factura no puede imputarse dos veces en el mismo recibo.';
  END IF;

  SELECT COALESCE(SUM((m->>'monto')::numeric), 0) INTO v_total_medios
    FROM jsonb_array_elements(p_medios) m;
  SELECT COALESCE(SUM((r->>'monto')::numeric), 0) INTO v_total_retenciones
    FROM jsonb_array_elements(p_retenciones) r;
  SELECT COALESCE(SUM((i->>'importe')::numeric), 0) INTO v_total_imputado
    FROM jsonb_array_elements(p_imputaciones) i;
  v_total := v_total_medios + v_total_retenciones;
  IF v_total <= 0 THEN RAISE EXCEPTION 'El total del recibo debe ser mayor a cero.'; END IF;
  IF v_total_imputado > v_total THEN
    RAISE EXCEPTION 'La suma imputada a facturas supera el total del recibo.';
  END IF;

  IF jsonb_array_length(p_retenciones) > 0 THEN
    SELECT doc_nro INTO v_cuit FROM clientes WHERE id = p_cliente_id AND doc_tipo = 80;
    IF v_cuit IS NULL THEN
      RAISE EXCEPTION 'Para registrar retenciones, el cliente debe tener CUIT.';
    END IF;
  END IF;

  v_numero := NULLIF(trim(p_numero), '');
  IF v_numero IS NULL THEN
    SELECT * INTO v_num FROM siguiente_numero('recibo');
    v_numero := v_num.numero_formateado;
    v_pv := v_num.punto_venta;
    v_comp := v_num.numero;
  ELSE
    IF v_numero !~ '^\d{5}-\d{8}$' THEN
      RAISE EXCEPTION 'El número % no tiene el formato PPPPP-NNNNNNNN.', v_numero;
    END IF;
    v_pv := split_part(v_numero, '-', 1);
    v_comp := split_part(v_numero, '-', 2)::integer;
  END IF;

  BEGIN
    INSERT INTO recibos (numero, punto_venta, numero_comp, fecha, cliente_id, total, observaciones)
    VALUES (v_numero, v_pv, v_comp, CURRENT_DATE, p_cliente_id, v_total, p_observaciones)
    RETURNING * INTO v_recibo;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'El recibo % ya fue emitido.', v_numero;
  END;

  IF p_numero IS NOT NULL THEN
    UPDATE contadores SET ultimo_numero = v_comp, punto_venta = v_pv
    WHERE tipo = 'recibo' AND (punto_venta <> v_pv OR ultimo_numero < v_comp);
  END IF;

  FOR v_m IN SELECT value FROM jsonb_array_elements(p_medios) LOOP
    IF v_m->>'tipo' IN ('efectivo', 'transferencia') THEN
      SELECT * INTO v_cta FROM cuentas_bancarias
      WHERE id = NULLIF(v_m->>'cuenta_bancaria_id', '')::integer AND activo
        AND clase = CASE WHEN v_m->>'tipo' = 'efectivo' THEN 'caja' ELSE 'banco' END;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Elegí una caja activa para efectivo o una cuenta bancaria activa para transferencia.';
      END IF;
    ELSE
      v_cta := NULL;
      IF NULLIF(btrim(v_m->>'numero_cheque'), '') IS NULL
         OR NULLIF(btrim(v_m->>'banco'), '') IS NULL
         OR NULLIF(v_m->>'fecha_vcto', '') IS NULL THEN
        RAISE EXCEPTION 'Cheque y E-Cheq necesitan número, banco y vencimiento.';
      END IF;
    END IF;

    INSERT INTO recibo_medios
      (recibo_id, tipo, detalle, numero_cheque, banco, titular, cuit_titular,
       fecha_emision, fecha_vcto, monto)
    VALUES
      (v_recibo.id, v_m->>'tipo', v_cta.descripcion, NULLIF(v_m->>'numero_cheque', ''),
       NULLIF(v_m->>'banco', ''), NULLIF(v_m->>'titular', ''), NULLIF(v_m->>'cuit_titular', ''),
       NULLIF(v_m->>'fecha_emision', '')::date, NULLIF(v_m->>'fecha_vcto', '')::date,
       (v_m->>'monto')::numeric)
    RETURNING id INTO v_rm_id;

    IF v_m->>'tipo' IN ('cheque', 'echeq') THEN
      INSERT INTO cheques
        (numero, tipo, banco, titular, cuit_titular, fecha_emision, fecha_vcto, monto, cliente_id, estado)
      VALUES
        (v_m->>'numero_cheque',
         CASE WHEN v_m->>'tipo' = 'cheque' THEN 'fisico' ELSE 'echeq' END,
         v_m->>'banco', v_m->>'titular', v_m->>'cuit_titular',
         COALESCE(NULLIF(v_m->>'fecha_emision', '')::date, CURRENT_DATE),
         (v_m->>'fecha_vcto')::date, (v_m->>'monto')::numeric, p_cliente_id, 'en_cartera');
    ELSE
      PERFORM tes_emitir_cobranza(v_rm_id, v_cta.id);
    END IF;
  END LOOP;

  FOR v_ret IN SELECT value FROM jsonb_array_elements(p_retenciones) LOOP
    SELECT * INTO v_cta FROM cuentas_bancarias WHERE tipo_retencion = v_ret->>'tipo_retencion';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'No hay cuenta de tesorería para las retenciones de %.', v_ret->>'tipo_retencion';
    END IF;

    BEGIN
      INSERT INTO recibo_retenciones
        (recibo_id, tipo_retencion, codigo_regimen, jurisdiccion, numero_certificado, fecha, cuit_agente, monto)
      VALUES
        (v_recibo.id, v_ret->>'tipo_retencion', NULLIF(btrim(v_ret->>'codigo_regimen'), ''),
         NULLIF(btrim(v_ret->>'jurisdiccion'), ''),
         btrim(v_ret->>'numero_certificado'), (v_ret->>'fecha')::date, v_cuit,
         (v_ret->>'monto')::numeric)
      RETURNING id INTO v_rr_id;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'El certificado % de % del cliente ya está registrado.',
        v_ret->>'numero_certificado', v_ret->>'tipo_retencion';
    END;

    -- Como Tango: una cobranza en la cuenta del impuesto, con la fecha del recibo.
    INSERT INTO movimientos_tesoreria
      (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
       origen, referencia_tipo, referencia_id, concepto)
    VALUES
      (v_recibo.fecha, v_cta.id,
       (SELECT id FROM tipos_comprobante_tesoreria WHERE codigo = 'COBRANZA'), 1,
       (v_ret->>'monto')::numeric, 'recibo', 'recibo_retenciones', v_rr_id,
       'Retención ' || (v_ret->>'tipo_retencion') || ' recibo ' || v_recibo.numero);
  END LOOP;

  -- El importe de cada factura se guarda explícito; el remanente queda a cuenta del cliente.
  FOR v_imp IN SELECT value FROM jsonb_array_elements(p_imputaciones)
               ORDER BY (value->>'factura_id')::integer LOOP
    SELECT * INTO v_fac FROM facturas WHERE id = (v_imp->>'factura_id')::integer FOR UPDATE;
    IF NOT FOUND OR v_fac.cliente_id <> p_cliente_id OR v_fac.estado = 'anulada' THEN
      RAISE EXCEPTION 'Factura inválida o de otro cliente.';
    END IF;
    IF v_fac.estado_fiscal NOT IN ('historico', 'autorizado') THEN
      RAISE EXCEPTION 'La factura % todavía no tiene CAE.', v_fac.numero;
    END IF;
    SELECT GREATEST(v_fac.total
      - COALESCE((SELECT SUM(COALESCE(rf.importe, r.total))
                  FROM recibo_facturas rf JOIN recibos r ON r.id = rf.recibo_id
                  WHERE rf.factura_id = v_fac.id), 0)
      - COALESCE((SELECT SUM(n.total) FROM notas n WHERE n.factura_id = v_fac.id
                  AND n.tipo = 'NC' AND n.estado_fiscal IN ('historico', 'autorizado')), 0), 0)
      INTO v_saldo;
    IF (v_imp->>'importe')::numeric > v_saldo THEN
      RAISE EXCEPTION 'La imputación supera el saldo pendiente de la factura % (%).',
        v_fac.numero, v_saldo;
    END IF;
    INSERT INTO recibo_facturas (recibo_id, factura_id, importe)
    VALUES (v_recibo.id, v_fac.id, (v_imp->>'importe')::numeric);
    PERFORM recalcular_estado_factura(v_fac.id);
  END LOOP;

  RETURN v_recibo;
END;
$$;

-- Si al completar el certificado cambia el impuesto, el movimiento pasa a la cuenta del nuevo.
-- Los movimientos de Tango apuntan al recibo, no a la retención, y quedan como estaban.
CREATE OR REPLACE FUNCTION completar_certificado_retencion(
  p_id integer,
  p_tipo_retencion varchar,
  p_numero_certificado varchar,
  p_fecha date,
  p_codigo_regimen varchar DEFAULT NULL,
  p_jurisdiccion varchar DEFAULT NULL
)
RETURNS recibo_retenciones
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_ret recibo_retenciones;
BEGIN
  IF p_tipo_retencion NOT IN ('Ganancias', 'IVA', 'IIBB', 'SUSS')
     OR NULLIF(btrim(p_numero_certificado), '') IS NULL
     OR p_fecha IS NULL
     OR (p_tipo_retencion = 'IIBB' AND NULLIF(btrim(p_jurisdiccion), '') IS NULL) THEN
    RAISE EXCEPTION 'Completá impuesto, número y fecha del certificado; para IIBB también jurisdicción.';
  END IF;

  BEGIN
    UPDATE recibo_retenciones SET
      tipo_retencion = p_tipo_retencion,
      numero_certificado = btrim(p_numero_certificado),
      fecha = p_fecha,
      codigo_regimen = NULLIF(btrim(p_codigo_regimen), ''),
      jurisdiccion = NULLIF(btrim(p_jurisdiccion), ''),
      pendiente_documentacion = false
    WHERE id = p_id AND pendiente_documentacion
    RETURNING * INTO v_ret;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Ese certificado ya está registrado para el cliente y el impuesto.';
  END;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La retención no existe o ya tiene certificado.';
  END IF;

  UPDATE movimientos_tesoreria mt SET
    cuenta_bancaria_id = cb.id,
    concepto = 'Retención ' || v_ret.tipo_retencion || ' recibo ' || r.numero,
    updated_at = NOW()
  FROM cuentas_bancarias cb, recibos r
  WHERE cb.tipo_retencion = v_ret.tipo_retencion AND r.id = v_ret.recibo_id
    AND mt.referencia_tipo = 'recibo_retenciones' AND mt.referencia_id = v_ret.id
    AND NOT mt.anulado AND mt.cuenta_bancaria_id <> cb.id;
  RETURN v_ret;
END;
$$;

-- Recibo 00001-00004302 (cargado el 20/10 con el formulario anterior): 20261020210000 le anuló el
-- movimiento; vuelve a sumar en su cuenta, como las de Tango.
UPDATE movimientos_tesoreria mt SET
  anulado = false,
  concepto = 'Retención ' || rr.tipo_retencion || ' recibo ' || r.numero,
  updated_at = NOW()
FROM recibo_retenciones rr JOIN recibos r ON r.id = rr.recibo_id
WHERE mt.referencia_tipo = 'recibo_retenciones' AND mt.referencia_id = rr.id AND mt.anulado;

-- Las retenciones cargadas con el formulario nuevo antes de esta migración (sólo hay en
-- homologación) reciben su movimiento.
INSERT INTO movimientos_tesoreria
  (fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
   origen, referencia_tipo, referencia_id, concepto)
SELECT r.fecha, cb.id, (SELECT id FROM tipos_comprobante_tesoreria WHERE codigo = 'COBRANZA'), 1,
       rr.monto, 'recibo', 'recibo_retenciones', rr.id,
       'Retención ' || rr.tipo_retencion || ' recibo ' || r.numero
FROM recibo_retenciones rr
JOIN recibos r ON r.id = rr.recibo_id
JOIN cuentas_bancarias cb ON cb.tipo_retencion = rr.tipo_retencion
WHERE rr.origen_medio_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM movimientos_tesoreria mt
                  WHERE mt.referencia_tipo = 'recibo_retenciones' AND mt.referencia_id = rr.id);

NOTIFY pgrst, 'reload schema';
