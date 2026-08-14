-- =============================================================
-- CRM — Fase A / migración 0111: fixes de advisors post-0100..0110
--   1) FK facturas_compra_items.alicuota_iva_id sin índice de cobertura (perf lint 0001).
--   2) audit_trigger() no necesita EXECUTE de authenticated (corre como owner vía el trigger);
--      se revoca para limpiar el lint authenticated_security_definer_function_executable.
-- Idempotente.
-- =============================================================

CREATE INDEX IF NOT EXISTS idx_fc_items_alicuota ON facturas_compra_items(alicuota_iva_id);

REVOKE ALL ON FUNCTION audit_trigger() FROM authenticated;
