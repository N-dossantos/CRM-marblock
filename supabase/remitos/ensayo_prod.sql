-- =============================================================
-- PLAN_REMITOS_PENDIENTES — ensayo en PRODUCCIÓN, antes de aplicar: corre las migraciones dentro
-- de una transacción, controla el backfill contra los datos reales y deshace todo.
--
-- Lo corre Nico, desde la raíz del repo:
--   psql "$(cat .db_url)" -X -f supabase/remitos/ensayo_prod.sql
--
-- Termina con ROLLBACK: no aplica nada ni carga datos. Sólo incluye verificar_backfill.sql (sólo
-- lectura); verificar_asignaciones.sql crea datos de prueba y NUNCA va acá. Cada tarea del plan
-- agrega su migración (20261020160001 a 20261020160003) debajo de la primera.
-- =============================================================
\set ON_ERROR_STOP 1
BEGIN;
\ir ../migrations/20261020160000_remito_factura_asignaciones.sql
\ir verificar_backfill.sql
ROLLBACK;
\echo '── Fin: ROLLBACK (no se aplicó nada)'
