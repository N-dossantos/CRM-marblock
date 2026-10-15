-- =============================================================
-- ARCA — esquema de facturación electrónica (PLAN_ARCA.md §3, Fase 2)
--
-- 1) facturas/notas: el número fiscal pasa a ser opcional (un borrador todavía no lo tiene: lo
--    asigna ARCA al autorizar) y aparece `estado_fiscal`, ortogonal a `estado` (cobranza, §4).
-- 2) Catálogo `condiciones_iva_afip` (RG 5616) con la clase de comprobante que ARCA admite para
--    cada condición; lo consume la migración de clientes que sigue.
-- 3) Tablas internas de la Edge Function `arca`: cache del ticket WSAA, serie en curso por
--    (PV, tipo ARCA) y auditoría de cada intento. Deny-all: ni `authenticated` las ve; sólo se
--    llega a ellas por las RPCs SECURITY DEFINER de 20261015120002_rpc_arca.sql.
--
-- Las columnas cae / cae_vencimiento / afip_* ya existen (20260728120000_fiscal_afip_columns).
-- =============================================================

-- ── 1) Estado fiscal de facturas y notas ─────────────────────────
-- historico          cargado antes del CRM fiscal (Tango, o emitido en la web de ARCA). Cuenta en
--                    saldos e informes; nunca se emite desde el CRM.
-- borrador           cargado en el CRM, sin número fiscal. No afecta saldos ni informes.
-- en_proceso         reclamada la serie (arca_series_en_curso); se está pidiendo el CAE.
-- resultado_incierto se envió FECAESolicitar y la respuesta no llegó: se reconcilia con
--                    FECompConsultar antes de cualquier otro envío de la serie (§4).
-- rechazado          ARCA respondió Resultado = R. Se corrige y se reintenta.
-- autorizado         con CAE: inmutable.
ALTER TABLE facturas
  ALTER COLUMN numero      DROP NOT NULL,
  ALTER COLUMN punto_venta DROP NOT NULL,
  ALTER COLUMN numero_comp DROP NOT NULL,
  ADD COLUMN estado_fiscal      VARCHAR(24) NOT NULL DEFAULT 'historico',
  ADD COLUMN arca_nro_tentativo INTEGER;

ALTER TABLE notas
  ALTER COLUMN numero      DROP NOT NULL,
  ALTER COLUMN punto_venta DROP NOT NULL,
  ALTER COLUMN numero_comp DROP NOT NULL,
  ADD COLUMN estado_fiscal      VARCHAR(24) NOT NULL DEFAULT 'historico',
  ADD COLUMN arca_nro_tentativo INTEGER;

-- Lo que ya tiene CAE local está autorizado; el resto del histórico queda `historico` (nunca
-- borrador). La carga de Tango no trae CAE, así que en prod es todo `historico`.
UPDATE facturas SET estado_fiscal = 'autorizado' WHERE cae IS NOT NULL AND cae_vencimiento IS NOT NULL;
UPDATE notas    SET estado_fiscal = 'autorizado' WHERE cae IS NOT NULL AND cae_vencimiento IS NOT NULL;

-- Las combinaciones válidas viven en la base: una RPC con un bug no puede dejar un borrador con
-- número fiscal, un autorizado sin CAE ni un resultado incierto sin el número que se envió.
ALTER TABLE facturas
  ADD CONSTRAINT chk_fac_estado_fiscal CHECK (estado_fiscal IN
    ('historico','borrador','en_proceso','resultado_incierto','rechazado','autorizado')),
  ADD CONSTRAINT chk_fac_numero_fiscal CHECK (
    (numero IS NOT NULL AND punto_venta IS NOT NULL AND numero_comp IS NOT NULL)
    = (estado_fiscal IN ('historico','autorizado'))),
  ADD CONSTRAINT chk_fac_cae CHECK (
    estado_fiscal <> 'autorizado' OR (cae IS NOT NULL AND cae_vencimiento IS NOT NULL)),
  ADD CONSTRAINT chk_fac_nro_tentativo CHECK (
    arca_nro_tentativo IS NULL OR estado_fiscal IN ('en_proceso','resultado_incierto')),
  ADD CONSTRAINT chk_fac_incierto_con_nro CHECK (
    estado_fiscal <> 'resultado_incierto' OR arca_nro_tentativo IS NOT NULL);

