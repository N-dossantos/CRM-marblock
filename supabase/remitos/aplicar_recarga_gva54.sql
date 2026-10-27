\set ON_ERROR_STOP 1
BEGIN;
\ir recargar_asignaciones_gva54.sql
COMMIT;
\echo '── Recarga aplicada con éxito (COMMIT).'
