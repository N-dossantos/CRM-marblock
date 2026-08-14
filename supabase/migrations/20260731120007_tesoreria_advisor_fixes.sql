-- =============================================================
-- CRM — Fase C / migración 0207: fixes de advisors post-0200..0206
--   * tes_emitir_cobranza es un HELPER INTERNO (sólo lo invocan crear_recibo y
--     generar_movimiento_desde_recibo, que corren como owner). El REVOKE FROM PUBLIC/anon
--     de 0205 no lo saca de `authenticated` porque el proyecto tiene un ALTER DEFAULT
--     PRIVILEGES que otorga EXECUTE a authenticated sobre funciones nuevas. Se revoca
--     explícitamente para que no quede expuesto como endpoint /rpc/ (limpia el lint
--     authenticated_security_definer_function_executable de un helper que no es API).
-- Idempotente.
-- =============================================================

REVOKE ALL ON FUNCTION tes_emitir_cobranza(integer, integer) FROM authenticated;
