-- Retenciones sufridas en recibos: cancelan deuda del cliente, sin ingresar en Tesorería.
-- El certificado lo emite el agente de retención; este registro conserva sus datos para el contador.

CREATE TABLE recibo_retenciones (
  id                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  recibo_id          integer NOT NULL REFERENCES recibos(id) ON DELETE CASCADE,
  tipo_retencion     varchar(20) NOT NULL CHECK (tipo_retencion IN ('Ganancias', 'IVA', 'IIBB', 'SUSS')),
  codigo_regimen     varchar(20),
  jurisdiccion       varchar(100),
  numero_certificado varchar(80) NOT NULL CHECK (btrim(numero_certificado) <> ''),
  fecha              date NOT NULL,
  cuit_agente        varchar(11) NOT NULL CHECK (cuit_agente ~ '^[0-9]{11}$'),
  monto              numeric(14,2) NOT NULL CHECK (monto > 0),
  UNIQUE (cuit_agente, tipo_retencion, numero_certificado),
  CHECK (tipo_retencion <> 'IIBB' OR NULLIF(btrim(jurisdiccion), '') IS NOT NULL)
);

CREATE INDEX idx_recibo_retenciones_recibo ON recibo_retenciones(recibo_id);
CREATE INDEX idx_recibo_retenciones_fecha ON recibo_retenciones(fecha);

ALTER TABLE recibo_retenciones ENABLE ROW LEVEL SECURITY;
CREATE POLICY staff_all ON recibo_retenciones FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- Un importe por factura evita que un recibo imputado a varias facture la cancele varias veces.
-- El saldo se calcula con los importes históricos explícitos y los recibos anteriores sin importe.
CREATE FUNCTION facturas_pendientes_recibo(p_cliente_id integer)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(x) FROM (
    SELECT f.id, f.numero, f.fecha, f.total, f.estado,
      GREATEST(f.total
        - COALESCE((SELECT SUM(COALESCE(rf.importe, r.total))
                    FROM recibo_facturas rf JOIN recibos r ON r.id = rf.recibo_id
                    WHERE rf.factura_id = f.id), 0)
        - COALESCE((SELECT SUM(n.total) FROM notas n
                    WHERE n.factura_id = f.id AND n.tipo = 'NC'
                      AND n.estado_fiscal IN ('historico', 'autorizado')), 0), 0) AS saldo
    FROM facturas f
    WHERE f.cliente_id = p_cliente_id AND f.estado <> 'anulada'
      AND f.estado_fiscal IN ('historico', 'autorizado')
    ORDER BY f.fecha, f.numero, f.id
  ) x WHERE x.saldo > 0;
$$;

DROP FUNCTION crear_recibo(integer, jsonb, jsonb, text, varchar);

CREATE FUNCTION crear_recibo(
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
    BEGIN
      INSERT INTO recibo_retenciones
        (recibo_id, tipo_retencion, codigo_regimen, jurisdiccion, numero_certificado, fecha, cuit_agente, monto)
      VALUES
        (v_recibo.id, v_ret->>'tipo_retencion', NULLIF(btrim(v_ret->>'codigo_regimen'), ''),
         NULLIF(btrim(v_ret->>'jurisdiccion'), ''),
         btrim(v_ret->>'numero_certificado'), (v_ret->>'fecha')::date, v_cuit,
         (v_ret->>'monto')::numeric);
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'El certificado % de % del cliente ya está registrado.',
        v_ret->>'numero_certificado', v_ret->>'tipo_retencion';
    END;
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

-- Toda lectura del recibo incluye importe aplicado y certificados, sin multiplicar filas por JOIN.
CREATE OR REPLACE FUNCTION recibos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_cliente_id integer DEFAULT NULL,
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT r.id, count(*) OVER () AS total_filas, sum(r.total) OVER () AS total_importe
    FROM recibos r JOIN clientes c ON c.id = r.cliente_id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_cliente_id IS NULL OR r.cliente_id = p_cliente_id)
      AND (p_desde IS NULL OR r.fecha >= p_desde)
      AND (p_hasta IS NULL OR r.fecha <= p_hasta)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
  SELECT to_jsonb(t) FROM (
    SELECT r.*, c.razon_social, c.doc_tipo, c.doc_nro,
      ci.descripcion AS condicion_iva, c.condicion_iva_afip_id, ci.clase,
      COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'factura_id', rf.factura_id, 'numero', f.numero, 'importe', rf.importe) ORDER BY f.numero)
        FROM recibo_facturas rf JOIN facturas f ON f.id = rf.factura_id
        WHERE rf.recibo_id = r.id), '[]'::jsonb) AS facturas,
      COALESCE((SELECT jsonb_agg(to_jsonb(rm) - 'recibo_id' ORDER BY rm.id)
        FROM recibo_medios rm WHERE rm.recibo_id = r.id), '[]'::jsonb) AS medios,
      COALESCE((SELECT jsonb_agg(to_jsonb(rr) - 'recibo_id' ORDER BY rr.id)
        FROM recibo_retenciones rr WHERE rr.recibo_id = r.id), '[]'::jsonb) AS retenciones,
      pg.total_filas, pg.total_importe
    FROM pagina pg JOIN recibos r ON r.id = pg.id
    JOIN clientes c ON c.id = r.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
  ) t;
