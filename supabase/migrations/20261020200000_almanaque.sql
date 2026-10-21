-- PLAN_MAESTRO §3.10: anotaciones manuales compartidas por el staff.
CREATE TABLE public.almanaque (
  id SERIAL PRIMARY KEY,
  fecha DATE NOT NULL,
  texto TEXT NOT NULL CHECK (length(btrim(texto)) BETWEEN 1 AND 200),
  hecha BOOLEAN NOT NULL DEFAULT false,
  hecha_en TIMESTAMPTZ,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_almanaque_hecha CHECK (hecha = (hecha_en IS NOT NULL))
);

CREATE INDEX idx_almanaque_fecha ON public.almanaque(fecha);

ALTER TABLE public.almanaque ENABLE ROW LEVEL SECURITY;
CREATE POLICY staff_all ON public.almanaque
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.almanaque TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.almanaque_id_seq TO authenticated;
REVOKE ALL ON public.almanaque FROM anon;
REVOKE ALL ON SEQUENCE public.almanaque_id_seq FROM anon;

CREATE TRIGGER trg_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.almanaque
  FOR EACH ROW EXECUTE FUNCTION public.audit_trigger();

NOTIFY pgrst, 'reload schema';
