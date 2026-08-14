-- =============================================================
-- CRM — Fase A / migración 0102: Procesos Generales — núcleo compartido
-- system_plan.md §3 (en paralelo a Compras) + §6:
--   * audit_log + audit_trigger()  — UN SOLO mecanismo compartido de auditoría, no una
--     tabla por sector. Se adjunta a las tablas nuevas de Compras AQUÍ (día uno), para
--     evitar un retrofit más caro sobre tablas ya en uso.
--   * tablas_generales — catálogo genérico único (como el módulo "Tablas Generales" de Tango).
-- (empleados / plan_de_cuentas quedan fuera de esta pasada: §6, Fase E bloqueada.)
-- Idempotente.
-- =============================================================

-- ──────────────────────────────────────────────────────────────
-- AUDIT LOG  (compartido)
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
  id               BIGSERIAL PRIMARY KEY,
  tabla            VARCHAR(63) NOT NULL,
  registro_id      TEXT,                    -- (to_jsonb(row)->>'id'); TEXT p/ ser genérico
  accion           VARCHAR(6)  NOT NULL CHECK (accion IN ('INSERT','UPDATE','DELETE')),
  datos_anteriores JSONB,
  datos_nuevos     JSONB,
  usuario_id       UUID REFERENCES auth.users(id) ON DELETE SET NULL,  -- auth.uid() del JWT
  ts               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_tabla_registro ON audit_log(tabla, registro_id);
CREATE INDEX IF NOT EXISTS idx_audit_ts             ON audit_log(ts);
CREATE INDEX IF NOT EXISTS idx_audit_usuario        ON audit_log(usuario_id);

-- Función genérica adjuntable a cualquier tabla. SECURITY DEFINER para poder escribir
-- audit_log aunque el rol que dispara la escritura no tenga INSERT sobre esa tabla
-- (audit_log queda de sólo-lectura para authenticated — ver migración de RLS).
-- auth.uid() lee el claim del JWT de la request y funciona igual dentro de una RPC
-- SECURITY DEFINER (el GUC request.jwt.claims sigue seteado por request).
CREATE OR REPLACE FUNCTION audit_trigger()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_old jsonb;
  v_new jsonb;
  v_id  text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old := to_jsonb(OLD); v_new := NULL;          v_id := v_old->>'id';
  ELSIF TG_OP = 'UPDATE' THEN
    v_old := to_jsonb(OLD); v_new := to_jsonb(NEW); v_id := v_new->>'id';
  ELSE
    v_old := NULL;          v_new := to_jsonb(NEW); v_id := v_new->>'id';
  END IF;

  INSERT INTO audit_log (tabla, registro_id, accion, datos_anteriores, datos_nuevos, usuario_id)
  VALUES (TG_TABLE_NAME, v_id, TG_OP, v_old, v_new, auth.uid());

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

ALTER FUNCTION audit_trigger() SET search_path = public, pg_temp;
REVOKE ALL ON FUNCTION audit_trigger() FROM PUBLIC, anon;  -- el trigger corre como owner igual

-- Adjuntar auditoría a las tablas cabecera/ABM nuevas de Compras (no a las de ítems: ruido).
DO $$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'proveedores','proveedor_alicuotas','materiales',
    'facturas_compra','remitos_compra','notas_compra','pagos_proveedor','retenciones'
  ]
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit ON %I;', t);
    EXECUTE format(
      'CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I
       FOR EACH ROW EXECUTE FUNCTION audit_trigger();', t);
  END LOOP;
END; $$;

-- ──────────────────────────────────────────────────────────────
-- TABLAS GENERALES  (catálogo genérico único)
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tablas_generales (
  id          SERIAL PRIMARY KEY,
  categoria   VARCHAR(50)  NOT NULL,   -- 'condicion_iva','condicion_compra','provincia','tipo_retencion',...
  codigo      VARCHAR(50)  NOT NULL,
  descripcion VARCHAR(200) NOT NULL,
  orden       INTEGER NOT NULL DEFAULT 0,
  activo      BOOLEAN NOT NULL DEFAULT TRUE,
  UNIQUE (categoria, codigo)
);

CREATE INDEX IF NOT EXISTS idx_tablas_generales_cat ON tablas_generales(categoria);
