-- =============================================================
-- CRM Ventas — Supabase migration 0001: schema
-- Port of backend/src/db/schema.sql (structure + functions + triggers + indexes).
-- Differences from the original file, on purpose:
--   * NO seed INSERTs here — config/contadores/cuentas come from the live-data
--     import (see supabase/DATA_MIGRATION.md). Fresh installs load supabase/seed.sql.
--   * The circular FK remitos.factura_id <-> facturas.remito_id is broken: facturas
--     is created first, then remitos.factura_id is added with ALTER TABLE at the end.
-- Idempotent (IF NOT EXISTS) so it is safe to re-run.
-- =============================================================

-- ──────────────────────────────────────────────────────────────
-- CONFIGURACIÓN Y CONTADORES
-- ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS config_empresa (
  clave VARCHAR(50) PRIMARY KEY,
  valor TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS contadores (
  tipo          VARCHAR(20) PRIMARY KEY,
  punto_venta   CHAR(5)     NOT NULL DEFAULT '00002',
  ultimo_numero INTEGER     NOT NULL DEFAULT 0,
  descripcion   VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS cuentas_bancarias (
  id          SERIAL PRIMARY KEY,
  descripcion VARCHAR(200) NOT NULL,
  banco       VARCHAR(100),
  tipo_cuenta VARCHAR(50),
  numero      VARCHAR(50),
  cbu         VARCHAR(22),
  alias       VARCHAR(50),
  activo      BOOLEAN NOT NULL DEFAULT TRUE
);

-- ──────────────────────────────────────────────────────────────
-- CLIENTES
-- ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS clientes (
  id                   SERIAL PRIMARY KEY,
  razon_social         VARCHAR(200) NOT NULL,
  cuit                 VARCHAR(13)  NOT NULL UNIQUE,
  condicion_iva        VARCHAR(50)  NOT NULL DEFAULT 'Resp. Inscripto',
  direccion            VARCHAR(300),
  localidad            VARCHAR(100),
  provincia            VARCHAR(100) DEFAULT 'Buenos Aires',
  telefono             VARCHAR(50),
  email                VARCHAR(150),
  descuento_porcentaje DECIMAL(5,2) NOT NULL DEFAULT 0
                         CHECK (descuento_porcentaje IN (0, 10, 15, 20)),
  notas                TEXT,
  activo               BOOLEAN NOT NULL DEFAULT TRUE,
  created_at           TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────────────────────
-- PRODUCTOS / LISTA DE PRECIOS
-- ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS productos (
  id              SERIAL PRIMARY KEY,
  codigo          VARCHAR(20)  NOT NULL UNIQUE,
  descripcion     VARCHAR(300) NOT NULL,
  precio_sin_iva  DECIMAL(14,2) NOT NULL DEFAULT 0,
  activo          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────────────────────
-- PRESUPUESTOS
-- ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS presupuestos (
  id                SERIAL PRIMARY KEY,
  numero            VARCHAR(15)  NOT NULL UNIQUE,
  punto_venta       CHAR(5)      NOT NULL,
  numero_comp       INTEGER      NOT NULL,
  fecha             DATE         NOT NULL,
  fecha_vcto        DATE         NOT NULL,
  cliente_id        INTEGER      NOT NULL REFERENCES clientes(id),
  descuento_general DECIMAL(5,2) NOT NULL DEFAULT 0,
  subtotal          DECIMAL(14,2) NOT NULL DEFAULT 0,
  descuento_monto   DECIMAL(14,2) NOT NULL DEFAULT 0,
  neto_gravado      DECIMAL(14,2) NOT NULL DEFAULT 0,
  iva_monto         DECIMAL(14,2) NOT NULL DEFAULT 0,
  total             DECIMAL(14,2) NOT NULL DEFAULT 0,
  estado            VARCHAR(20)  NOT NULL DEFAULT 'borrador',
  observaciones     TEXT,
  created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_pres_estado CHECK (estado IN ('borrador','enviado','aceptado','vencido','convertido','rechazado'))
);

CREATE TABLE IF NOT EXISTS presupuesto_items (
  id              SERIAL PRIMARY KEY,
  presupuesto_id  INTEGER NOT NULL REFERENCES presupuestos(id) ON DELETE CASCADE,
  producto_id     INTEGER REFERENCES productos(id) ON DELETE SET NULL,
  descripcion     VARCHAR(300) NOT NULL,
  cantidad        DECIMAL(10,3) NOT NULL DEFAULT 1,
  precio_unitario DECIMAL(14,2) NOT NULL,
  descuento_item  DECIMAL(5,2)  NOT NULL DEFAULT 0,
  subtotal        DECIMAL(14,2) NOT NULL,
  orden           INTEGER NOT NULL DEFAULT 0
);

-- ──────────────────────────────────────────────────────────────
-- FACTURAS  (created before remitos to break the circular FK)
-- ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS facturas (
  id                SERIAL PRIMARY KEY,
  numero            VARCHAR(15)  NOT NULL UNIQUE,
  punto_venta       CHAR(5)      NOT NULL,
  numero_comp       INTEGER      NOT NULL,
  tipo              CHAR(1)      NOT NULL DEFAULT 'A',
  fecha             DATE         NOT NULL,
  cliente_id        INTEGER      NOT NULL REFERENCES clientes(id),
  remito_id         INTEGER,  -- FK added after remitos exists (see ALTER below)
  presupuesto_id    INTEGER      REFERENCES presupuestos(id) ON DELETE SET NULL,
  descuento_general DECIMAL(5,2) NOT NULL DEFAULT 0,
  subtotal          DECIMAL(14,2) NOT NULL DEFAULT 0,
  descuento_monto   DECIMAL(14,2) NOT NULL DEFAULT 0,
  neto_gravado      DECIMAL(14,2) NOT NULL DEFAULT 0,
  iva_alicuota      DECIMAL(5,2)  NOT NULL DEFAULT 21.00,
  iva_monto         DECIMAL(14,2) NOT NULL DEFAULT 0,
  total             DECIMAL(14,2) NOT NULL DEFAULT 0,
  estado            VARCHAR(20)  NOT NULL DEFAULT 'pendiente',
  observaciones     TEXT,
  created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_fac_tipo   CHECK (tipo IN ('A','B')),
  CONSTRAINT chk_fac_estado CHECK (estado IN ('pendiente','parcial','cobrada','anulada'))
);

CREATE TABLE IF NOT EXISTS factura_items (
  id              SERIAL PRIMARY KEY,
  factura_id      INTEGER NOT NULL REFERENCES facturas(id) ON DELETE CASCADE,
  producto_id     INTEGER REFERENCES productos(id) ON DELETE SET NULL,
  descripcion     VARCHAR(300) NOT NULL,
  cantidad        DECIMAL(10,3) NOT NULL DEFAULT 1,
  precio_unitario DECIMAL(14,2) NOT NULL,
  descuento_item  DECIMAL(5,2)  NOT NULL DEFAULT 0,
  subtotal        DECIMAL(14,2) NOT NULL,
  orden           INTEGER NOT NULL DEFAULT 0
);

-- ──────────────────────────────────────────────────────────────
-- REMITOS
-- ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS remitos (
  id              SERIAL PRIMARY KEY,
  numero          VARCHAR(15)  NOT NULL UNIQUE,
  punto_venta     CHAR(5)      NOT NULL,
  numero_comp     INTEGER      NOT NULL,
  fecha           DATE         NOT NULL,
  cliente_id      INTEGER      NOT NULL REFERENCES clientes(id),
  factura_id      INTEGER,  -- FK added below (facturas already exists, but kept with the pair for clarity)
  presupuesto_id  INTEGER      REFERENCES presupuestos(id) ON DELETE SET NULL,
  estado          VARCHAR(20)  NOT NULL DEFAULT 'pendiente',
  observaciones   TEXT,
  created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_rem_estado CHECK (estado IN ('pendiente','facturado','anulado'))
);

CREATE TABLE IF NOT EXISTS remito_items (
  id              SERIAL PRIMARY KEY,
  remito_id       INTEGER NOT NULL REFERENCES remitos(id) ON DELETE CASCADE,
  producto_id     INTEGER REFERENCES productos(id) ON DELETE SET NULL,
  descripcion     VARCHAR(300) NOT NULL,
  cantidad        DECIMAL(10,3) NOT NULL DEFAULT 1,
  precio_unitario DECIMAL(14,2) NOT NULL DEFAULT 0,
  descuento_item  DECIMAL(5,2)  NOT NULL DEFAULT 0,
  subtotal        DECIMAL(14,2) NOT NULL DEFAULT 0,
  orden           INTEGER NOT NULL DEFAULT 0
);

-- Cierre de las FK circulares entre remitos y facturas.
ALTER TABLE remitos
  DROP CONSTRAINT IF EXISTS remitos_factura_id_fkey,
  ADD  CONSTRAINT remitos_factura_id_fkey
       FOREIGN KEY (factura_id) REFERENCES facturas(id) ON DELETE SET NULL;

ALTER TABLE facturas
  DROP CONSTRAINT IF EXISTS facturas_remito_id_fkey,
  ADD  CONSTRAINT facturas_remito_id_fkey
       FOREIGN KEY (remito_id) REFERENCES remitos(id) ON DELETE SET NULL;

-- ──────────────────────────────────────────────────────────────
-- NOTAS DE CRÉDITO / DÉBITO
-- ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS notas (
  id              SERIAL PRIMARY KEY,
  -- Unicidad por (tipo, numero): NC y ND son series independientes con contadores separados
  -- que arrancan ambas en 00002-00000001. UNIQUE global sobre `numero` las haría chocar.
  -- (En la BD viva esto lo corrige la migración 0008; aquí queda bien para instalaciones nuevas.)
  numero          VARCHAR(15)  NOT NULL,
  punto_venta     CHAR(5)      NOT NULL,
  numero_comp     INTEGER      NOT NULL,
  tipo            CHAR(2)      NOT NULL,  -- NC, ND
  tipo_letra      CHAR(1)      NOT NULL DEFAULT 'A',
  fecha           DATE         NOT NULL,
  factura_id      INTEGER      NOT NULL REFERENCES facturas(id),
  motivo          VARCHAR(300),
  subtotal        DECIMAL(14,2) NOT NULL DEFAULT 0,
  descuento_monto DECIMAL(14,2) NOT NULL DEFAULT 0,
  neto_gravado    DECIMAL(14,2) NOT NULL DEFAULT 0,
  iva_monto       DECIMAL(14,2) NOT NULL DEFAULT 0,
  total           DECIMAL(14,2) NOT NULL DEFAULT 0,
  observaciones   TEXT,
  created_at      TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_nota_tipo CHECK (tipo IN ('NC','ND')),
  CONSTRAINT notas_tipo_numero_key UNIQUE (tipo, numero)
);

CREATE TABLE IF NOT EXISTS nota_items (
  id              SERIAL PRIMARY KEY,
  nota_id         INTEGER NOT NULL REFERENCES notas(id) ON DELETE CASCADE,
  producto_id     INTEGER REFERENCES productos(id) ON DELETE SET NULL,
  descripcion     VARCHAR(300) NOT NULL,
  cantidad        DECIMAL(10,3) NOT NULL DEFAULT 1,
  precio_unitario DECIMAL(14,2) NOT NULL,
  descuento_item  DECIMAL(5,2)  NOT NULL DEFAULT 0,
  subtotal        DECIMAL(14,2) NOT NULL,
  orden           INTEGER NOT NULL DEFAULT 0
);

-- ──────────────────────────────────────────────────────────────
-- RECIBOS DE COBRO
-- ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS recibos (
  id           SERIAL PRIMARY KEY,
  numero       VARCHAR(15)  NOT NULL UNIQUE,
  punto_venta  CHAR(5)      NOT NULL,
  numero_comp  INTEGER      NOT NULL,
  fecha        DATE         NOT NULL,
  cliente_id   INTEGER      NOT NULL REFERENCES clientes(id),
  total        DECIMAL(14,2) NOT NULL DEFAULT 0,
  observaciones TEXT,
  created_at   TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS recibo_facturas (
  id          SERIAL PRIMARY KEY,
  recibo_id   INTEGER NOT NULL REFERENCES recibos(id) ON DELETE CASCADE,
  factura_id  INTEGER NOT NULL REFERENCES facturas(id)
);

CREATE TABLE IF NOT EXISTS recibo_medios (
  id            SERIAL PRIMARY KEY,
  recibo_id     INTEGER NOT NULL REFERENCES recibos(id) ON DELETE CASCADE,
  tipo          VARCHAR(20) NOT NULL,  -- efectivo, transferencia, cheque, echeq
  detalle       VARCHAR(300),          -- nombre cuenta bancaria
  numero_cheque VARCHAR(30),
  banco         VARCHAR(100),
  titular       VARCHAR(200),
  cuit_titular  VARCHAR(13),
  fecha_emision DATE,
  fecha_vcto    DATE,
  monto         DECIMAL(14,2) NOT NULL,
  CONSTRAINT chk_medio_tipo CHECK (tipo IN ('efectivo','transferencia','cheque','echeq'))
);

-- ──────────────────────────────────────────────────────────────
-- CHEQUES DE TERCEROS (CARTERA)
-- ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS cheques (
  id               SERIAL PRIMARY KEY,
  numero           VARCHAR(30)  NOT NULL,
  tipo             VARCHAR(10)  NOT NULL DEFAULT 'fisico',  -- fisico, echeq
  banco            VARCHAR(100) NOT NULL,
  titular          VARCHAR(200),
  cuit_titular     VARCHAR(13),
  fecha_emision    DATE         NOT NULL,
  fecha_vcto       DATE         NOT NULL,
  monto            DECIMAL(14,2) NOT NULL,
  cliente_id       INTEGER      REFERENCES clientes(id) ON DELETE SET NULL,  -- cliente que lo entregó
  proveedor_destino VARCHAR(200),  -- a quién se entregó (si aplica)
  observaciones    TEXT,
  estado           VARCHAR(20)  NOT NULL DEFAULT 'en_cartera',
  created_at       TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_cheque_estado CHECK (estado IN ('en_cartera','depositado','entregado','rechazado_banco'))
);

-- ──────────────────────────────────────────────────────────────
-- FUNCIÓN: siguiente número de comprobante (THREAD-SAFE)
-- ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION siguiente_numero(p_tipo VARCHAR)
RETURNS TABLE (punto_venta CHAR(5), numero INTEGER, numero_formateado VARCHAR) AS $$
DECLARE
  v_pv   CHAR(5);
  v_num  INTEGER;
BEGIN
  UPDATE contadores
  SET ultimo_numero = ultimo_numero + 1
  WHERE tipo = p_tipo
  RETURNING contadores.punto_venta, contadores.ultimo_numero
  INTO v_pv, v_num;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contador no encontrado para tipo: %', p_tipo;
  END IF;

  RETURN QUERY SELECT
    v_pv,
    v_num,
    (v_pv || '-' || LPAD(v_num::TEXT, 8, '0'))::VARCHAR;
END;
$$ LANGUAGE plpgsql;

-- ──────────────────────────────────────────────────────────────
-- FUNCIÓN: recalcular estado de factura por cobros
-- ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION recalcular_estado_factura(p_factura_id INTEGER)
RETURNS VOID AS $$
DECLARE
  v_total    DECIMAL(14,2);
  v_cobrado  DECIMAL(14,2);
  v_nc_total DECIMAL(14,2);
BEGIN
  SELECT total INTO v_total FROM facturas WHERE id = p_factura_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- Suma de recibos imputados a esta factura
  SELECT COALESCE(SUM(rm.monto), 0) INTO v_cobrado
  FROM recibo_medios rm
  JOIN recibos r ON r.id = rm.recibo_id
  JOIN recibo_facturas rf ON rf.recibo_id = r.id
  WHERE rf.factura_id = p_factura_id;

  -- Suma de notas de crédito (reducen saldo)
  SELECT COALESCE(SUM(total), 0) INTO v_nc_total
  FROM notas
  WHERE factura_id = p_factura_id AND tipo = 'NC';

  v_cobrado := v_cobrado + v_nc_total;

  UPDATE facturas SET
    estado = CASE
      WHEN v_cobrado <= 0                        THEN 'pendiente'
      WHEN v_cobrado >= v_total - 0.01           THEN 'cobrada'
      ELSE                                            'parcial'
    END,
    updated_at = NOW()
  WHERE id = p_factura_id AND estado != 'anulada';
END;
$$ LANGUAGE plpgsql;

-- ──────────────────────────────────────────────────────────────
-- TRIGGER: actualizar updated_at
-- ──────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DO $$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['clientes','productos','presupuestos','remitos','facturas','cheques']
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_updated_at ON %I;
       CREATE TRIGGER trg_updated_at BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END; $$;

-- ──────────────────────────────────────────────────────────────
-- ÍNDICES
-- ──────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_clientes_razon      ON clientes(razon_social);
CREATE INDEX IF NOT EXISTS idx_clientes_cuit        ON clientes(cuit);
CREATE INDEX IF NOT EXISTS idx_productos_codigo     ON productos(codigo);
CREATE INDEX IF NOT EXISTS idx_facturas_cliente     ON facturas(cliente_id);
CREATE INDEX IF NOT EXISTS idx_facturas_estado      ON facturas(estado);
CREATE INDEX IF NOT EXISTS idx_facturas_fecha       ON facturas(fecha);
CREATE INDEX IF NOT EXISTS idx_remitos_cliente      ON remitos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_remitos_estado       ON remitos(estado);
CREATE INDEX IF NOT EXISTS idx_presupuestos_cliente ON presupuestos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_presupuestos_estado  ON presupuestos(estado);
CREATE INDEX IF NOT EXISTS idx_notas_factura        ON notas(factura_id);
CREATE INDEX IF NOT EXISTS idx_recibos_cliente      ON recibos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_cheques_estado       ON cheques(estado);
CREATE INDEX IF NOT EXISTS idx_cheques_vcto         ON cheques(fecha_vcto);

-- Claves foráneas en tablas de ítems y de unión (Postgres NO las indexa solo):
-- aceleran los JOINs de detalle/informes y los ON DELETE CASCADE/SET NULL.
CREATE INDEX IF NOT EXISTS idx_presupuesto_items_pres  ON presupuesto_items(presupuesto_id);
CREATE INDEX IF NOT EXISTS idx_presupuesto_items_prod  ON presupuesto_items(producto_id);
CREATE INDEX IF NOT EXISTS idx_remito_items_remito     ON remito_items(remito_id);
CREATE INDEX IF NOT EXISTS idx_remito_items_prod       ON remito_items(producto_id);
CREATE INDEX IF NOT EXISTS idx_factura_items_factura   ON factura_items(factura_id);
CREATE INDEX IF NOT EXISTS idx_factura_items_prod      ON factura_items(producto_id);
CREATE INDEX IF NOT EXISTS idx_nota_items_nota         ON nota_items(nota_id);
CREATE INDEX IF NOT EXISTS idx_nota_items_prod         ON nota_items(producto_id);
CREATE INDEX IF NOT EXISTS idx_recibo_facturas_recibo  ON recibo_facturas(recibo_id);
CREATE INDEX IF NOT EXISTS idx_recibo_facturas_factura ON recibo_facturas(factura_id);
CREATE INDEX IF NOT EXISTS idx_recibo_medios_recibo    ON recibo_medios(recibo_id);

-- Claves foráneas de enlace entre comprobantes (JOINs y ON DELETE SET NULL).
CREATE INDEX IF NOT EXISTS idx_remitos_factura         ON remitos(factura_id);
CREATE INDEX IF NOT EXISTS idx_remitos_presupuesto     ON remitos(presupuesto_id);
CREATE INDEX IF NOT EXISTS idx_facturas_remito         ON facturas(remito_id);
CREATE INDEX IF NOT EXISTS idx_facturas_presupuesto    ON facturas(presupuesto_id);
CREATE INDEX IF NOT EXISTS idx_cheques_cliente         ON cheques(cliente_id);

-- Índice parcial que respalda el auto-vencimiento de presupuestos:
-- solo indexa los presupuestos que todavía pueden vencer.
CREATE INDEX IF NOT EXISTS idx_presupuestos_autovencer ON presupuestos(fecha_vcto)
  WHERE estado IN ('borrador','enviado');
