-- =============================================================
-- CRM Ventas — Supabase migration 0002: Row-Level Security
-- Model: "shared staff". Every authenticated user gets full CRUD; anon is denied.
-- This mirrors the previous LAN behaviour (everyone on the network saw everything),
-- except access is now gated behind a Supabase Auth login instead of being open.
--
-- Because the frontend talks to PostgREST with the PUBLIC anon key, RLS is the only
-- thing standing between the internet and the invoices. Two independent guards:
--   1) No table/sequence privileges are granted to `anon` (REVOKE below).
--   2) RLS is ENABLED with a single policy that only allows the `authenticated` role.
-- =============================================================

DO $$
DECLARE
  t    TEXT;
  tbls TEXT[] := ARRAY[
    'config_empresa','contadores','cuentas_bancarias','clientes','productos',
    'presupuestos','presupuesto_items','remitos','remito_items','facturas','factura_items',
    'notas','nota_items','recibos','recibo_facturas','recibo_medios','cheques'
  ];
BEGIN
  FOREACH t IN ARRAY tbls LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', t);
    -- Sin FORCE a propósito: las RPC SECURITY DEFINER corren como owner de la tabla y deben
    -- poder escribir. FORCE haría que RLS también aplique al owner y podría bloquearlas si el
    -- owner no tiene BYPASSRLS. (Verificar con una escritura de prueba al aplicar la migración.)
    EXECUTE format('DROP POLICY IF EXISTS staff_all ON public.%I;', t);
    -- Full access for any logged-in staff member; anon has no policy -> denied.
    EXECUTE format(
      'CREATE POLICY staff_all ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true);',
      t
    );
  END LOOP;
END $$;

-- ── Privilegios de tabla/secuencia ────────────────────────────
-- authenticated: CRUD completo. anon: nada.
GRANT USAGE ON SCHEMA public TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT                 ON ALL SEQUENCES  IN SCHEMA public TO authenticated;

REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;

-- Que las tablas/secuencias futuras hereden el mismo criterio.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon;

-- NOTA: el rol `service_role` (usado por Edge Functions / tareas de servidor) ignora RLS
-- por diseño de Supabase; no se le otorga nada aquí porque ya lo tiene.
