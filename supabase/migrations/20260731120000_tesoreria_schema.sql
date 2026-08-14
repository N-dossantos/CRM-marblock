-- =============================================================
-- CRM — Fase C / migración 0200: Tesorería — schema
-- Companion de system_plan_fase_c_tesoreria.md §3.
--   * agrupaciones_tesoreria + tipos_comprobante_tesoreria (catálogos, con seed)
--   * ALTER cuentas_bancarias -> dimensión "cuenta" del ledger (clase/agrupacion/saldo_inicial)
--   * conciliaciones_bancarias  (antes del ledger: éste la referencia)
--   * movimientos_tesoreria     (LEDGER CENTRAL, ± monto, saldo por SUM(monto_con_signo))
--   * cheques_propios           (cheques que emitimos nosotros; impactan al 'pagado')
--   * ALTER pago_proveedor_medios -> cierra la FK cheque_propio_id que Fase A dejó abierta (§3.7)
--   * config_empresa (caja default para medios 'efectivo')
--   * adjunta audit_trigger() a las tablas cabecera/operativas nuevas (§7)
-- Idempotente. Mismas convenciones que 20260730120000_compras_schema.sql.
-- =============================================================

-- ──────────────────────────────────────────────────────────────
-- 1. AGRUPACIONES  (subtotales por grupo en reportes)
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS agrupaciones_tesoreria (
  id          SERIAL PRIMARY KEY,
  codigo      VARCHAR(20)  NOT NULL UNIQUE,
  descripcion VARCHAR(100) NOT NULL,
  orden       INTEGER NOT NULL DEFAULT 0,
  activo      BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO agrupaciones_tesoreria (codigo, descripcion, orden) VALUES
  ('BANCOS',  'Bancos',               1),
  ('CAJAS',   'Cajas',                2),
  ('VALORES', 'Valores a depositar',  3)
ON CONFLICT (codigo) DO NOTHING;

-- ──────────────────────────────────────────────────────────────
-- 2. TIPOS DE COMPROBANTE  (catálogo con signo sugerido; FK desde el ledger)
--    signo 0 = "lo define el movimiento" (transferencia/ajuste).
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tipos_comprobante_tesoreria (
  id          SERIAL PRIMARY KEY,
  codigo      VARCHAR(20)  NOT NULL UNIQUE,
  descripcion VARCHAR(100) NOT NULL,
  signo       SMALLINT NOT NULL DEFAULT 0 CHECK (signo IN (-1, 0, 1)),
  activo      BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO tipos_comprobante_tesoreria (codigo, descripcion, signo) VALUES
  ('DEP',                'Depósito',                      1),
  ('EXT',                'Extracción',                   -1),
  ('TRANSF',             'Transferencia entre cuentas',   0),
  ('ACRED_CHEQUE',       'Acreditación de cheque',        1),
  ('RECHAZO_CHEQUE',     'Rechazo de cheque',            -1),
  ('COBRANZA',           'Cobranza (recibo)',             1),
  ('PAGO_PROV',          'Pago a proveedor',             -1),
  ('PAGO_CHEQUE_PROPIO', 'Pago cheque propio',           -1),
  ('GASTO_BANCARIO',     'Gasto / comisión bancaria',    -1),
  ('AJUSTE',             'Ajuste',                        0)
ON CONFLICT (codigo) DO NOTHING;

-- ──────────────────────────────────────────────────────────────
-- 3. ALTER cuentas_bancarias -> dimensión "cuenta" del ledger  (§3.3)
--    clase 'caja' = efectivo, 'valores' = valores a depositar, 'banco' = cuenta bancaria.
-- ──────────────────────────────────────────────────────────────
ALTER TABLE cuentas_bancarias
  ADD COLUMN IF NOT EXISTS clase VARCHAR(20) NOT NULL DEFAULT 'banco'
    CHECK (clase IN ('banco','caja','valores')),
  ADD COLUMN IF NOT EXISTS agrupacion_id INTEGER REFERENCES agrupaciones_tesoreria(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS saldo_inicial DECIMAL(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS fecha_saldo_inicial DATE;

CREATE INDEX IF NOT EXISTS idx_cuentas_agrupacion ON cuentas_bancarias(agrupacion_id);

-- ──────────────────────────────────────────────────────────────
-- 4. CONCILIACIONES  (cabecera de un extracto conciliado; creada antes del ledger)
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS conciliaciones_bancarias (
  id                 SERIAL PRIMARY KEY,
  cuenta_bancaria_id INTEGER NOT NULL REFERENCES cuentas_bancarias(id),
  fecha_desde        DATE NOT NULL,
  fecha_hasta        DATE NOT NULL,
  saldo_extracto     DECIMAL(14,2) NOT NULL,          -- saldo final según el banco
  saldo_sistema      DECIMAL(14,2),                    -- snapshot del saldo calculado al cerrar
  diferencia         DECIMAL(14,2),                    -- saldo_extracto - saldo_sistema
  estado             VARCHAR(20) NOT NULL DEFAULT 'abierta' CHECK (estado IN ('abierta','cerrada')),
  observaciones      TEXT,
  created_at         TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_concil_cuenta ON conciliaciones_bancarias(cuenta_bancaria_id);

-- ──────────────────────────────────────────────────────────────
-- 5. MOVIMIENTOS_TESORERIA  (LEDGER CENTRAL)  §3.5
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS movimientos_tesoreria (
  id                            SERIAL PRIMARY KEY,
  numero                        VARCHAR(15),          -- opcional; alcanza el id (§14.4)
  fecha                         DATE NOT NULL DEFAULT CURRENT_DATE,
  cuenta_bancaria_id            INTEGER NOT NULL REFERENCES cuentas_bancarias(id),
  tipo_comprobante_tesoreria_id INTEGER NOT NULL REFERENCES tipos_comprobante_tesoreria(id),
  signo                         SMALLINT NOT NULL CHECK (signo IN (-1, 1)),
  monto                         DECIMAL(14,2) NOT NULL CHECK (monto >= 0),
  monto_con_signo               DECIMAL(14,2) GENERATED ALWAYS AS (monto * signo) STORED,
  origen                        VARCHAR(20) NOT NULL DEFAULT 'manual'
    CHECK (origen IN ('manual','recibo','pago_proveedor','cheque','cheque_propio','transferencia','conciliacion')),
  referencia_tipo               VARCHAR(30),          -- 'recibos','pagos_proveedor','cheques','cheques_propios','movimientos_tesoreria'
  referencia_id                 INTEGER,              -- polimórfico, sin FK (system_plan §5)
  concepto                      VARCHAR(300),
  conciliado                    BOOLEAN NOT NULL DEFAULT FALSE,
  conciliacion_id               INTEGER REFERENCES conciliaciones_bancarias(id) ON DELETE SET NULL,
  anulado                       BOOLEAN NOT NULL DEFAULT FALSE,
  created_at                    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at                    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mov_tes_cuenta_fecha ON movimientos_tesoreria(cuenta_bancaria_id, fecha);
CREATE INDEX IF NOT EXISTS idx_mov_tes_fecha        ON movimientos_tesoreria(fecha);
CREATE INDEX IF NOT EXISTS idx_mov_tes_tipo         ON movimientos_tesoreria(tipo_comprobante_tesoreria_id);
CREATE INDEX IF NOT EXISTS idx_mov_tes_ref          ON movimientos_tesoreria(referencia_tipo, referencia_id);
CREATE INDEX IF NOT EXISTS idx_mov_tes_concil       ON movimientos_tesoreria(conciliacion_id);
CREATE INDEX IF NOT EXISTS idx_mov_tes_pendientes   ON movimientos_tesoreria(cuenta_bancaria_id)
  WHERE conciliado = FALSE AND anulado = FALSE;   -- acelera la pantalla de conciliación

-- ──────────────────────────────────────────────────────────────
-- 6. CHEQUES_PROPIOS  (emitidos por nosotros; ciclo propio)  §3.6
--    emitido → entregado → pagado / rechazado / anulado. Impactan al 'pagado'.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cheques_propios (
  id                 SERIAL PRIMARY KEY,
  numero             VARCHAR(30)  NOT NULL,
  cuenta_bancaria_id INTEGER NOT NULL REFERENCES cuentas_bancarias(id),  -- chequera / banco emisor
  tipo               VARCHAR(10)  NOT NULL DEFAULT 'fisico' CHECK (tipo IN ('fisico','echeq')),
  beneficiario       VARCHAR(200),                                       -- texto libre
  proveedor_id       INTEGER REFERENCES proveedores(id) ON DELETE SET NULL,
  fecha_emision      DATE NOT NULL DEFAULT CURRENT_DATE,
  fecha_pago         DATE NOT NULL,                                      -- diferido: cuándo se paga
  monto              DECIMAL(14,2) NOT NULL,
  estado             VARCHAR(20)  NOT NULL DEFAULT 'emitido'
    CHECK (estado IN ('emitido','entregado','pagado','rechazado','anulado')),
  pago_proveedor_id  INTEGER REFERENCES pagos_proveedor(id) ON DELETE SET NULL,
  observaciones      TEXT,
  created_at         TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT cheques_propios_numero_cuenta_key UNIQUE (cuenta_bancaria_id, numero)
);

CREATE INDEX IF NOT EXISTS idx_cheques_propios_estado    ON cheques_propios(estado);
CREATE INDEX IF NOT EXISTS idx_cheques_propios_proveedor ON cheques_propios(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_cheques_propios_pago      ON cheques_propios(pago_proveedor_id);

-- ──────────────────────────────────────────────────────────────
-- 7. ALTER pago_proveedor_medios -> cerrar la FK que Fase A dejó abierta  (§3.7)
--    Fase A creó cheque_propio_id como INTEGER sin FK ("nullable hasta Fase C").
-- ──────────────────────────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'pago_proveedor_medios_cheque_propio_fk'
  ) THEN
    ALTER TABLE pago_proveedor_medios
      ADD CONSTRAINT pago_proveedor_medios_cheque_propio_fk
      FOREIGN KEY (cheque_propio_id) REFERENCES cheques_propios(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_ppm_cheque_propio ON pago_proveedor_medios(cheque_propio_id);

-- ──────────────────────────────────────────────────────────────
-- 8. CONFIG: caja default para medios 'efectivo'  (§3.8)
--    Se setea con el id real de la caja tras crearla; vacío = no se generan movimientos
--    de efectivo (se avisa, no se inventa cuenta).
-- ──────────────────────────────────────────────────────────────
INSERT INTO config_empresa (clave, valor) VALUES
  ('tesoreria_caja_default_id', '')
ON CONFLICT (clave) DO NOTHING;

-- ──────────────────────────────────────────────────────────────
-- 9. AUDITORÍA  (§7): adjuntar audit_trigger() a las tablas cabecera/operativas nuevas.
--    (No a los catálogos config: ruido sin valor de rastro.)
-- ──────────────────────────────────────────────────────────────
DO $$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'movimientos_tesoreria','cheques_propios','conciliaciones_bancarias','cuentas_bancarias'
  ]
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit ON %I;', t);
    EXECUTE format(
      'CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I
       FOR EACH ROW EXECUTE FUNCTION audit_trigger();', t);
  END LOOP;
END; $$;
