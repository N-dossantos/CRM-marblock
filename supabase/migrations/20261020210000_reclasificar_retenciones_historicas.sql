-- Los recibos importados de Tango usaban cuentas de caja ficticias para retenciones.
-- Conservar el importe y el recibo, sin inventar fecha ni número de certificado.

ALTER TABLE recibo_retenciones
  ALTER COLUMN numero_certificado DROP NOT NULL,
  ALTER COLUMN fecha DROP NOT NULL;

ALTER TABLE recibo_retenciones
  ADD COLUMN pendiente_documentacion boolean NOT NULL DEFAULT false,
  ADD COLUMN origen_medio_id integer UNIQUE,
  ADD COLUMN detalle_origen varchar(100);

ALTER TABLE recibo_retenciones DROP CONSTRAINT recibo_retenciones_check;
ALTER TABLE recibo_retenciones ADD CONSTRAINT recibo_retenciones_documentacion_check
  CHECK (pendiente_documentacion OR
    (numero_certificado IS NOT NULL AND fecha IS NOT NULL AND
     (tipo_retencion <> 'IIBB' OR NULLIF(btrim(jurisdiccion), '') IS NOT NULL)));

-- Una cuenta de retenciones jamás es una caja disponible para un cobro nuevo.
UPDATE cuentas_bancarias SET activo = false
WHERE descripcion IN (
  'RETENCION GANANCIAS GENERADAS',
  'RETENCIONES DE GANANCIAS SUFRIDAS',
  'RETENCIONES IIBR SUFRIDAS',
  'RETENCION IVA SUFRIDO',
  'RETENCIONES S.U.S.S. SUFRIDAS'
);

INSERT INTO recibo_retenciones
  (recibo_id, tipo_retencion, cuit_agente, monto, pendiente_documentacion,
   origen_medio_id, detalle_origen)
SELECT rm.recibo_id,
  CASE
    WHEN rm.detalle IN ('RETENCIONES DE GANANCIAS SUFRIDAS', 'RETENCION GANANCIAS GENERADAS') THEN 'Ganancias'
    WHEN rm.detalle = 'RETENCION IVA SUFRIDO' THEN 'IVA'
    WHEN rm.detalle = 'RETENCIONES IIBR SUFRIDAS' THEN 'IIBB'
    ELSE 'SUSS'
  END,
  c.doc_nro, rm.monto, true, rm.id, rm.detalle
FROM recibo_medios rm
JOIN recibos r ON r.id = rm.recibo_id
JOIN clientes c ON c.id = r.cliente_id
WHERE rm.tipo = 'transferencia'
  AND rm.detalle IN (
    'RETENCION GANANCIAS GENERADAS',
    'RETENCIONES DE GANANCIAS SUFRIDAS',
    'RETENCIONES IIBR SUFRIDAS',
    'RETENCION IVA SUFRIDO',
    'RETENCIONES S.U.S.S. SUFRIDAS'
  );

-- La única imputación sin importe era un recibo con una sola factura. Fijar su
-- importe antes de retirar el medio anterior conserva todos los cálculos de saldo.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM recibo_facturas rf
    WHERE rf.importe IS NULL
      AND (SELECT count(*) FROM recibo_facturas x WHERE x.recibo_id = rf.recibo_id) <> 1
  ) THEN
    RAISE EXCEPTION 'Hay imputaciones antiguas sin importe y con varias facturas.';
  END IF;
END $$;

UPDATE recibo_facturas rf SET importe = r.total
FROM recibos r WHERE r.id = rf.recibo_id AND rf.importe IS NULL;

-- El único movimiento de tesorería asociado a estas cuentas fue una cobranza
-- ficticia no conciliada. Queda anulado y enlazado con el registro reclasificado.
UPDATE movimientos_tesoreria mt SET
  anulado = true,
  referencia_tipo = 'recibo_retenciones',
  referencia_id = rr.id
FROM recibo_retenciones rr
WHERE rr.pendiente_documentacion
  AND mt.origen = 'recibo'
  AND mt.referencia_tipo = 'recibo_medios'
  AND mt.referencia_id = rr.origen_medio_id
  AND mt.conciliado = false;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM movimientos_tesoreria mt
    JOIN recibo_retenciones rr ON rr.origen_medio_id = mt.referencia_id
    WHERE rr.pendiente_documentacion AND mt.origen = 'recibo'
      AND mt.referencia_tipo = 'recibo_medios' AND NOT mt.anulado
  ) THEN
    RAISE EXCEPTION 'Hay movimientos de retenciones históricas sin reclasificar.';
  END IF;
END $$;

DELETE FROM recibo_medios rm USING recibo_retenciones rr
WHERE rr.pendiente_documentacion AND rr.origen_medio_id = rm.id;

-- El período de los registros pendientes usa la fecha del recibo; el período
-- de los certificados completos usa la fecha del certificado.
CREATE OR REPLACE FUNCTION informe_retenciones_sufridas(p_desde date, p_hasta date)
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH registros AS (
    SELECT rr.fecha, rr.tipo_retencion, rr.codigo_regimen, rr.jurisdiccion,
           rr.numero_certificado, rr.cuit_agente, rr.monto,
           rr.pendiente_documentacion, rr.detalle_origen,
           r.fecha AS fecha_recibo, r.numero AS recibo_numero,
           c.razon_social AS cliente
    FROM recibo_retenciones rr
    JOIN recibos r ON r.id = rr.recibo_id
    JOIN clientes c ON c.id = r.cliente_id
    WHERE COALESCE(rr.fecha, r.fecha) BETWEEN p_desde AND p_hasta
  )
  SELECT jsonb_build_object(
    'retenciones', COALESCE(jsonb_agg(to_jsonb(registros) ORDER BY COALESCE(fecha, fecha_recibo), recibo_numero), '[]'::jsonb),
    'total', COALESCE(sum(monto), 0),
    'total_documentado', COALESCE(sum(monto) FILTER (WHERE NOT pendiente_documentacion), 0),
    'total_pendiente', COALESCE(sum(monto) FILTER (WHERE pendiente_documentacion), 0)
  ) FROM registros;
$$;

NOTIFY pgrst, 'reload schema';
