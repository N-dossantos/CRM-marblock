-- =============================================================
-- CRM — Cuenta 2 / migración 0500: circuito informal — schema
-- Companion de cuenta2.md. Circuito paralelo SIN IVA y SIN numeración fiscal, aislado del
-- circuito oficial (Cuenta 1):
--   * clientes_cuenta2 / proveedores_cuenta2  (entidades propias, sin CUIT — §1.1)
--   * cuenta2_remitos (+ items)               ("Remito X", único comprobante, nº manual — §1.3)
--   * cuenta2_movimientos                     (cobros/pagos/ajustes directos, sin recibo — §1.5)
--   * cuenta2_cheques                         (cartera propia, migrable a Cuenta 1 — §1.6)
--
-- Aislamiento (§1.2 / §5.1): ninguna FK apunta a clientes/proveedores/facturas/remitos/recibos
-- ni a movimientos_tesoreria. Las dos únicas referencias hacia Cuenta 1 son de solo lectura o
-- puntuales: productos (catálogo compartido — §1.3) y cuenta2_cheques.cheque_id (el registro
-- creado al transferir un cheque a la cartera oficial — §1.6).
--
-- Cta. Cte. SIN tabla de saldos: no existe `cuenta2_ctacte`. El saldo se calcula al leer con
-- SUM(debe-haber) OVER (...) sobre el UNION de remitos + movimientos, igual que hace
-- informe_cta_cte para Cuenta 1 (migración 0011). Guardar un saldo_resultante por fila
-- derivaría y es un footgun de concurrencia.
--
-- Sin audit_trigger(): audit_log es infraestructura de Cuenta 1 y Ventas tampoco lo usa.
-- Idempotente. Mismas convenciones que 20260801120000_contabilidad_schema.sql.
-- =============================================================