ALTER TABLE notas
  ADD CONSTRAINT chk_nota_estado_fiscal CHECK (estado_fiscal IN
    ('historico','borrador','en_proceso','resultado_incierto','rechazado','autorizado')),
  ADD CONSTRAINT chk_nota_numero_fiscal CHECK (
    (numero IS NOT NULL AND punto_venta IS NOT NULL AND numero_comp IS NOT NULL)
    = (estado_fiscal IN ('historico','autorizado'))),
  ADD CONSTRAINT chk_nota_cae CHECK (
    estado_fiscal <> 'autorizado' OR (cae IS NOT NULL AND cae_vencimiento IS NOT NULL)),
  ADD CONSTRAINT chk_nota_nro_tentativo CHECK (
    arca_nro_tentativo IS NULL OR estado_fiscal IN ('en_proceso','resultado_incierto')),
  ADD CONSTRAINT chk_nota_incierto_con_nro CHECK (
    estado_fiscal <> 'resultado_incierto' OR arca_nro_tentativo IS NOT NULL);

COMMENT ON COLUMN facturas.estado_fiscal IS
  'Estado ante ARCA (PLAN_ARCA §4), independiente de estado (cobranza): historico, borrador, '
  'en_proceso, resultado_incierto, rechazado, autorizado.';
COMMENT ON COLUMN facturas.arca_nro_tentativo IS
  'Número consultado/enviado a FECAESolicitar en el intento en curso. Se conserva en '
  'resultado_incierto para reconciliar con FECompConsultar.';
COMMENT ON COLUMN notas.estado_fiscal IS
  'Estado ante ARCA (PLAN_ARCA §4): historico, borrador, en_proceso, resultado_incierto, '
  'rechazado, autorizado. Las NC/ND llevan CAE propio.';
COMMENT ON COLUMN notas.arca_nro_tentativo IS
  'Número consultado/enviado a FECAESolicitar en el intento en curso.';

-- ── 2) Catálogo de condición IVA del receptor (RG 5616) ──────────
-- Tal como lo devolvió FEParamGetCondicionIvaReceptor en homologación el 15/10/2026 (§3.2). La
-- clase decide la letra: A ⇔ Responsable Inscripto y los tres monotributos; B ⇔ el resto. Se
-- vuelve a verificar contra producción en la Fase 7: si ARCA cambió algo, gana ARCA.
CREATE TABLE condiciones_iva_afip (
  id          SMALLINT    PRIMARY KEY,
  descripcion VARCHAR(80) NOT NULL,
  clase       CHAR(1)     NOT NULL CONSTRAINT chk_cond_iva_clase CHECK (clase IN ('A','B'))
);

INSERT INTO condiciones_iva_afip (id, descripcion, clase) VALUES
  (1,  'IVA Responsable Inscripto',                      'A'),
  (6,  'Responsable Monotributo',                        'A'),
  (13, 'Monotributista Social',                          'A'),
  (16, 'Monotributo Trabajador Independiente Promovido', 'A'),
  (4,  'IVA Sujeto Exento',                              'B'),
  (5,  'Consumidor Final',                               'B'),
  (7,  'Sujeto No Categorizado',                         'B'),
  (8,  'Proveedor del Exterior',                         'B'),
  (9,  'Cliente del Exterior',                           'B'),
  (10, 'IVA Liberado – Ley N° 19.640',                   'B'),
  (15, 'IVA No Alcanzado',                               'B');

-- Sólo lectura para el staff: es un dato de ARCA, se cambia por migración y no desde la app.
ALTER TABLE condiciones_iva_afip ENABLE ROW LEVEL SECURITY;
CREATE POLICY staff_select ON condiciones_iva_afip FOR SELECT TO authenticated USING (true);
REVOKE ALL ON condiciones_iva_afip FROM PUBLIC, anon, authenticated;
GRANT SELECT ON condiciones_iva_afip TO authenticated;

