-- =============================================================
-- CRM Ventas — Supabase migration 0004: harden function privileges
-- Two fixes surfaced by the security advisor after 0003:
--   1) anon could EXECUTE the SECURITY DEFINER write RPCs. Supabase's default
--      privileges GRANT EXECUTE on new public functions directly to `anon`, and
--      `REVOKE ... FROM PUBLIC` does NOT remove that direct grant. Revoke from anon
--      explicitly, and stop future public functions from leaking to anon by default.
--   2) helper functions had a mutable search_path (lint 0011). Pin it.
-- Idempotent — safe to re-run.
-- =============================================================

-- 1) Pin search_path on the helpers created in 0001/0003.
ALTER FUNCTION public.siguiente_numero(varchar)                    SET search_path = public, pg_temp;
ALTER FUNCTION public.recalcular_estado_factura(integer)           SET search_path = public, pg_temp;
ALTER FUNCTION public.set_updated_at()                             SET search_path = public, pg_temp;
ALTER FUNCTION public.crm_calc_totales(jsonb, numeric)             SET search_path = public, pg_temp;
ALTER FUNCTION public.crm_insert_presupuesto_items(integer, jsonb) SET search_path = public, pg_temp;

-- 2) Revoke EXECUTE from PUBLIC + anon on every current public function.
--    (Internal helpers are invoked from SECURITY DEFINER fns / triggers, which run as
--     the owner and don't need caller EXECUTE, so this can't break the RPCs.)
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
  END LOOP;
END $$;

-- 3) Re-grant EXECUTE to authenticated only on the caller-facing RPCs.
GRANT EXECUTE ON FUNCTION crear_presupuesto(integer, jsonb, numeric, text)                                 TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_presupuesto(integer, integer, jsonb, numeric, text, varchar, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION presupuesto_set_estado(integer, varchar)                                          TO authenticated;

-- 4) Future functions created in public must not auto-grant EXECUTE to anon.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;
