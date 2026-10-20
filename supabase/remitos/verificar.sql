-- =============================================================
-- PLAN_REMITOS_PENDIENTES — controles de verificar_asignaciones.sql en HOMOLOGACIÓN, con las
-- migraciones ya aplicadas.
--
-- Uso (nunca contra prod):
--   psql "$(cat ~/.arca/marblock/homo_db_url)" -X -f supabase/remitos/verificar.sql
--
-- Termina con ROLLBACK: los datos de prueba no quedan en la base.
-- =============================================================
\set ON_ERROR_STOP 1
BEGIN;
\ir verificar_asignaciones.sql
ROLLBACK;
\echo '── Fin: ROLLBACK (la base queda como estaba)'
