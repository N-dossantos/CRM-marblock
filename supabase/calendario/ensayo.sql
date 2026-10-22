-- Aplicar y probar en homologación, sin conservar los cambios ni los datos de prueba. Necesita la
-- tabla almanaque (20261020200000) y renombrarla con 20261021160000.
-- psql "$HOMO_DATABASE_URL" -X -f supabase/calendario/ensayo.sql
\set ON_ERROR_STOP 1
BEGIN;
INSERT INTO almanaque(fecha, texto) VALUES (CURRENT_DATE, 'Anotación previa al cambio');
\ir ../migrations/20261021160000_calendario.sql
\ir verificar.sql
SELECT pg_temp.ok(EXISTS(SELECT 1 FROM calendario WHERE titulo='Anotación previa al cambio' AND descripcion IS NULL),
  'las anotaciones existentes pasan con su texto como título');
SELECT count(*) || ' OK: ' || string_agg(m, ' · ' ORDER BY t) AS resultado FROM pg_temp.resultados;
ROLLBACK;
