-- Ejecutar en una base de prueba con las migraciones aplicadas. Todo se revierte.
-- psql "$TEST_DATABASE_URL" -X -f supabase/retenciones/verificar.sql
\set ON_ERROR_STOP 1
BEGIN;
CREATE FUNCTION pg_temp.ok(c boolean, m text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF c IS TRUE THEN RAISE NOTICE 'OK %', m; ELSE RAISE EXCEPTION 'FALLA %', m; END IF;
END $$;

CREATE TEMP TABLE prueba ON COMMIT DROP AS
WITH c AS (
  INSERT INTO clientes(razon_social, doc_tipo, doc_nro, condicion_iva_afip_id)
  VALUES ('Agente de retención de prueba', 80, '30999999995',
          (SELECT min(id) FROM condiciones_iva_afip)) RETURNING id
), caja AS (
  INSERT INTO cuentas_bancarias(descripcion, clase, activo)
  VALUES ('CAJA PRUEBA RETENCIONES', 'caja', true) RETURNING id
)
SELECT c.id AS cliente_id, caja.id AS caja_id FROM c, caja;
GRANT SELECT ON prueba TO authenticated;

SET LOCAL ROLE authenticated;
DO $$
DECLARE
  p prueba;
  r recibos;
  v_hist recibo_retenciones;
  v_ganancias integer;
  v_iibb integer;
  v_iva integer;
  v_saldo_antes numeric;
  v_mov movimientos_tesoreria;
  v_n integer;
BEGIN
  SELECT * INTO p FROM prueba;
  SELECT id INTO v_ganancias FROM cuentas_bancarias WHERE tipo_retencion = 'Ganancias';
  SELECT id INTO v_iibb FROM cuentas_bancarias WHERE tipo_retencion = 'IIBB';
  SELECT id INTO v_iva FROM cuentas_bancarias WHERE tipo_retencion = 'IVA';

  PERFORM pg_temp.ok((SELECT count(*) = 4 AND bool_and(NOT cb.activo AND a.codigo = 'RETENCIONES')
                      FROM cuentas_bancarias cb JOIN agrupaciones_tesoreria a ON a.id = cb.agrupacion_id
                      WHERE cb.tipo_retencion IS NOT NULL),
    'una cuenta inactiva por impuesto, en la agrupación Retenciones');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM movimientos_tesoreria
                                 WHERE referencia_tipo = 'recibo_retenciones' AND anulado),
    'ningún movimiento de retención queda anulado');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM recibo_retenciones rr
                                 WHERE rr.origen_medio_id IS NULL AND NOT EXISTS (
                                   SELECT 1 FROM movimientos_tesoreria mt
                                   WHERE mt.referencia_tipo = 'recibo_retenciones' AND mt.referencia_id = rr.id)),
    'toda retención cargada en el CRM tiene su movimiento');

  SELECT COALESCE(sum(monto_con_signo), 0) INTO v_saldo_antes
  FROM movimientos_tesoreria WHERE cuenta_bancaria_id = v_ganancias AND NOT anulado;

  SELECT * INTO r FROM crear_recibo(p.cliente_id,
    jsonb_build_array(jsonb_build_object('tipo', 'efectivo', 'monto', 1000, 'cuenta_bancaria_id', p.caja_id)),
    '[]'::jsonb,
    '[{"tipo_retencion":"Ganancias","numero_certificado":"G-1","fecha":"2026-10-28","monto":123.45},
      {"tipo_retencion":"IIBB","numero_certificado":"B-1","fecha":"2026-10-28","monto":10,"jurisdiccion":"Buenos Aires"}]'::jsonb);
  PERFORM pg_temp.ok(r.total = 1133.45, 'total del recibo = medios + retenciones');

  SELECT mt.* INTO v_mov FROM movimientos_tesoreria mt
  JOIN recibo_retenciones x ON x.id = mt.referencia_id AND mt.referencia_tipo = 'recibo_retenciones'
  WHERE x.recibo_id = r.id AND x.tipo_retencion = 'Ganancias';
  PERFORM pg_temp.ok(v_mov.cuenta_bancaria_id = v_ganancias AND v_mov.monto = 123.45
                     AND v_mov.signo = 1 AND v_mov.fecha = r.fecha AND v_mov.origen = 'recibo'
                     AND NOT v_mov.anulado
                     AND v_mov.concepto = 'Retención Ganancias recibo ' || r.numero,
    'Ganancias: cobranza en su cuenta, con monto, fecha y concepto');
  PERFORM pg_temp.ok(EXISTS (SELECT 1 FROM movimientos_tesoreria mt
                             JOIN recibo_retenciones x ON x.id = mt.referencia_id
                             WHERE mt.referencia_tipo = 'recibo_retenciones' AND x.recibo_id = r.id
                               AND x.tipo_retencion = 'IIBB' AND mt.cuenta_bancaria_id = v_iibb
                               AND mt.monto = 10),
    'IIBB: cobranza en su cuenta');
  PERFORM pg_temp.ok((SELECT sum(monto_con_signo) FROM movimientos_tesoreria
                      WHERE cuenta_bancaria_id = v_ganancias AND NOT anulado) = v_saldo_antes + 123.45,
    'el saldo de la cuenta de Ganancias sube con la retención');
  PERFORM pg_temp.ok((SELECT count(*) = 1 AND sum(monto) = 1000 FROM movimientos_tesoreria
                      WHERE cuenta_bancaria_id = p.caja_id),
    'la caja recibe sólo el efectivo');

  BEGIN
    PERFORM crear_recibo(p.cliente_id,
      jsonb_build_array(jsonb_build_object('tipo', 'efectivo', 'monto', 1, 'cuenta_bancaria_id', v_ganancias)));
    RAISE EXCEPTION 'FALLA aceptó cobrar en efectivo en una cuenta de retenciones';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'Elegí una caja activa%' THEN RAISE; END IF;
  END;
  PERFORM pg_temp.ok(true, 'una cuenta de retenciones no sirve para cobrar');

  SELECT count(*) INTO v_n FROM movimientos_tesoreria WHERE referencia_tipo = 'recibo_retenciones';
  BEGIN
    PERFORM crear_recibo(p.cliente_id, '[]'::jsonb, '[]'::jsonb,
      '[{"tipo_retencion":"Ganancias","numero_certificado":"G-1","fecha":"2026-10-28","monto":5}]'::jsonb);
    RAISE EXCEPTION 'FALLA aceptó un certificado repetido';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'El certificado G-1 de Ganancias%' THEN RAISE; END IF;
  END;
  PERFORM pg_temp.ok((SELECT count(*) FROM movimientos_tesoreria
                      WHERE referencia_tipo = 'recibo_retenciones') = v_n,
    'un certificado repetido no deja movimiento');

  -- Una histórica como la del recibo 4302: sin certificado y con su movimiento en Ganancias.
  INSERT INTO recibo_retenciones(recibo_id, tipo_retencion, cuit_agente, monto, pendiente_documentacion)
  VALUES (r.id, 'Ganancias', '30999999995', 50, true) RETURNING * INTO v_hist;
  INSERT INTO movimientos_tesoreria(fecha, cuenta_bancaria_id, tipo_comprobante_tesoreria_id, signo, monto,
                                    origen, referencia_tipo, referencia_id, concepto)
  VALUES (r.fecha, v_ganancias, (SELECT id FROM tipos_comprobante_tesoreria WHERE codigo = 'COBRANZA'), 1, 50,
          'recibo', 'recibo_retenciones', v_hist.id, 'Retención Ganancias recibo ' || r.numero);
  PERFORM completar_certificado_retencion(v_hist.id, 'IVA', 'V-1', '2026-10-27');
  SELECT * INTO v_mov FROM movimientos_tesoreria
  WHERE referencia_tipo = 'recibo_retenciones' AND referencia_id = v_hist.id;
  PERFORM pg_temp.ok(v_mov.cuenta_bancaria_id = v_iva AND v_mov.monto = 50
                     AND v_mov.concepto = 'Retención IVA recibo ' || r.numero,
    'completar con otro impuesto pasa el movimiento a la cuenta del nuevo');

  INSERT INTO recibo_retenciones(recibo_id, tipo_retencion, cuit_agente, monto, pendiente_documentacion)
  VALUES (r.id, 'IIBB', '30999999995', 7, true) RETURNING * INTO v_hist;
  PERFORM completar_certificado_retencion(v_hist.id, 'SUSS', 'S-1', '2026-10-27');
  PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM movimientos_tesoreria
                                 WHERE referencia_tipo = 'recibo_retenciones' AND referencia_id = v_hist.id),
    'completar una histórica sin movimiento propio no crea ninguno');
END $$;

RESET ROLE;
ROLLBACK;
