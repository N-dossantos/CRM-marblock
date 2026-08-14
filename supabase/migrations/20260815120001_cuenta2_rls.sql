-- =============================================================
-- CRM — Cuenta 2 / migración 0501: RLS de las tablas del circuito informal
-- Mismo modelo "shared staff" de 0002/0103/0201/0301: `authenticated` CRUD completo, `anon`
-- denegado. Todos los usuarios del sistema acceden a la sección (cuenta2.md §1.7), así que no
-- hace falta un rol nuevo — el modelo shared staff ya lo cubre.
-- SIN FORCE: las RPC SECURITY DEFINER corren como owner y FORCE bloquearía sus escrituras.
-- Idempotente.
-- =============================================================

DO $$
DECLARE
  t    TEXT;
  tbls TEXT[] := ARRAY[
    'clientes_cuenta2','proveedores_cuenta2','cuenta2_remitos','cuenta2_remito_items',
    'cuenta2_cheques','cuenta2_movimientos'
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
