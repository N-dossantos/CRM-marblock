-- Numeración única por letra (PLAN_MIGRACION_TANGO.md, Tarea 6).
-- En el punto de venta 00002 Tango numera Factura A y Factura B por separado, así que existen 62 pares
-- con el mismo "00002-NNNNNNNN" (p. ej. FAC A 00002-00000002 y FAC B 00002-00000002), y una NC A y una
-- NC B comparten "00002-00000001". `facturas.numero` UNIQUE y `notas (tipo, numero)` UNIQUE los rechazarían
-- (y la app también chocaría apenas el contador de B alcance un número ya usado por A).
-- Mismo criterio que 0008_fix_notas_numero_unique: relajar la unicidad a la letra.
ALTER TABLE facturas DROP CONSTRAINT facturas_numero_key;
ALTER TABLE facturas ADD CONSTRAINT facturas_tipo_numero_key UNIQUE (tipo, numero);

ALTER TABLE notas DROP CONSTRAINT notas_tipo_numero_key;
ALTER TABLE notas ADD CONSTRAINT notas_tipo_letra_numero_key UNIQUE (tipo, tipo_letra, numero);

-- Compras (Tarea 7): 3 ND de proveedor "a cuenta" (ESTADO CTA) no cuelgan de ninguna factura; mismo criterio que
-- D2 en Ventas (notas.factura_id ya admite NULL en 20261006120000).
ALTER TABLE notas_compra ALTER COLUMN factura_compra_id DROP NOT NULL;
