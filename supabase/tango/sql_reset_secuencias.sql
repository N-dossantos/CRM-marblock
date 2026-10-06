-- Resincroniza cada secuencia SERIAL de `public` con el MAX(id) de su tabla.
-- PLAN_MAESTRO.md §3.2.5 paso 2: el COPY inserta ids explícitos SIN avanzar la secuencia, así que
-- el próximo INSERT de la app colisionaría. El ETL ya emite un setval por cada tabla que carga;
-- esto cubre las demás (y es idempotente).
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT s.relname AS seq, t.relname AS tbl, a.attname AS col
    FROM pg_class s
    JOIN pg_depend d    ON d.objid = s.oid AND d.deptype = 'a'
    JOIN pg_class t     ON t.oid = d.refobjid
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
    WHERE s.relkind = 'S' AND t.relnamespace = 'public'::regnamespace
  LOOP
    EXECUTE format(
      'SELECT setval(%L, COALESCE((SELECT MAX(%I) FROM %I), 1), (SELECT MAX(%I) IS NOT NULL FROM %I))',
      r.seq, r.col, r.tbl, r.col, r.tbl);
  END LOOP;
END $$;
