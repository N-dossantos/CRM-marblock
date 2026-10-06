-- =============================================================
-- CRM Ventas — seed de configuración (SOLO instalación limpia / desarrollo)
-- En producción NO se corre esto: la config real (empresa, contadores, cuentas)
-- llega desde la importación de datos en vivo (ver PLAN_MIGRACION_TANGO.md).
-- Todos los INSERT usan ON CONFLICT DO NOTHING → seguro de re-ejecutar.
-- =============================================================

INSERT INTO config_empresa (clave, valor) VALUES
  ('razon_social',         'Tu Empresa S.A.'),
  ('cuit',                 '30-00000000-0'),
  ('direccion',            'Calle Falsa 123, Buenos Aires'),
  ('condicion_iva',        'Responsable Inscripto'),
  ('ingresos_brutos',      '000-000000-0'),
  ('inicio_actividades',   '01/01/2020'),
  ('iva_alicuota',         '21.00')
ON CONFLICT (clave) DO NOTHING;

-- Contadores de numeración. Puntos de arranque documentados en el README:
-- Factura A arranca en 2000 (próxima = 2001); el resto en 0 (próxima = 1); Recibo pv 00001.
INSERT INTO contadores (tipo, punto_venta, ultimo_numero, descripcion) VALUES
  ('factura_a',    '00002', 2000, 'Factura A'),
  ('factura_b',    '00002', 0,    'Factura B'),
  ('remito',       '00002', 0,    'Remito'),
  ('presupuesto',  '00002', 0,    'Presupuesto'),
  ('nota_credito', '00002', 0,    'Nota de Crédito'),
  ('nota_debito',  '00002', 0,    'Nota de Débito'),
  ('recibo',       '00001', 0,    'Recibo de Cobro')
ON CONFLICT (tipo) DO NOTHING;

INSERT INTO cuentas_bancarias (descripcion, banco, tipo_cuenta, numero, cbu) VALUES
  ('Banco Nación – Cta. Cte. 0110123456789012',  'Banco Nación Argentina', 'Cuenta Corriente', '123456789', '0110000000000123456789'),
  ('Banco Galicia – Cta. Cte. 0191987654321098', 'Banco Galicia',          'Cuenta Corriente', '987654321', '0191000000000987654321')
ON CONFLICT DO NOTHING;
