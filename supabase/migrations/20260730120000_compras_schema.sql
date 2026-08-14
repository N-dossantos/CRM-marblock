-- =============================================================
-- CRM — Fase A / migración 0100: Sector Compras — schema
-- Implementa system_plan.md §4 (Compras). Tablas propias, separadas de Ventas:
--   * la numeración es DEL PROVEEDOR (no la generamos con siguiente_numero) — la unicidad
--     se escala por proveedor_id, no es un UNIQUE(numero) global como en Ventas;
--   * el estado tiene otra semántica: 'pagada' en vez de 'cobrada'.
-- IVA multi-alícuota (0/10.5/21/27) es la única capacidad nueva de arquitectura; Ventas
-- queda con IVA fijo 21% en esta pasada (system_plan.md §4.4, §7).
--
-- La FK circular facturas_compra <-> remitos_compra se rompe igual que remitos<->facturas
-- en Ventas: facturas_compra se crea sin la FK a remito, luego se agrega con ALTER TABLE.
-- Idempotente (IF NOT EXISTS) — seguro de re-aplicar.
-- =============================================================

-- ──────────────────────────────────────────────────────────────
-- PROVEEDORES  (espeja clientes + campos propios de compras)  §4.1
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS proveedores (
  id                             SERIAL PRIMARY KEY,
  razon_social                   VARCHAR(200) NOT NULL,
  cuit                           VARCHAR(13)  NOT NULL UNIQUE,
  condicion_iva                  VARCHAR(50)  NOT NULL DEFAULT 'Resp. Inscripto',
  condicion_compra               VARCHAR(50)  NOT NULL DEFAULT 'Cuenta Corriente',
  actividad                      VARCHAR(200),
  numero_ingresos_brutos         VARCHAR(30),
  clasificacion_bienes_servicios VARCHAR(20)  NOT NULL DEFAULT 'Bienes'
    CHECK (clasificacion_bienes_servicios IN ('Bienes','Servicios','Bienes y Servicios')),
  fecha_alta                     DATE NOT NULL DEFAULT CURRENT_DATE,
  direccion                      VARCHAR(300),
  localidad                      VARCHAR(100),
  provincia                      VARCHAR(100) DEFAULT 'Buenos Aires',
  telefono                       VARCHAR(50),
  email                          VARCHAR(150),
  notas                          TEXT,
  activo                         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at                     TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at                     TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────────────────────
-- PROVEEDOR_ALICUOTAS  — retenciones por proveedor (≠ IVA por línea)  §4.2
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS proveedor_alicuotas (
  id             SERIAL PRIMARY KEY,
  proveedor_id   INTEGER NOT NULL REFERENCES proveedores(id) ON DELETE CASCADE,
  tipo_retencion VARCHAR(30) NOT NULL CHECK (tipo_retencion IN ('IVA','Ganancias','IIBB','SUSS')),
  jurisdiccion   VARCHAR(100),          -- provincia / Convenio Multilateral, para IIBB
  alicuota       DECIMAL(5,2) NOT NULL,
  vigente_desde  DATE NOT NULL DEFAULT CURRENT_DATE,
  UNIQUE (proveedor_id, tipo_retencion, jurisdiccion)
);

-- ──────────────────────────────────────────────────────────────
-- MATERIALES  — catálogo de compra (separado de productos que Ventas vende)  §4.3
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS materiales (
  id                SERIAL PRIMARY KEY,
  codigo            VARCHAR(20)  NOT NULL UNIQUE,
  descripcion       VARCHAR(300) NOT NULL,
  unidad_medida     VARCHAR(20)  NOT NULL DEFAULT 'unidad',  -- kg, m3, litro, unidad, bolsa, etc.
  precio_referencia DECIMAL(14,2) NOT NULL DEFAULT 0,        -- informativo: último precio de compra conocido
  activo            BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────────────────────
-- ALICUOTAS_IVA  — catálogo multi-alícuota  §4.4
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS alicuotas_iva (
  id          SERIAL PRIMARY KEY,
  descripcion VARCHAR(50) NOT NULL,
  porcentaje  DECIMAL(5,2) NOT NULL UNIQUE,
  activo      BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO alicuotas_iva (descripcion, porcentaje) VALUES
  ('Exento (0%)', 0),
  ('10.5%',       10.5),
  ('21%',         21),
  ('27%',         27)
ON CONFLICT (porcentaje) DO NOTHING;

-- ──────────────────────────────────────────────────────────────
-- FACTURAS_COMPRA  (creada antes que remitos_compra p/ romper la FK circular)  §4.5
--   numero_comp / punto_venta son DEL PROVEEDOR (parámetros de entrada, no siguiente_numero).
--   La unicidad se escala por proveedor_id (constraint al final).
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS facturas_compra (
  id                    SERIAL PRIMARY KEY,
  proveedor_id          INTEGER NOT NULL REFERENCES proveedores(id),
  tipo                  CHAR(1) NOT NULL DEFAULT 'A' CHECK (tipo IN ('A','B','C','M')),
  punto_venta           CHAR(5) NOT NULL,   -- del proveedor, tal cual figura en el comprobante
  numero_comp           INTEGER NOT NULL,   -- del proveedor
  numero                VARCHAR(15) NOT NULL,
  fecha                 DATE NOT NULL,                        -- fecha de emisión (del proveedor)
  fecha_recepcion       DATE NOT NULL DEFAULT CURRENT_DATE,   -- cuándo lo cargamos nosotros
  remito_compra_id      INTEGER,  -- FK agregada por ALTER abajo (remitos_compra aún no existe)
  cae                   VARCHAR(20),         -- CAE que ya trae el comprobante, emitido por el proveedor
  afip_tipo_comprobante VARCHAR(3),
  subtotal              DECIMAL(14,2) NOT NULL DEFAULT 0,
  descuento_general     DECIMAL(5,2)  NOT NULL DEFAULT 0,
  descuento_monto       DECIMAL(14,2) NOT NULL DEFAULT 0,
  neto_gravado          DECIMAL(14,2) NOT NULL DEFAULT 0,
  iva_monto             DECIMAL(14,2) NOT NULL DEFAULT 0,
  total                 DECIMAL(14,2) NOT NULL DEFAULT 0,
  estado                VARCHAR(20) NOT NULL DEFAULT 'pendiente'
    CHECK (estado IN ('pendiente','parcial','pagada','anulada')),
  observaciones         TEXT,
  created_at            TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT facturas_compra_proveedor_numero_key UNIQUE (proveedor_id, tipo, punto_venta, numero_comp)
);

CREATE TABLE IF NOT EXISTS facturas_compra_items (
  id                SERIAL PRIMARY KEY,
  factura_compra_id INTEGER NOT NULL REFERENCES facturas_compra(id) ON DELETE CASCADE,
  material_id       INTEGER REFERENCES materiales(id) ON DELETE SET NULL,
  descripcion       VARCHAR(300) NOT NULL,
  cantidad          DECIMAL(10,3) NOT NULL DEFAULT 1,
  precio_unitario   DECIMAL(14,2) NOT NULL,
  descuento_item    DECIMAL(5,2)  NOT NULL DEFAULT 0,
  alicuota_iva_id   INTEGER NOT NULL REFERENCES alicuotas_iva(id),
  subtotal          DECIMAL(14,2) NOT NULL,
  orden             INTEGER NOT NULL DEFAULT 0
);

-- Desglose de IVA por alícuota, en tabla propia (no jsonb) para que el Libro IVA Compras
-- pueda hacer GROUP BY directo.  §4.4
CREATE TABLE IF NOT EXISTS factura_compra_iva_detalle (
  id                SERIAL PRIMARY KEY,
  factura_compra_id INTEGER NOT NULL REFERENCES facturas_compra(id) ON DELETE CASCADE,
  alicuota_iva_id   INTEGER NOT NULL REFERENCES alicuotas_iva(id),
  neto_gravado      DECIMAL(14,2) NOT NULL DEFAULT 0,
  iva_monto         DECIMAL(14,2) NOT NULL DEFAULT 0
);

-- ──────────────────────────────────────────────────────────────
-- REMITOS_COMPRA  §4.5
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS remitos_compra (
  id                SERIAL PRIMARY KEY,
  proveedor_id      INTEGER NOT NULL REFERENCES proveedores(id),
  punto_venta       CHAR(5) NOT NULL,
  numero_comp       INTEGER NOT NULL,
  numero            VARCHAR(15) NOT NULL,
  fecha             DATE NOT NULL,
  factura_compra_id INTEGER REFERENCES facturas_compra(id) ON DELETE SET NULL,
  estado            VARCHAR(20) NOT NULL DEFAULT 'pendiente'
    CHECK (estado IN ('pendiente','facturado','anulado')),
  observaciones     TEXT,
  created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT remitos_compra_proveedor_numero_key UNIQUE (proveedor_id, punto_venta, numero_comp)
);

CREATE TABLE IF NOT EXISTS remito_compra_items (
  id               SERIAL PRIMARY KEY,
  remito_compra_id INTEGER NOT NULL REFERENCES remitos_compra(id) ON DELETE CASCADE,
  material_id      INTEGER REFERENCES materiales(id) ON DELETE SET NULL,
  descripcion      VARCHAR(300) NOT NULL,
  cantidad         DECIMAL(10,3) NOT NULL DEFAULT 1,
  precio_unitario  DECIMAL(14,2) NOT NULL DEFAULT 0,
  descuento_item   DECIMAL(5,2)  NOT NULL DEFAULT 0,
  subtotal         DECIMAL(14,2) NOT NULL DEFAULT 0,
  orden            INTEGER NOT NULL DEFAULT 0
);

-- Cierre de la FK circular facturas_compra <-> remitos_compra.
ALTER TABLE facturas_compra
  DROP CONSTRAINT IF EXISTS facturas_compra_remito_compra_id_fkey,
  ADD  CONSTRAINT facturas_compra_remito_compra_id_fkey
       FOREIGN KEY (remito_compra_id) REFERENCES remitos_compra(id) ON DELETE SET NULL;

-- ──────────────────────────────────────────────────────────────
-- NOTAS_COMPRA (NC/ND, siempre ligadas a una factura de compra)  §4.5
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS notas_compra (
  id                SERIAL PRIMARY KEY,
  proveedor_id      INTEGER NOT NULL REFERENCES proveedores(id),
  tipo              CHAR(2) NOT NULL CHECK (tipo IN ('NC','ND')),
  tipo_letra        CHAR(1) NOT NULL DEFAULT 'A',
  punto_venta       CHAR(5) NOT NULL,
  numero_comp       INTEGER NOT NULL,
  numero            VARCHAR(15) NOT NULL,
  fecha             DATE NOT NULL,
  factura_compra_id INTEGER NOT NULL REFERENCES facturas_compra(id),
  motivo            VARCHAR(300),
  subtotal          DECIMAL(14,2) NOT NULL DEFAULT 0,
  descuento_monto   DECIMAL(14,2) NOT NULL DEFAULT 0,
  neto_gravado      DECIMAL(14,2) NOT NULL DEFAULT 0,
  iva_monto         DECIMAL(14,2) NOT NULL DEFAULT 0,
  total             DECIMAL(14,2) NOT NULL DEFAULT 0,
  observaciones     TEXT,
  created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT notas_compra_proveedor_numero_key UNIQUE (proveedor_id, tipo, punto_venta, numero_comp)
);

CREATE TABLE IF NOT EXISTS nota_compra_items (
  id              SERIAL PRIMARY KEY,
  nota_compra_id  INTEGER NOT NULL REFERENCES notas_compra(id) ON DELETE CASCADE,
  material_id     INTEGER REFERENCES materiales(id) ON DELETE SET NULL,
  descripcion     VARCHAR(300) NOT NULL,
  cantidad        DECIMAL(10,3) NOT NULL DEFAULT 1,
  precio_unitario DECIMAL(14,2) NOT NULL,
  descuento_item  DECIMAL(5,2)  NOT NULL DEFAULT 0,
  subtotal        DECIMAL(14,2) NOT NULL,
  orden           INTEGER NOT NULL DEFAULT 0
);

-- ──────────────────────────────────────────────────────────────
-- PAGOS A PROVEEDOR ("ingreso de pago" = carga del pago, dinero que SALE)  §4.7
--   Único comprobante de Compras que numeramos nosotros: siguiente_numero('pago_proveedor').
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pagos_proveedor (
  id           SERIAL PRIMARY KEY,
  numero       VARCHAR(15) NOT NULL UNIQUE,  -- nuestro, vía siguiente_numero('pago_proveedor')
  punto_venta  CHAR(5) NOT NULL,
  numero_comp  INTEGER NOT NULL,
  fecha        DATE NOT NULL,
  proveedor_id INTEGER NOT NULL REFERENCES proveedores(id),
  total        DECIMAL(14,2) NOT NULL DEFAULT 0,
  observaciones TEXT,
  created_at   TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS pago_proveedor_medios (
  id                SERIAL PRIMARY KEY,
  pago_proveedor_id INTEGER NOT NULL REFERENCES pagos_proveedor(id) ON DELETE CASCADE,
  tipo              VARCHAR(20) NOT NULL
    CHECK (tipo IN ('efectivo','transferencia','cheque_propio','cheque_tercero')),
  detalle           VARCHAR(300),
  cuenta_bancaria_id INTEGER REFERENCES cuentas_bancarias(id),  -- nullable: efectivo no la usa
  cheque_id         INTEGER REFERENCES cheques(id),             -- cheque_tercero: entregado desde cartera
  cheque_propio_id  INTEGER,  -- cheque_propio: FK a cheques_propios (Tesorería, Fase C) — sin FK todavía
  monto             DECIMAL(14,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS pago_proveedor_facturas (
  id                SERIAL PRIMARY KEY,
  pago_proveedor_id INTEGER NOT NULL REFERENCES pagos_proveedor(id) ON DELETE CASCADE,
  factura_compra_id INTEGER NOT NULL REFERENCES facturas_compra(id)
);

-- ──────────────────────────────────────────────────────────────
-- RETENCIONES (deducidas al momento del pago)  §4.8
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS retenciones (
  id                 SERIAL PRIMARY KEY,
  pago_proveedor_id  INTEGER NOT NULL REFERENCES pagos_proveedor(id) ON DELETE CASCADE,
  proveedor_id       INTEGER NOT NULL REFERENCES proveedores(id),
  tipo_retencion     VARCHAR(30) NOT NULL CHECK (tipo_retencion IN ('IVA','Ganancias','IIBB','SUSS')),
  jurisdiccion       VARCHAR(100),
  numero_certificado VARCHAR(30),
  fecha              DATE NOT NULL,
  base_imponible     DECIMAL(14,2) NOT NULL,
  alicuota           DECIMAL(5,2) NOT NULL,
  monto              DECIMAL(14,2) NOT NULL,
  created_at         TIMESTAMP NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────────────────────
-- ÍNDICES  (Postgres NO indexa solo las FK; aceleran JOINs/informes/ON DELETE)
-- ──────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_proveedores_razon         ON proveedores(razon_social);
CREATE INDEX IF NOT EXISTS idx_proveedores_cuit          ON proveedores(cuit);
CREATE INDEX IF NOT EXISTS idx_prov_alicuotas_prov       ON proveedor_alicuotas(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_materiales_codigo         ON materiales(codigo);

CREATE INDEX IF NOT EXISTS idx_fc_proveedor              ON facturas_compra(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_fc_estado                 ON facturas_compra(estado);
CREATE INDEX IF NOT EXISTS idx_fc_fecha                  ON facturas_compra(fecha);
CREATE INDEX IF NOT EXISTS idx_fc_remito                 ON facturas_compra(remito_compra_id);
CREATE INDEX IF NOT EXISTS idx_fc_items_factura          ON facturas_compra_items(factura_compra_id);
CREATE INDEX IF NOT EXISTS idx_fc_items_material         ON facturas_compra_items(material_id);
CREATE INDEX IF NOT EXISTS idx_fc_iva_det_factura        ON factura_compra_iva_detalle(factura_compra_id);
CREATE INDEX IF NOT EXISTS idx_fc_iva_det_alicuota       ON factura_compra_iva_detalle(alicuota_iva_id);

CREATE INDEX IF NOT EXISTS idx_rc_proveedor              ON remitos_compra(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_rc_estado                 ON remitos_compra(estado);
CREATE INDEX IF NOT EXISTS idx_rc_factura                ON remitos_compra(factura_compra_id);
CREATE INDEX IF NOT EXISTS idx_rc_items_remito           ON remito_compra_items(remito_compra_id);
CREATE INDEX IF NOT EXISTS idx_rc_items_material         ON remito_compra_items(material_id);

CREATE INDEX IF NOT EXISTS idx_nc_factura                ON notas_compra(factura_compra_id);
CREATE INDEX IF NOT EXISTS idx_nc_proveedor              ON notas_compra(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_nc_items_nota             ON nota_compra_items(nota_compra_id);
CREATE INDEX IF NOT EXISTS idx_nc_items_material         ON nota_compra_items(material_id);

CREATE INDEX IF NOT EXISTS idx_pp_proveedor              ON pagos_proveedor(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_pp_medios_pago            ON pago_proveedor_medios(pago_proveedor_id);
CREATE INDEX IF NOT EXISTS idx_pp_medios_cheque          ON pago_proveedor_medios(cheque_id);
CREATE INDEX IF NOT EXISTS idx_pp_medios_cuenta          ON pago_proveedor_medios(cuenta_bancaria_id);
CREATE INDEX IF NOT EXISTS idx_pp_facturas_pago          ON pago_proveedor_facturas(pago_proveedor_id);
CREATE INDEX IF NOT EXISTS idx_pp_facturas_factura       ON pago_proveedor_facturas(factura_compra_id);

CREATE INDEX IF NOT EXISTS idx_retenciones_pago          ON retenciones(pago_proveedor_id);
CREATE INDEX IF NOT EXISTS idx_retenciones_proveedor     ON retenciones(proveedor_id);

-- ──────────────────────────────────────────────────────────────
-- TRIGGERS updated_at (reusa set_updated_at() de la migración 0001)
-- ──────────────────────────────────────────────────────────────
DO $$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['proveedores','materiales','facturas_compra','remitos_compra']
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_updated_at ON %I;
       CREATE TRIGGER trg_updated_at BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END; $$;
