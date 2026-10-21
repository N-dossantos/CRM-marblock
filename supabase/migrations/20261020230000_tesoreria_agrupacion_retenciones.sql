-- Las cuentas donde Tango acumulaba retenciones no son cajas: en los saldos de tesorería se
-- muestran en su propia agrupación. Sus movimientos históricos quedan como estaban; el detalle
-- por recibo está en recibo_retenciones (20261020210000).
INSERT INTO agrupaciones_tesoreria (codigo, descripcion, orden)
SELECT 'RETENCIONES', 'Retenciones', 4
WHERE NOT EXISTS (SELECT 1 FROM agrupaciones_tesoreria WHERE codigo = 'RETENCIONES');

UPDATE cuentas_bancarias
SET agrupacion_id = (SELECT id FROM agrupaciones_tesoreria WHERE codigo = 'RETENCIONES')
WHERE descripcion IN (
  'RETENCION GANANCIAS GENERADAS',
  'RETENCIONES DE GANANCIAS SUFRIDAS',
  'RETENCIONES IIBR SUFRIDAS',
  'RETENCION IVA SUFRIDO',
  'RETENCIONES S.U.S.S. SUFRIDAS'
);
