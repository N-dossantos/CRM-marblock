-- Conteos de todas las tablas que carga el ETL, con lo esperado del .bak del 2026-09-25 al lado.
-- Es el chequeo del paso 2 de la Tarea 10: correr la carga dos veces tiene que dar lo mismo.
-- Si cambia el .bak, los números de `esperado` salen de `python3 -m etl` (los imprime al final).
\pset footer off
WITH esperado(tabla, n) AS (VALUES
  ('clientes', 695), ('proveedores', 379), ('cuentas_bancarias', 11), ('plan_de_cuentas', 152),
  ('materiales', 19), ('productos', 25),
  ('facturas', 4596), ('factura_items', 10878), ('remitos', 6835), ('remito_items', 14685),
  ('notas', 375), ('nota_items', 578), ('recibos', 3701), ('recibo_facturas', 5299),
  ('recibo_medios', 7812), ('cheques', 4986),
  ('facturas_compra', 6191), ('factura_compra_iva_detalle', 7945), ('facturas_compra_items', 6200),
  ('notas_compra', 478), ('nota_compra_items', 531), ('pagos_proveedor', 3314),
  ('pago_proveedor_facturas', 7811), ('pago_proveedor_medios', 6815), ('percepciones_compra', 1974),
  ('movimientos_tesoreria', 9279), ('cheques_propios', 88),
  ('asientos_contables', 17460), ('asiento_items', 51379),
  -- Vacías por diseño: Tango no tiene presupuestos, ni percepciones de venta (H11), ni retenciones
  -- practicadas (H15), ni configuración de retención por proveedor (H14); Stock no tiene destino.
  ('presupuestos', 0), ('presupuesto_items', 0), ('percepciones', 0), ('retenciones', 0),
  ('proveedor_alicuotas', 0), ('remitos_compra', 0), ('remito_compra_items', 0)
),
real AS (
  SELECT t.table_name AS tabla,
         (xpath('/row/c/text()', query_to_xml(
            format('SELECT count(*) AS c FROM public.%I', t.table_name), false, true, '')))[1]::text::int AS n
  FROM information_schema.tables t
  WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
)
SELECT e.tabla, e.n AS esperado, r.n AS cargado,
       CASE WHEN r.n IS NULL THEN '✗ no existe'
            WHEN r.n = e.n   THEN 'OK'
            ELSE                  '⚠ ' || (r.n - e.n)::text END AS estado
FROM esperado e LEFT JOIN real r ON r.tabla = e.tabla
ORDER BY (CASE WHEN r.n IS DISTINCT FROM e.n THEN 0 ELSE 1 END), e.tabla;

\echo ''
\echo '-- contadores: la próxima emisión de la app sigue de acá (D5: reconfirmar contra ARCA) --'
SELECT tipo, punto_venta, ultimo_numero,
       punto_venta || '-' || lpad((ultimo_numero + 1)::text, 8, '0') AS proximo
FROM contadores ORDER BY tipo;
