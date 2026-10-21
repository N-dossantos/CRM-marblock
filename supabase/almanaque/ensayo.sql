-- Aplicar y probar en homologación, sin conservar tabla ni datos de prueba.
-- psql "$HOMO_DATABASE_URL" -X -f supabase/almanaque/ensayo.sql
\set ON_ERROR_STOP 1
BEGIN;
\ir ../migrations/20261020200000_almanaque.sql
\ir verificar.sql
ROLLBACK;
