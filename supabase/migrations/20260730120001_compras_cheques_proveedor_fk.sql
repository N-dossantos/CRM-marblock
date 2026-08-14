-- =============================================================
-- CRM — Fase A / migración 0101: cheques.proveedor_id (FK real)  §4.9
-- La cartera de cheques (migración 0001) tenía sólo `proveedor_destino` como texto libre,
-- porque no existía tabla proveedores. Ahora que existe (0100), se agrega la FK real.
-- Se MANTIENE proveedor_destino para registros históricos; la RPC crear_pago_proveedor
-- resuelve el handoff seteando cheques.proveedor_id + estado='entregado'.
-- Idempotente.
-- =============================================================

ALTER TABLE cheques
  ADD COLUMN IF NOT EXISTS proveedor_id INTEGER REFERENCES proveedores(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_cheques_proveedor ON cheques(proveedor_id);