-- ──────────────────────────────────────────────────────────────
-- 1. ENTIDADES  (§1.1) — estructura simplificada: nombre, descuento, teléfono, notas.
--    Sin CUIT y sin UNIQUE: el circuito es informal y no hay identificador fiscal.
--    Descuento libre 0–100 (Cuenta 1 lo restringe a 0/10/15/20; acá no aplica esa grilla).
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS clientes_cuenta2 (
  id                   SERIAL PRIMARY KEY,
  nombre               VARCHAR(200) NOT NULL,
  descuento_porcentaje DECIMAL(5,2) NOT NULL DEFAULT 0
                         CHECK (descuento_porcentaje BETWEEN 0 AND 100),
  telefono             VARCHAR(50),
  notas                TEXT,
  activo               BOOLEAN NOT NULL DEFAULT TRUE,
  created_at           TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cli_c2_nombre ON clientes_cuenta2(nombre);

CREATE TABLE IF NOT EXISTS proveedores_cuenta2 (
  id                   SERIAL PRIMARY KEY,
  nombre               VARCHAR(200) NOT NULL,
  descuento_porcentaje DECIMAL(5,2) NOT NULL DEFAULT 0
                         CHECK (descuento_porcentaje BETWEEN 0 AND 100),
  telefono             VARCHAR(50),
  notas                TEXT,
  activo               BOOLEAN NOT NULL DEFAULT TRUE,
  created_at           TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_prov_c2_nombre ON proveedores_cuenta2(nombre);

-- ──────────────────────────────────────────────────────────────
-- 2. REMITO X  (§1.3) — único comprobante, sirve de venta y de compra según tipo_sector.
--    `numero` se tipea a mano (talonario de papel, sin punto de venta fiscal) y NO lleva
--    UNIQUE: bloquear por duplicado en un circuito informal molesta más de lo que protege.
--    Sin columnas de IVA: los precios ya son netos (§1.3).
--    Sin impacto en stock (§1.4): el sistema no lleva control de inventario.
--    FKs con RESTRICT — borrar una entidad con movimientos rompería el CHECK de abajo y
--    dejaría el ledger huérfano; la baja de entidades es lógica (activo = false).
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cuenta2_remitos (
  id                   SERIAL PRIMARY KEY,
  tipo_sector          VARCHAR(10) NOT NULL CHECK (tipo_sector IN ('venta','compra')),
  cliente_id           INTEGER REFERENCES clientes_cuenta2(id)   ON DELETE RESTRICT,
  proveedor_id         INTEGER REFERENCES proveedores_cuenta2(id) ON DELETE RESTRICT,
  numero               VARCHAR(30) NOT NULL,              -- carga manual, ej. '12345'
  fecha                DATE NOT NULL DEFAULT CURRENT_DATE,
  descuento_porcentaje DECIMAL(5,2)  NOT NULL DEFAULT 0,
  subtotal             DECIMAL(14,2) NOT NULL DEFAULT 0,
  descuento_monto      DECIMAL(14,2) NOT NULL DEFAULT 0,
  total                DECIMAL(14,2) NOT NULL DEFAULT 0,
  observaciones        TEXT,
  created_at           TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_c2rem_entidad CHECK (
    (tipo_sector = 'venta'  AND cliente_id   IS NOT NULL AND proveedor_id IS NULL) OR
    (tipo_sector = 'compra' AND proveedor_id IS NOT NULL AND cliente_id   IS NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_c2rem_cliente   ON cuenta2_remitos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_c2rem_proveedor ON cuenta2_remitos(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_c2rem_fecha     ON cuenta2_remitos(tipo_sector, fecha DESC);

-- Ítems: copia de remito_items menos alicuota_iva_id (no hay IVA en Cuenta 2).
-- producto_id apunta al catálogo compartido de Cuenta 1 (§1.3) — solo lectura de precios.
CREATE TABLE IF NOT EXISTS cuenta2_remito_items (
  id              SERIAL PRIMARY KEY,
  remito_id       INTEGER NOT NULL REFERENCES cuenta2_remitos(id) ON DELETE CASCADE,
  producto_id     INTEGER REFERENCES productos(id) ON DELETE SET NULL,
  descripcion     VARCHAR(300)  NOT NULL,
  cantidad        DECIMAL(10,3) NOT NULL DEFAULT 1,
  precio_unitario DECIMAL(14,2) NOT NULL DEFAULT 0,       -- neto, sin IVA
  descuento_item  DECIMAL(5,2)  NOT NULL DEFAULT 0,
  subtotal        DECIMAL(14,2) NOT NULL DEFAULT 0,
  orden           INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_c2rem_items_remito   ON cuenta2_remito_items(remito_id);
CREATE INDEX IF NOT EXISTS idx_c2rem_items_producto ON cuenta2_remito_items(producto_id);

-- ──────────────────────────────────────────────────────────────
-- 3. CHEQUES CUENTA 2  (§1.6) — cartera propia, no toca cajas ni cuentas bancarias oficiales.
--    Columnas espejo de `cheques` para que transferir a Cuenta 1 sea un mapeo 1:1.
--    fecha_emision/fecha_vcto NOT NULL porque `cheques` las exige NOT NULL.
--    Estados: en_cartera → entregado (endosado a un proveedor C2) | transferido_c1 | anulado.
--    NO existe 'depositado': depositar implica acreditar en una cuenta bancaria oficial, que
--    es justo la contaminación que este módulo evita. El camino es transferir a C1 y depositar
--    allá con depositar_cheque_tercero(), que sí impacta el ledger de Tesorería.
--    cheque_id: el registro creado en la cartera oficial al transferirlo (§1.6 / §5.4).
--    origen_movimiento_id: el cobro/pago que dio de alta este cheque. Distingue sin ambigüedad
--    un cheque CREADO por un movimiento (borrarlo lo borra) de uno preexistente ENDOSADO por él
--    (borrarlo solo lo devuelve a la cartera). FK circular con cuenta2_movimientos, cerrada con
--    ALTER al final del archivo — mismo criterio que remitos <-> facturas en la migración 0001.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cuenta2_cheques (
  id            SERIAL PRIMARY KEY,
  numero        VARCHAR(30)  NOT NULL,
  tipo          VARCHAR(10)  NOT NULL DEFAULT 'fisico' CHECK (tipo IN ('fisico','echeq')),
  banco         VARCHAR(100) NOT NULL,
  titular       VARCHAR(200),
  cuit_titular  VARCHAR(13),
  fecha_emision DATE NOT NULL,
  fecha_vcto    DATE NOT NULL,
  monto         DECIMAL(14,2) NOT NULL,
  cliente_id    INTEGER REFERENCES clientes_cuenta2(id)    ON DELETE SET NULL,  -- quién lo entregó
  proveedor_id  INTEGER REFERENCES proveedores_cuenta2(id) ON DELETE SET NULL,  -- a quién se endosó
  estado        VARCHAR(20) NOT NULL DEFAULT 'en_cartera'
    CHECK (estado IN ('en_cartera','entregado','transferido_c1','anulado')),
  cheque_id     INTEGER REFERENCES cheques(id) ON DELETE SET NULL,  -- fila creada en la cartera C1
  origen_movimiento_id INTEGER,      -- FK a cuenta2_movimientos, cerrada por ALTER al final
  observaciones TEXT,
  created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_c2chq_estado    ON cuenta2_cheques(estado);
CREATE INDEX IF NOT EXISTS idx_c2chq_vcto      ON cuenta2_cheques(fecha_vcto);
CREATE INDEX IF NOT EXISTS idx_c2chq_cliente   ON cuenta2_cheques(cliente_id);
CREATE INDEX IF NOT EXISTS idx_c2chq_proveedor ON cuenta2_cheques(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_c2chq_cheque_c1 ON cuenta2_cheques(cheque_id);

-- ──────────────────────────────────────────────────────────────
-- 4. MOVIMIENTOS DE CTA. CTE.  (§1.5) — cobros, pagos y ajustes.
--    No hay Recibo ni Orden de Pago: el cobro/pago impacta la cuenta corriente directo.
--    Se guardan `debe` y `haber` (no un monto con signo) para que el UNION del informe sea
--    trivial y la fila se lea sola. Convención igual a Cuenta 1 en ambos sectores:
--    remito → debe, cobro/pago → haber, saldo positivo = "debe" (ventas) / "le debemos" (compras).
--    AJUSTE es el mecanismo para cargar el saldo inicial de una entidad.
-- ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS cuenta2_movimientos (
  id           SERIAL PRIMARY KEY,
  tipo_sector  VARCHAR(10) NOT NULL CHECK (tipo_sector IN ('venta','compra')),
  cliente_id   INTEGER REFERENCES clientes_cuenta2(id)    ON DELETE RESTRICT,
  proveedor_id INTEGER REFERENCES proveedores_cuenta2(id) ON DELETE RESTRICT,
  fecha        DATE NOT NULL DEFAULT CURRENT_DATE,
  tipo         VARCHAR(10) NOT NULL CHECK (tipo IN ('COBRO','PAGO','AJUSTE')),
  medio        VARCHAR(20) CHECK (medio IN ('efectivo','transferencia','cheque')),  -- NULL en AJUSTE
  debe         DECIMAL(14,2) NOT NULL DEFAULT 0 CHECK (debe  >= 0),
  haber        DECIMAL(14,2) NOT NULL DEFAULT 0 CHECK (haber >= 0),
  cheque_id    INTEGER REFERENCES cuenta2_cheques(id) ON DELETE SET NULL,
  concepto     VARCHAR(300) NOT NULL,
  created_at   TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_c2mov_entidad CHECK (
    (tipo_sector = 'venta'  AND cliente_id   IS NOT NULL AND proveedor_id IS NULL) OR
    (tipo_sector = 'compra' AND proveedor_id IS NOT NULL AND cliente_id   IS NULL)
  ),
  CONSTRAINT chk_c2mov_debe_xor_haber CHECK (NOT (debe > 0 AND haber > 0))
);

CREATE INDEX IF NOT EXISTS idx_c2mov_cliente   ON cuenta2_movimientos(cliente_id);
CREATE INDEX IF NOT EXISTS idx_c2mov_proveedor ON cuenta2_movimientos(proveedor_id);
CREATE INDEX IF NOT EXISTS idx_c2mov_fecha     ON cuenta2_movimientos(tipo_sector, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_c2mov_cheque    ON cuenta2_movimientos(cheque_id);

-- Cierre de la FK circular entre cuenta2_cheques y cuenta2_movimientos.
ALTER TABLE cuenta2_cheques
  DROP CONSTRAINT IF EXISTS cuenta2_cheques_origen_movimiento_id_fkey,
  ADD  CONSTRAINT cuenta2_cheques_origen_movimiento_id_fkey
       FOREIGN KEY (origen_movimiento_id) REFERENCES cuenta2_movimientos(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_c2chq_origen_mov ON cuenta2_cheques(origen_movimiento_id);

-- ──────────────────────────────────────────────────────────────
-- 5. TRIGGERS updated_at  (reusa set_updated_at() de la migración 0001)
-- ──────────────────────────────────────────────────────────────
DO $$ DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'clientes_cuenta2','proveedores_cuenta2','cuenta2_remitos','cuenta2_cheques'
  ]
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_updated_at ON %I;
       CREATE TRIGGER trg_updated_at BEFORE UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION set_updated_at();', t, t);
  END LOOP;
END; $$;
