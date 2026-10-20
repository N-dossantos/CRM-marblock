-- =============================================================
-- PLAN_REMITOS_PENDIENTES — ensayo en HOMOLOGACIÓN: aplica las migraciones dentro de una
-- transacción, corre los controles de verificar_asignaciones.sql y deshace todo.
--
-- Uso (nunca contra prod), con las migraciones todavía sin aplicar:
--   psql "$(cat ~/.arca/marblock/homo_db_url)" -X -f supabase/remitos/ensayo.sql
--
-- Termina con ROLLBACK: la base queda como estaba. Cada tarea del plan agrega su migración
-- antes de verificar_asignaciones.sql. semilla_backfill.sql va antes de las migraciones: carga
-- remitos con factura_id para que el backfill tenga qué asignar (control 1.3).
-- =============================================================
\set ON_ERROR_STOP 1
BEGIN;
\ir semilla_backfill.sql
\ir ../migrations/20261020160000_remito_factura_asignaciones.sql
\ir ../migrations/20261020160001_rpc_remitos_asignaciones.sql
\ir verificar_asignaciones.sql
ROLLBACK;
\echo '── Fin: ROLLBACK (la base queda como estaba)'
