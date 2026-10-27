\set ON_ERROR_STOP 1
BEGIN;
\ir recargar_asignaciones_gva54.sql
\ir verificar_backfill.sql
ROLLBACK;
\echo '── Ensayo finalizado con ROLLBACK (la base no se modificó).'
