-- =============================================================
-- CRM — Fase E / migración 0301: RLS de las tablas del núcleo contable  §6
-- Mismo modelo "shared staff" de 0002/0103/0201: `authenticated` CRUD completo, `anon`
-- denegado. SIN FORCE: las RPC SECURITY DEFINER corren como owner y FORCE bloquearía sus
-- escrituras. (La escritura contable podría restringirse a un rol más chico en el futuro;
-- el modelo actual es shared staff — §6.) Idempotente.
-- =============================================================

DO $$
DECLARE
  t    TEXT;
  tbls TEXT[] := ARRAY[
    'plan_de_cuentas','asientos_contables','asiento_items'
  ];
BEGIN
  FOREACH t IN ARRAY tbls LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    EXECUTE format('DROP POLICY IF EXISTS staff_all ON public.%I;', t);
    EXECUTE format(
      'CREATE POLICY staff_all ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true);',
      t
    );
  END LOOP;
END $$;

-- Re-asegurar privilegios sobre tablas/secuencias nuevas (idempotente; ALTER DEFAULT
-- PRIVILEGES de 0002 ya lo hace automático, esto es cinturón + tiradores).
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT                 ON ALL SEQUENCES  IN SCHEMA public TO authenticated;
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;
