-- =============================================================
-- CRM — Fase A / migración 0103: RLS de las tablas nuevas (Compras + Procesos Generales)
-- Mismo modelo "shared staff" de la migración 0002: `authenticated` CRUD completo, `anon`
-- denegado. SIN FORCE: las RPC SECURITY DEFINER corren como owner y FORCE bloquearía sus
-- propias escrituras (documentado en 0002).
--
-- Excepción: audit_log queda de SÓLO LECTURA para authenticated (integridad del rastro).
-- Los INSERT los hace únicamente audit_trigger() (SECURITY DEFINER, corre como owner y
-- puentea grants/policy). Nadie puede alterar/borrar el log vía PostgREST.
-- Idempotente.
-- =============================================================

DO $$
DECLARE
  t    TEXT;
  tbls TEXT[] := ARRAY[
    'proveedores','proveedor_alicuotas','materiales','alicuotas_iva',
    'facturas_compra','facturas_compra_items','factura_compra_iva_detalle',
    'remitos_compra','remito_compra_items','notas_compra','nota_compra_items',
    'pagos_proveedor','pago_proveedor_medios','pago_proveedor_facturas','retenciones',
    'tablas_generales'
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

-- Re-asegurar privilegios sobre tablas/secuencias nuevas (idempotente; las ALTER DEFAULT
-- PRIVILEGES de 0002 ya lo hacen automático, esto es cinturón + tiradores).
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT                 ON ALL SEQUENCES  IN SCHEMA public TO authenticated;
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;

-- ── audit_log: sólo lectura para staff, escritura sólo vía trigger owner ──
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_read ON public.audit_log;
CREATE POLICY staff_read ON public.audit_log FOR SELECT TO authenticated USING (true);
REVOKE INSERT, UPDATE, DELETE ON public.audit_log FROM authenticated;
REVOKE ALL ON public.audit_log FROM anon;
