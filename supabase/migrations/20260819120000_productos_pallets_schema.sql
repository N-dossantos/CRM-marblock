-- =============================================================
-- CRM Ventas — productos.md: catálogo de 23 bloques/adoquines + 2 ítems especiales, y venta por
-- pallets. Agrega unidades_por_pallet/es_pallet_vacio/es_transporte a `productos` (spec §3.1.1) y
-- pallets/unidades_por_pallet a cada tabla de ítems de comprobante (spec §3.1.2, + nota_items:
-- comparte ItemsTable con presupuestos/remitos/facturas) para poder reconstruir el desglose
-- pallets/unidades al reabrir un comprobante ya guardado.
-- Idempotente: ADD COLUMN IF NOT EXISTS + INSERT ... ON CONFLICT (codigo) DO UPDATE.
-- =============================================================

ALTER TABLE public.productos
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS es_pallet_vacio      BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS es_transporte        BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.presupuesto_items
  ADD COLUMN IF NOT EXISTS pallets INTEGER,
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1;
ALTER TABLE public.factura_items
  ADD COLUMN IF NOT EXISTS pallets INTEGER,
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1;
ALTER TABLE public.remito_items
  ADD COLUMN IF NOT EXISTS pallets INTEGER,
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1;
ALTER TABLE public.nota_items
  ADD COLUMN IF NOT EXISTS pallets INTEGER,
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1;
ALTER TABLE public.cuenta2_remito_items
  ADD COLUMN IF NOT EXISTS pallets INTEGER,
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1;

-- La fila id=1 es un remanente de smoke-test (codigo '01') que YA tiene ítems reales de Cuenta 2
-- apuntando a producto_id=1 — no se puede borrar sin desvincular esos ítems (ON DELETE SET NULL).
-- Se corrige en el lugar para que pase a ser el producto '1' real; el UPSERT de abajo la completa.
UPDATE public.productos SET codigo = '1' WHERE id = 1 AND codigo = '01';

INSERT INTO public.productos
  (codigo, descripcion, precio_sin_iva, unidades_por_pallet, es_pallet_vacio, es_transporte, activo)
VALUES
  ('1',  'Bloque Liso de 19x19x39 Portante',        1572.08, 105, FALSE, FALSE, TRUE),
  ('2',  'Bloque Medio de 19x19x19 Liso',            1169.76, 180, FALSE, FALSE, TRUE),
  ('3',  'Bloque Dintel de 19x19x39 Liso',           2025.32, 105, FALSE, FALSE, TRUE),
  ('4',  'Bloque Liso de 19x19x39 Estandar',         1405.41, 105, FALSE, FALSE, TRUE),
  ('5',  'Bloque Media Altura de 19x9,5x39 Liso',     837.13, 150, FALSE, FALSE, TRUE),
  ('6',  'Bloque Liso de 14x19x39 Portante',         1237.13, 150, FALSE, FALSE, TRUE),
  ('7',  'Bloque Medio de 14x19x19 Liso',             919.45, 252, FALSE, FALSE, TRUE),
  ('8',  'Bloque Dintel de 14x19x39 Liso',           1524.90, 150, FALSE, FALSE, TRUE),
  ('9',  'Bloque Liso de 14x19x39 Estandar',         1112.96, 150, FALSE, FALSE, TRUE),
  ('10', 'Bloque Liso de 9x19x39',                   1146.91, 210, FALSE, FALSE, TRUE),
  ('11', 'Bloque de 19x19x39 Split',                 2697.25, 105, FALSE, FALSE, TRUE),
  ('12', 'Bloque de 19x19x39 Split Esquinero',       3096.75, 105, FALSE, FALSE, TRUE),
  ('13', 'Bloque Dintel de 19x19x39 Split',          3096.75, 105, FALSE, FALSE, TRUE),
  ('14', 'Bloque Medio de 19x19x39 Split',           1622.72, 180, FALSE, FALSE, TRUE),
  ('15', 'Bloque Medio de 19x19x39 Split Esquinero', 1840.96, 180, FALSE, FALSE, TRUE),
  ('16', 'Bloque de 14x19x39 Split',                 2472.48, 150, FALSE, FALSE, TRUE),
  ('17', 'Plaqueta de 7x19x39 Split',                2065.97, 216, FALSE, FALSE, TRUE),
  ('18', 'Adoquin Inter-trabado de 11x21x8',          537.82, 528, FALSE, FALSE, TRUE),
  ('19', 'Adoquin Inter-trabado de 11x21x6',          413.70, 624, FALSE, FALSE, TRUE),
  ('20', 'Adoquin Holanda de 10x20x8',                439.71, 600, FALSE, FALSE, TRUE),
  ('21', 'Adoquin Holanda de 10x20x6',                353.05, 720, FALSE, FALSE, TRUE),
  ('22', 'Cubremuros 26x19x4,5',                     1154.50, 256, FALSE, FALSE, TRUE),
  ('23', 'Cordon 28x13x50',                         11020.73,  56, FALSE, FALSE, TRUE),
  ('24', 'Pallet',                    4000.00,   1, TRUE,  FALSE, TRUE),
  ('25', 'Servicio de Transporte',                  300000.00,   1, FALSE, TRUE,  TRUE)
ON CONFLICT (codigo) DO UPDATE SET
  descripcion         = EXCLUDED.descripcion,
  precio_sin_iva       = EXCLUDED.precio_sin_iva,
  unidades_por_pallet  = EXCLUDED.unidades_por_pallet,
  es_pallet_vacio      = EXCLUDED.es_pallet_vacio,
  es_transporte        = EXCLUDED.es_transporte,
  activo               = TRUE,
  updated_at           = NOW();
