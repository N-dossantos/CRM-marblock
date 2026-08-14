-- =============================================================
-- CRM — Fase E / migración 0300: Núcleo contable — schema
-- Companion de system_plan_fase_e_contabilidad.md §2/§4/§6.
--   * plan_de_cuentas      (árbol jerárquico self-FK; espeja el plan de Tango — §2.1)
--   * asientos_contables   (cabecera; correlativo por siguiente_numero('asiento') — §2.2/§4)
--   * asiento_items        (partida doble: debe XOR haber por línea — §2.2)
--   * contador 'asiento'   (patrón de pago_proveedor — §4)
--   * trigger de balanceo DEFERRABLE como cinturón (la RPC valida igual, §2.2)
--   * updated_at + audit_trigger() en cabeceras (no en asiento_items: ruido — §6)
--
-- ⚠ DDL redactado, NO bloqueado. Lo bloqueado es POBLAR plan_de_cuentas y la matriz de
--   imputación (§3/§8): dependen de las credenciales de SQL Server de Tango. Las tablas
--   quedan vacías hasta el cutover — aplicar cuando se desbloquee (§8).
-- Idempotente. Mismas convenciones que 20260731120000_tesoreria_schema.sql.
-- =============================================================

-- ──────────────────────────────────────────────────────────────
-- 1. PLAN DE CUENTAS  (jerárquico; sólo las hoja imputables reciben asientos)  §2.1
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS plan_de_cuentas (
  id              SERIAL PRIMARY KEY,
  codigo          VARCHAR(30)  NOT NULL UNIQUE,        -- '1.1.01.001' (espeja el código de Tango)
  descripcion     VARCHAR(200) NOT NULL,
  tipo_cuenta     VARCHAR(20)  NOT NULL
    CHECK (tipo_cuenta IN ('Activo','Pasivo','Patrimonio','Ingreso','Egreso','Orden')),
  cuenta_padre_id INTEGER REFERENCES plan_de_cuentas(id) ON DELETE RESTRICT,  -- self-FK, jerarquía
  nivel           SMALLINT NOT NULL DEFAULT 1,
  imputable       BOOLEAN NOT NULL DEFAULT TRUE,       -- sólo las hoja reciben asientos; las de agrupación no
  activo          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_plan_cuentas_padre ON plan_de_cuentas(cuenta_padre_id);
CREATE INDEX IF NOT EXISTS idx_plan_cuentas_tipo  ON plan_de_cuentas(tipo_cuenta);

-- ──────────────────────────────────────────────────────────────
-- 2. ASIENTOS CONTABLES  (cabecera de partida doble)  §2.2
--    referencia_tipo/referencia_id: enlace polimórfico sin FK (mismo criterio que
--    movimientos_tesoreria) — un asiento nace de una factura, un pago, un movimiento, o manual.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS asientos_contables (
  id              SERIAL PRIMARY KEY,
  numero          INTEGER NOT NULL,                    -- correlativo por ejercicio (siguiente_numero('asiento'))
  fecha           DATE NOT NULL,
  descripcion     VARCHAR(300) NOT NULL,
  origen          VARCHAR(20) NOT NULL DEFAULT 'manual'
    CHECK (origen IN ('manual','venta','compra','tesoreria','apertura','cierre','ajuste')),
  referencia_tipo VARCHAR(30),                         -- 'facturas','facturas_compra','pagos_proveedor',
  referencia_id   INTEGER,                             --   'recibos','movimientos_tesoreria' (polimórfico, sin FK)
  estado          VARCHAR(20) NOT NULL DEFAULT 'confirmado'
    CHECK (estado IN ('borrador','confirmado','anulado')),
  created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  UNIQUE (numero)
);

CREATE INDEX IF NOT EXISTS idx_asientos_fecha      ON asientos_contables(fecha);
CREATE INDEX IF NOT EXISTS idx_asientos_referencia ON asientos_contables(referencia_tipo, referencia_id);
CREATE INDEX IF NOT EXISTS idx_asientos_origen     ON asientos_contables(origen);

-- ──────────────────────────────────────────────────────────────
-- 3. ASIENTO_ITEMS  (líneas: una es debe O haber, nunca las dos)  §2.2
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS asiento_items (
  id         SERIAL PRIMARY KEY,
  asiento_id INTEGER NOT NULL REFERENCES asientos_contables(id) ON DELETE CASCADE,
  cuenta_id  INTEGER NOT NULL REFERENCES plan_de_cuentas(id),
  debe       DECIMAL(14,2) NOT NULL DEFAULT 0 CHECK (debe  >= 0),
  haber      DECIMAL(14,2) NOT NULL DEFAULT 0 CHECK (haber >= 0),
  detalle    VARCHAR(300),
  orden      INTEGER NOT NULL DEFAULT 0,
  CONSTRAINT chk_debe_xor_haber CHECK (NOT (debe > 0 AND haber > 0))   -- una línea es debe O haber
);

CREATE INDEX IF NOT EXISTS idx_asiento_items_asiento ON asiento_items(asiento_id);
CREATE INDEX IF NOT EXISTS idx_asiento_items_cuenta  ON asiento_items(cuenta_id);

-- ──────────────────────────────────────────────────────────────
-- 4. CONTADOR 'asiento'  (patrón de pago_proveedor, §4). punto_venta '00000'.
--    crear_asiento() llama siguiente_numero('asiento'). Reset por ejercicio = decisión
--    operativa del cierre anual, no de esquema.
-- ──────────────────────────────────────────────────────────────
INSERT INTO contadores (tipo, punto_venta, ultimo_numero, descripcion)
VALUES ('asiento', '00000', 0, 'Asiento contable')
ON CONFLICT (tipo) DO NOTHING;

-- ──────────────────────────────────────────────────────────────
-- 5. BALANCEO (cinturón)  §2.2
--    SUM(debe)=SUM(haber) no es expresable como CHECK de fila. La RPC crear_asiento lo
--    valida server-side; este CONSTRAINT TRIGGER DEFERRABLE es el cinturón que además
--    protege inserts manuales / la futura generación automática. Los 'borrador' pueden
--    estar descuadrados mientras se editan; sólo se exige balance al confirmar.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION asiento_balanceado_check()
RETURNS trigger
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_asiento_id integer := COALESCE(NEW.asiento_id, OLD.asiento_id);
  v_estado     text;
  v_debe       numeric;
  v_haber      numeric;
BEGIN
  SELECT estado INTO v_estado FROM asientos_contables WHERE id = v_asiento_id;
  IF v_estado IS NULL THEN RETURN NULL; END IF;         -- asiento borrado en cascada: nada que validar
  IF v_estado = 'borrador' THEN RETURN NULL; END IF;    -- los borradores pueden estar descuadrados

  SELECT COALESCE(SUM(debe), 0), COALESCE(SUM(haber), 0)
    INTO v_debe, v_haber
  FROM asiento_items WHERE asiento_id = v_asiento_id;

  IF round(v_debe, 2) <> round(v_haber, 2) THEN
    RAISE EXCEPTION 'Asiento % descuadrado: debe=% haber=% (deben ser iguales).',
      v_asiento_id, v_debe, v_haber;
  END IF;
  RETURN NULL;
END;
$$;

ALTER FUNCTION asiento_balanceado_check() SET search_path = public, pg_temp;

DROP TRIGGER IF EXISTS trg_asiento_balanceado ON asiento_items;
CREATE CONSTRAINT TRIGGER trg_asiento_balanceado
  AFTER INSERT OR UPDATE OR DELETE ON asiento_items
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION asiento_balanceado_check();

-- ──────────────────────────────────────────────────────────────
-- 6. TRIGGERS updated_at  (reusa set_updated_at() de la migración 0001)
-- ──────────────────────────────────────────────────────────────
DO $$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['plan_de_cuentas','asientos_contables']
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_updated_at ON %I;
       CREATE TRIGGER trg_updated_at BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END; $$;

-- ──────────────────────────────────────────────────────────────
-- 7. AUDITORÍA  (§6): audit_trigger() a plan_de_cuentas y asientos_contables.
--    No a asiento_items (ruido: ya cuelgan del asiento).
-- ──────────────────────────────────────────────────────────────
DO $$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['plan_de_cuentas','asientos_contables']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit ON %I;', t);
    EXECUTE format(
      'CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I
       FOR EACH ROW EXECUTE FUNCTION audit_trigger();', t);
  END LOOP;
END; $$;
