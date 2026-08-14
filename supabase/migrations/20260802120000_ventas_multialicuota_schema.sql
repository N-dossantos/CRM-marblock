-- =============================================================
-- CRM — Fase F / migración 0400: IVA multi-alícuota en Ventas — schema  (WS3)
-- system_plan_fase_f_integracion_ventas.md §4.1.
-- Ventas nació con IVA 21% fijo a nivel cabecera; los *_items no tienen alícuota. Compras ya
-- resolvió multi-alícuota y su infra es reutilizable: catálogo `alicuotas_iva` +
-- `crm_calc_totales_multi_alicuota` + `TotalesBoxMulti`/`calcTotalesMulti` en el frontend.
-- Esta migración sólo agrega la columna por ítem, ADITIVA y RETROCOMPATIBLE:
--   alicuota_iva_id NULLABLE; NULL ⇒ 21% (mismo criterio que crm_calc_totales_multi_alicuota).
-- Cero data migration: las filas y formularios viejos que no la mandan siguen liquidando 21%.
-- Idempotente.
-- =============================================================

-- Catálogo de alícuotas (lo crea Compras 0100; se repite idempotente para que esta fase sea
-- self-contained y no dependa del orden de aplicación).
CREATE TABLE IF NOT EXISTS alicuotas_iva (
  id          SERIAL PRIMARY KEY,
  descripcion VARCHAR(50) NOT NULL,
  porcentaje  DECIMAL(5,2) NOT NULL UNIQUE,
  activo      BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO alicuotas_iva (descripcion, porcentaje) VALUES
  ('Exento (0%)', 0),
  ('10.5%',       10.5),
  ('21%',         21),
  ('27%',         27)
ON CONFLICT (porcentaje) DO NOTHING;

-- Columna por ítem en los 4 comprobantes de Ventas. En presupuesto/remito no liquida IVA
-- fiscal, pero el ítem la arrastra para que la conversión presupuesto→factura / remito→factura
-- herede la alícuota.
ALTER TABLE presupuesto_items ADD COLUMN IF NOT EXISTS alicuota_iva_id INTEGER REFERENCES alicuotas_iva(id);
ALTER TABLE factura_items     ADD COLUMN IF NOT EXISTS alicuota_iva_id INTEGER REFERENCES alicuotas_iva(id);
ALTER TABLE remito_items      ADD COLUMN IF NOT EXISTS alicuota_iva_id INTEGER REFERENCES alicuotas_iva(id);
ALTER TABLE nota_items        ADD COLUMN IF NOT EXISTS alicuota_iva_id INTEGER REFERENCES alicuotas_iva(id);