-- ── 3) Tablas internas de la Edge Function `arca` ────────────────
-- RLS sin políticas y sin privilegios para nadie (ni service_role): se accede únicamente por las
-- RPCs SECURITY DEFINER, que corren como owner. Sin FORCE ROW LEVEL SECURITY, igual que el resto
-- del esquema (20260727120002_rls.sql): FORCE bloquearía a esas mismas RPCs.

-- Cache del ticket de acceso de WSAA. Obligatorio, no una optimización: el TA vale 12 h y WSAA no
-- da otro mientras el anterior siga vigente (`coe.alreadyAuthenticated`, Fase 1). token + sign
-- habilitan a facturar a nombre de la empresa.
-- `pedido_hasta` serializa la renovación entre isolates: quien lo toma pide el TA a WSAA y los
-- demás esperan, en vez de pedir dos a la vez y quedarse sin ninguno.
CREATE TABLE arca_tokens (
  servicio     VARCHAR(20) PRIMARY KEY,
  token        TEXT,
  sign         TEXT,
  expira_en    TIMESTAMPTZ,
  pedido_hasta TIMESTAMPTZ,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_arca_tokens_completo CHECK (
    (token IS NULL) = (sign IS NULL) AND (token IS NULL) = (expira_en IS NULL))
);

-- Un único envío activo por serie fiscal (PV + tipo ARCA): evita dos FECAESolicitar
-- concurrentes que pidan el mismo último+1. La fila se borra al autorizar, al rechazar o al
-- confirmar que ARCA no autorizó; un resultado incierto la conserva hasta reconciliar (§4).
-- El número tentativo vive en el comprobante (arca_nro_tentativo), no se duplica acá.
CREATE TABLE arca_series_en_curso (
  punto_venta    INTEGER     NOT NULL,
  cbte_tipo      SMALLINT    NOT NULL,
  tabla          VARCHAR(10) NOT NULL CONSTRAINT chk_arca_serie_tabla CHECK (tabla IN ('facturas','notas')),
  comprobante_id INTEGER     NOT NULL,
  reclamada_en   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (punto_venta, cbte_tipo),
  CONSTRAINT arca_series_comprobante_key UNIQUE (tabla, comprobante_id)
);

-- Auditoría: un renglón por intento. Sólo el payload de negocio: nunca Token, Sign, certificado
-- ni clave (el CHECK rechaza un request que traiga el bloque Auth de WSFEv1).
CREATE TABLE arca_solicitudes (
  id             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tabla          VARCHAR(10) NOT NULL CONSTRAINT chk_arca_sol_tabla CHECK (tabla IN ('facturas','notas')),
  comprobante_id INTEGER     NOT NULL,
  resultado      VARCHAR(20) NOT NULL CONSTRAINT chk_arca_sol_resultado CHECK (resultado IN
    ('autorizado','rechazado','incierto','error_previo','no_autorizado')),
  request        JSONB,
  response       JSONB,
  errores        JSONB,
  observaciones  JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_arca_sol_sin_credenciales CHECK (
    request IS NULL OR NOT (request ?| ARRAY['Auth','Token','Sign']))
);

-- "Último intento de este comprobante" es la única lectura (arca_solicitud_ultimo).
CREATE INDEX idx_arca_solicitudes_comprobante ON arca_solicitudes (tabla, comprobante_id, id DESC);

ALTER TABLE arca_tokens          ENABLE ROW LEVEL SECURITY;
ALTER TABLE arca_series_en_curso ENABLE ROW LEVEL SECURITY;
ALTER TABLE arca_solicitudes     ENABLE ROW LEVEL SECURITY;

-- Los DEFAULT PRIVILEGES de 20260727120002 le dan CRUD a authenticated sobre toda tabla nueva:
-- se revoca explícito.
REVOKE ALL ON arca_tokens          FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON arca_series_en_curso FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON arca_solicitudes     FROM PUBLIC, anon, authenticated, service_role;