$$;

-- Recalcular también las retenciones sufridas de los recibos históricos sin importe explícito.
CREATE OR REPLACE FUNCTION recalcular_estado_factura(p_factura_id integer)
RETURNS void LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_total numeric;
  v_cobrado numeric;
  v_nc_total numeric;
BEGIN
  SELECT total INTO v_total FROM facturas WHERE id = p_factura_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT COALESCE(SUM(COALESCE(rf.importe, r.total)), 0) INTO v_cobrado
  FROM recibo_facturas rf JOIN recibos r ON r.id = rf.recibo_id
  WHERE rf.factura_id = p_factura_id;

  SELECT COALESCE(SUM(total), 0) INTO v_nc_total FROM notas
  WHERE factura_id = p_factura_id AND tipo = 'NC'
    AND estado_fiscal IN ('historico', 'autorizado');

  UPDATE facturas SET
    estado = CASE
      WHEN v_cobrado + v_nc_total <= 0 THEN 'pendiente'
      WHEN v_cobrado + v_nc_total >= v_total - 0.01 THEN 'cobrada'
      ELSE 'parcial'
    END,
    updated_at = NOW()
  WHERE id = p_factura_id AND estado <> 'anulada';
END;
$$;

-- Informe específico: las retenciones sufridas no forman parte del Libro IVA Ventas.
CREATE FUNCTION informe_retenciones_sufridas(p_desde date, p_hasta date)
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT jsonb_build_object(
    'retenciones', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.fecha, x.recibo_numero)
      FROM (SELECT rr.fecha, rr.tipo_retencion, rr.codigo_regimen, rr.jurisdiccion,
                   rr.numero_certificado, rr.cuit_agente, rr.monto,
                   r.fecha AS fecha_recibo, r.numero AS recibo_numero, c.razon_social AS cliente
            FROM recibo_retenciones rr JOIN recibos r ON r.id = rr.recibo_id
            JOIN clientes c ON c.id = r.cliente_id
            WHERE rr.fecha BETWEEN p_desde AND p_hasta) x), '[]'::jsonb),
    'total', COALESCE((SELECT SUM(monto) FROM recibo_retenciones
      WHERE fecha BETWEEN p_desde AND p_hasta), 0));
$$;

REVOKE ALL ON FUNCTION crear_recibo(integer, jsonb, jsonb, jsonb, text, varchar) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_recibo(integer, jsonb, jsonb, jsonb, text, varchar) TO authenticated;
REVOKE ALL ON FUNCTION facturas_pendientes_recibo(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION facturas_pendientes_recibo(integer) TO authenticated;
REVOKE ALL ON FUNCTION informe_retenciones_sufridas(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION informe_retenciones_sufridas(date, date) TO authenticated;

NOTIFY pgrst, 'reload schema';
