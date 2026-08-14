# Plan de Sistema — CRM Marblock más allá de Ventas

## 1. Contexto y objetivo

Hoy `crm-tango` implementa un único sector operativo: **Ventas** (Clientes, Productos,
Presupuestos, Remitos, Facturas A/B, Notas de Crédito/Débito, Recibos, Cuenta Corriente, Cartera de
Cheques, Informes), sobre Supabase (Postgres + Auth + RLS + Edge Functions), con el backend Express
ya retirado.

Este documento extiende el plan del sistema a los tres sectores que todavía faltan para cubrir la
operación completa de la empresa, en línea con el ERP legado (Tango/Axoft Gestión) del que se está
migrando:

- **Compras** — proveedores, comprobantes de compra, cuenta corriente de proveedores, informes.
- **Tesorería** — cuentas, cheques, conciliación bancaria, movimientos, informes.
- **Procesos Generales** — tablas generales, datos contables, empleados, auditoría, consultas
  cruzadas entre sectores.

`supabase/TANGO_Migration.md` ya marca Compras, Stock y Tesorería como datos reales que existen en
Tango pero que **todavía no tienen tabla destino en Supabase** ("out of scope, no target yet"). Este
plan es ese destino: define qué construir, en qué orden y con qué diseño técnico.

Relación con otros documentos:
- `supabase/MIGRATION_PLAN.md` — trackea el *cutover de datos* de Ventas/Tango (fase, bloqueos).
  Este documento es el **roadmap de construcción** de los tres sectores nuevos, no reemplaza a ese.
- `supabase/TANGO_Migration.md` — fuente de los ítems marcados "sin destino todavía" que este plan
  resuelve.

Alcance de esta primera pasada: **Compras** recibe una especificación técnica completa (tablas,
RPCs, pantallas). **Tesorería** y **Procesos Generales** reciben un diseño a nivel de roadmap
(conceptos, tablas propuestas, dependencias) — el detalle columna por columna de esos dos sectores
queda para una siguiente pasada, una vez que Compras esté construido y haya validado el patrón una
vez más.

## 2. Estado actual (resumen)

- **Stack**: frontend React + Vite hablando directo con Supabase vía `supabase-js`. Capa de acceso
  única en `frontend/src/api/index.js` (objetos por recurso sobre `.rpc()` o PostgREST). Vistas en
  `frontend/src/views/`, una carpeta por módulo: `Dashboard, Clientes, Productos, Presupuestos,
  Remitos, Facturas, Notas, Recibos, CtaCte, Cheques, Informes, Login`.
- **Escrituras**: siempre a través de funciones Postgres `SECURITY DEFINER` — cada operación de
  comprobante (numeración + cabecera + N ítems + recálculo de estado) es una sola función. El patrón
  de referencia es `supabase/migrations/20260727120003_rpc_presupuestos.sql`.
- **Numeración**: `contadores(tipo PK, punto_venta, ultimo_numero, descripcion)` +
  `siguiente_numero(p_tipo)` — numeración atómica, pero **solo para comprobantes que nosotros
  emitimos** (facturas, remitos, notas, recibos, presupuestos de venta).
- **Totales**: se calculan en el servidor únicamente, vía `crm_calc_totales()` — hoy con IVA fijo al
  21%, sin soporte multi-alícuota.
- **RLS**: modelo "shared staff" — `authenticated` tiene CRUD completo, `anon` no tiene nada
  (revocado explícitamente + sin política). Las tablas nuevas necesitan `ENABLE ROW LEVEL SECURITY`
  + una política `staff_all` propia; **sin `FORCE`** (las RPC `SECURITY DEFINER` corren como owner y
  `FORCE` bloquearía sus propias escrituras). Nota útil: `ALTER DEFAULT PRIVILEGES` ya otorga CRUD a
  `authenticated` y revoca `anon` automáticamente para tablas futuras — pero **RLS igual hay que
  habilitarlo y darle política a cada tabla nueva explícitamente**, eso no es automático.
- **Privilegios de funciones**: cada RPC nueva necesita `ALTER FUNCTION ... SET search_path = public,
  pg_temp` + `REVOKE ALL ... FROM PUBLIC, anon` + `GRANT EXECUTE ... TO authenticated` — los
  privilegios por defecto de Supabase filtran `EXECUTE` a `anon` si no se hace explícito (lección de
  las migraciones 0004/0010).
- **Piezas reutilizables ya existentes**: `cuentas_bancarias`, `cheques` (cartera de cheques de
  terceros, con una columna de texto libre `proveedor_destino` — no es una FK real porque no existe
  tabla `proveedores` todavía), `config_empresa`, y el patrón general
  cabecera+ítems+RPC+numeración+estado.
- **Faltante hoy**: no existe `proveedores`, `compras`, `stock`, ledger de tesorería, ni núcleo
  contable (plan de cuentas/asientos) en ningún lado del esquema.

## 3. Secuenciación de fases

| Fase | Contenido | Racional |
|---|---|---|
| **A** | Compras completo (schema → RLS → RPCs → frontend) **+ en paralelo**: `audit_log` genérico y `tablas_generales` genérico (Procesos Generales) | Compras es el mayor reuso del patrón ya probado en Ventas, y el de menor riesgo. El trigger de auditoría se agrega en la misma migración que crea las tablas nuevas — hacerlo después sería un retrofit más costoso sobre tablas ya en uso. |
| **B** | Consultas Compras (depende de A) + revisar si Consultas Ventas necesita una entrada propia distinta de Informes/CtaCte | Consultas Compras no puede existir sin que existan antes las tablas de Compras. |
| **C** | Tesorería (infraestructura nueva: agrupaciones, tipos de comprobante, movimientos, conciliación, cheques propios) | Se secuencia después de Compras a propósito: conviene validar una vez más el patrón RLS/RPC/vista (con Compras) antes de encarar un problema sin análogo directo en Ventas — un ledger de movimientos + conciliación bancaria. `pagos_proveedor` (de Compras) puede salir standalone en la Fase A y conectarse a `movimientos_tesoreria` recién cuando exista la Fase C. |
| **D** | Consultas Tesorería + impresión de movimientos/cheques + transferencias | Dependen todas de que exista `movimientos_tesoreria`/`cheques_propios` (Fase C). |
| **E** | Núcleo contable (`plan_de_cuentas` / `asientos_contables`) — **núcleo aplicado, matriz bloqueada** | El DDL se puede redactar en cualquier momento, pero poblarlo/validarlo requiere espejar el plan de cuentas real de Tango → bloqueado en las mismas credenciales de SQL Server que faltan para el resto del cutover de datos. Toda "Consultas > contabilidad" de los 3 sectores, y el informe "contabilidad" de Tesorería, quedan sin construir hasta que esto se desbloquee. |
| **F** | **Completar/integrar Ventas** con las funcionalidades nuevas: cobranzas Ventas→Tesorería (backend ya hecho, falta frontend), Ventas→Contabilidad (asientos, bloqueado en la matriz de Fase E), IVA multi-alícuota en Ventas + Pedidos | Ventas se construyó antes que Compras/Tesorería/Contabilidad y quedó con enganches abiertos hacia ellas. **Spec: `system_plan_fase_f_integracion_ventas.md`.** |

## 3.1 Estado de implementación

- **Fase A — backend: APLICADO y verificado en producción (2026-07-30).** Migraciones
  `20260730120000`..`20260730120011` (12 en total) aplicadas al proyecto `kkdbvzixwlyeahgianuc` vía
  Supabase MCP: schema Compras, FK `cheques.proveedor_id`, núcleo Procesos Generales
  (`audit_log` + `audit_trigger()` + `tablas_generales`), RLS, y todas las RPCs
  (totales multi-alícuota, proveedores, facturas/remitos/notas de compra, pagos+retenciones,
  lecturas+informes). Smoke test end-to-end OK (factura multi-alícuota 21%/10.5% → total 14310,
  desglose IVA correcto, pago imputado → estado `pagada`, cta cte proveedor saldo 0, Libro IVA
  Compras, auditoría). Datos de prueba borrados; contador `pago_proveedor` y secuencias reseteados;
  `audit_log` vaciado — base pristina para el cutover. Advisors revisados: sólo los WARN
  deliberados de "shared staff" + RPC `SECURITY DEFINER` (misma postura que Ventas).
- **Fase A — frontend: COMPLETO (2026-07-30).** Todas las vistas de §4.13 creadas bajo
  `frontend/src/views/`: `ComprasProveedores`, `ComprasMateriales`, `ComprasRemitos`,
  `ComprasFacturas`, `ComprasNotas`, `ComprasPagos`, `ComprasCtaCte`. Formularios nuevos
  `CompraComprobanteForm` (factura/remito, numeración del proveedor, IVA multi-alícuota),
  `PagoProveedorForm` (medios multi-modales + imputación + retenciones) y `NotaCompraForm`
  (NC/ND de compra ligada a factura, multi-alícuota). Variante `TotalesBoxMulti` +
  `calcTotalesMulti` para el preview multi-alícuota. Objetos de API completos en
  `src/api/index.js` (`ProveedoresAPI`, `MaterialesAPI`, `AlicuotasIvaAPI`, `FacturasCompraAPI`,
  `RemitosCompraAPI`, `NotasCompraAPI`, `PagosProveedorAPI` + `InformesAPI.ctaCteProveedor`/
  `ivaCompras`/`preciosCompra`/`nominaProveedores`). Ruteo (`App.jsx`, 7 rutas `/compras/*`),
  sección "Compras" en el menú (`components/Layout`) y 3 pestañas nuevas en `Informes`
  (Libro IVA Compras, nómina de proveedores, precios de compra). `npm run build` OK.
  Los comprobantes de compra no generan PDF (son del proveedor); no hay Edge Function de compras.
- **Fase B — COMPLETO (2026-07-31).** Consultas integrales 360° para ambos sectores, sólo lectura:
  `frontend/src/views/ConsultaCliente` (Ventas) y `frontend/src/views/ConsultaProveedor` (Compras),
  simétricas. Shell reutilizable `components/Consultas/Consulta360` (buscador + lista de entidades +
  cabecera con saldo + sub-pestañas) y modales de drill-down `VentaDetalle`
  (factura/remito/nota/recibo/presupuesto, con botón "📄 PDF" vía Edge Function) y `CompraDetalle`
  (factura/remito/nota/pago de compra, sin PDF — los comprobantes son del proveedor). Cada ficha
  muestra datos del cliente/proveedor + saldo de cuenta corriente + una pestaña por tipo de
  comprobante (con "Ver" → detalle); ConsultaProveedor agrega la pestaña de retenciones config. Toda
  la data sale de RPCs ya existentes (`informe_cta_cte` / `informe_cta_cte_proveedor`, los `*_list` de
  cada comprobante, `proveedor_alicuotas`) — **sin backend nuevo**. Único ajuste de frontend:
  `PresupuestosAPI.list` acepta `cliente_id` y filtra en el cliente, porque `presupuestos_list` no
  tiene filtro server-side por cliente (a diferencia de remitos/facturas/notas/recibos). Nueva
  sección "Consultas" en el menú (`components/Layout`) con 2 entradas y rutas
  `/consultas/{cliente,proveedor}` en `App.jsx`. Esto resuelve la pregunta abierta de §6: Consultas
  Ventas **sí** recibe entrada propia, distinta de Informes/CtaCte — una ficha 360° por entidad.
  `npm run build` OK. Quedan como backlog (§7, no bloquean esta fase): "pedidos", "cupones", y toda
  "consulta > contabilidad" (Fase E, bloqueada).
- **Fase C — backend: APLICADO y verificado en producción (2026-07-31).** Migraciones
  `20260731120000`..`20260731120007` (8 en total) aplicadas al proyecto `kkdbvzixwlyeahgianuc` vía
  Supabase MCP: schema Tesorería (agrupaciones, tipos de comprobante, `movimientos_tesoreria` ledger,
  `cheques_propios`, `conciliaciones_bancarias`, ALTERs de `cuentas_bancarias`/`pago_proveedor_medios`),
  RLS `staff_all`, RPCs de escritura (movimientos, cheques propios, conciliación, integración
  ventas/compras→tesorería, transferencias) e informes jsonb. Advisors: sólo los WARN deliberados +
  el `_advisor_fixes` que revoca el helper interno `tes_emitir_cobranza`. **Frontend: código completo**
  (`TesoreriaMovimientos`, `TesoreriaCuentas`, `TesoreriaChequesPropios`, `TesoreriaConciliacion`,
  formulario `TransferenciaForm`) — ver detalle en el companion de Fase C/D.
- **Fase D — código completo; único paso pendiente: deploy de la Edge Function `pdf` (2026-07-31).**
  Frontend de Consultas Tesorería 360° (ficha por cuenta, reusando el shell de Fase B), impresión y
  transferencias editados y `npm run build` OK; la precondición "Fase C aplicada" ya está **cumplida**.
  Falta **redesplegar la Edge Function `pdf`** con los templates/rutas de tesorería (la desplegada es
  `version 1`, ~2026-07-27, anterior a Tesorería → todavía no imprime movimientos/cheques). Procedimiento
  en `system_plan_fase_d_consultas_tesoreria.md §5.1`.
- **Fase E — núcleo contable APLICADO vacío en producción (2026-08-01).** Migraciones
  `20260801120000`..`20260801120004` (5 en total) aplicadas vía Supabase MCP: `plan_de_cuentas`,
  `asientos_contables`, `asiento_items` (+ RLS, trigger de balanceo diferido, auditoría),
  `crear_asiento`/`anular_asiento` (manuales, **funcionan**) e informes `informe_libro_diario` /
  `informe_libro_mayor` / `informe_sumas_y_saldos`. Smoke test balanceado 121=121 OK con rollback (cero
  residuo). **Sigue bloqueado en datos** (credenciales SQL Server de Tango): poblar `plan_de_cuentas` y
  validar la **matriz de imputación** con el contador → recién ahí se llenan los cuerpos de
  `generar_asiento_desde_factura/_pago_proveedor/_movimiento_tesoreria`, que **hoy lanzan una excepción a
  propósito**. Ver `system_plan_fase_e_contabilidad.md §8`.
  **Frontend de Contabilidad: CONSTRUIDO (2026-08-14)** — §8 paso 5, el único que no depende de Tango.
  `PlanCuentasAPI`/`AsientosAPI`/`InformesAPI.{libroDiario,libroMayor,sumasYSaldos}` en
  `src/api/index.js`; vistas `ContabilidadPlanCuentas` (ABM del árbol, indentado por `nivel`, marca
  imputables) y `ContabilidadAsientos` (listado desde `informe_libro_diario` con drill-down de líneas
  + anular); `Forms/AsientoForm.jsx` con líneas debe/haber excluyentes y preview de balanceo (el
  servidor revalida igual); 2 rutas `/contabilidad/*`, sección "Contabilidad" en el menú y 3 pestañas
  nuevas en `Informes` (Libro Diario / Libro Mayor con selector de cuenta / Sumas y Saldos).
  `npm run build` OK; **falta el smoke contra la base** (estaba caída, ver `MIGRATION_PLAN.md`).
  Las pestañas "Contabilidad" placeholder de las fichas 360° siguen vacías: necesitan asientos
  ligados a comprobantes, que sólo aparecen con la generación automática (bloqueada en la matriz).
- **Fase F — spec redactada; WS1 + WS3(multi-alícuota) implementados (2026-08-01).** Completar/integrar
  Ventas con las funcionalidades nuevas: **WS1 ✅** — el form de recibo (`ReciboForm.jsx`) ya manda
  `cuenta_bancaria_id` por medio efectivo/transferencia, así que las cobranzas impactan el ledger
  (COBRANZA +1). **WS3 · IVA multi-alícuota ✅** — migraciones `20260802120000`..`02` aplicadas
  (`alicuota_iva_id` por ítem + RPCs con `crm_calc_totales_multi_alicuota`, backward-compat 21%); frontend
  (`ItemsTable`/`ComprobanteForm`/`NotaForm` con selector por ítem + `TotalesBoxMulti`) y template de PDF
  con desglose; smoke E2E OK (factura 21%+10.5% → total 2315). **WS2 — enganche APLICADO y probado
  (2026-08-14):** migraciones `20260803120000`/`01` con `generar_asiento_desde_nota` (stub),
  `generar_asientos_ventas_pendientes` (backfill idempotente) y el disparo automático como
  **CONSTRAINT TRIGGER diferido** en `facturas`/`notas` guardado por
  `config_empresa('contabilidad_auto_asientos')`, que arranca en `'off'` ⇒ **no-op**. Se implementó
  como trigger diferido en vez de una línea al final de `crear_factura`/`crear_nota` para no duplicar
  el cuerpo de esas RPC y para correr al COMMIT, con los ítems ya insertados (mismo mecanismo que
  `trg_asiento_balanceado`). Verificado con `SET CONSTRAINTS ALL IMMEDIATE`: el trigger **corre y no
  hace nada** con el flag en `off` (factura A emitida normal, 0 asientos automáticos). La **matriz**
  sigue bloqueada: prender el flag recién tras Fase E §8 pasos 2-4.
  **WS3 · Pedidos** pendiente de decisión de modelado (backlog §7).
  Deploy pendiente: la Edge Function `pdf` (para el desglose impreso; mismo deploy que Fase D).
  Companion: `system_plan_fase_f_integracion_ventas.md`.

## 4. Sector Compras — especificación técnica

### 4.1 `proveedores`

Espeja `clientes`, agregando los campos propios de compras:

```sql
CREATE TABLE proveedores (
  id                             SERIAL PRIMARY KEY,
  razon_social                   VARCHAR(200) NOT NULL,
  cuit                           VARCHAR(13)  NOT NULL UNIQUE,
  condicion_iva                  VARCHAR(50)  NOT NULL DEFAULT 'Resp. Inscripto',
  condicion_compra               VARCHAR(50)  NOT NULL DEFAULT 'Cuenta Corriente',
  actividad                      VARCHAR(200),
  numero_ingresos_brutos         VARCHAR(30),  -- opcional
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
```

### 4.2 `proveedor_alicuotas` — retenciones por proveedor

Concepto **distinto** del IVA por línea de factura (ver 4.4): son las tasas de retención
(IVA/Ganancias/IIBB/SUSS) que se le aplican a este proveedor al pagarle.

```sql
CREATE TABLE proveedor_alicuotas (
  id             SERIAL PRIMARY KEY,
  proveedor_id   INTEGER NOT NULL REFERENCES proveedores(id) ON DELETE CASCADE,
  tipo_retencion VARCHAR(30) NOT NULL CHECK (tipo_retencion IN ('IVA','Ganancias','IIBB','SUSS')),
  jurisdiccion   VARCHAR(100),          -- provincia / Convenio Multilateral, para IIBB
  alicuota       DECIMAL(5,2) NOT NULL,
  vigente_desde  DATE NOT NULL DEFAULT CURRENT_DATE,
  UNIQUE (proveedor_id, tipo_retencion, jurisdiccion)
);
```

### 4.3 `materiales` — catálogo de compra (separado de `productos`)

Compras no compra del catálogo `productos` que Ventas vende (productos terminados) — necesita su
propio catálogo de materiales/insumos.

```sql
CREATE TABLE materiales (
  id                SERIAL PRIMARY KEY,
  codigo            VARCHAR(20)  NOT NULL UNIQUE,
  descripcion       VARCHAR(300) NOT NULL,
  unidad_medida     VARCHAR(20)  NOT NULL DEFAULT 'unidad',  -- kg, m3, litro, unidad, bolsa, etc.
  precio_referencia DECIMAL(14,2) NOT NULL DEFAULT 0,        -- informativo: último precio de compra conocido
  activo            BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMP NOT NULL DEFAULT NOW()
);
```

Todas las tablas de ítems de Compras referencian `material_id`, no `producto_id`.

### 4.4 IVA multi-alícuota (`alicuotas_iva`)

Este es el cambio de arquitectura genuino frente al `crm_calc_totales()` actual (21% fijo). Las
facturas de proveedores mezclan alícuotas legítimamente (0%, 10.5%, 21%, 27%), y el Libro IVA
Compras necesita desglosarlas.

```sql
CREATE TABLE alicuotas_iva (
  id          SERIAL PRIMARY KEY,
  descripcion VARCHAR(50) NOT NULL,   -- 'Exento (0%)', '10.5%', '21%', '27%'
  porcentaje  DECIMAL(5,2) NOT NULL UNIQUE,
  activo      BOOLEAN NOT NULL DEFAULT TRUE
);
-- seed: (0, 'Exento'), (10.5, '10.5%'), (21, '21%'), (27, '27%')
```

Se agrega `alicuota_iva_id INTEGER NOT NULL REFERENCES alicuotas_iva(id)` a
`facturas_compra_items` (default = la fila de 21%, para no romper el comportamiento implícito de
hoy). Nueva función `crm_calc_totales_multi_alicuota(p_items jsonb, p_descuento_general numeric)` —
mismo contrato de totales generales que `crm_calc_totales`, pero agrupando por alícuota. El desglose
por alícuota se guarda en su propia tabla (no en jsonb) para que el Libro IVA Compras pueda hacer
`GROUP BY` directamente:

```sql
CREATE TABLE factura_compra_iva_detalle (
  id                SERIAL PRIMARY KEY,
  factura_compra_id INTEGER NOT NULL REFERENCES facturas_compra(id) ON DELETE CASCADE,
  alicuota_iva_id   INTEGER NOT NULL REFERENCES alicuotas_iva(id),
  neto_gravado      DECIMAL(14,2) NOT NULL DEFAULT 0,
  iva_monto         DECIMAL(14,2) NOT NULL DEFAULT 0
);
```

> Nota: esto es una capacidad nueva, no una copia de un patrón existente. Ventas queda con IVA fijo
> al 21% en esta pasada — unificar ambos sectores más adelante es un ítem legítimo pero está fuera
> de alcance ahora.

### 4.5 Cadena de comprobantes de compra (tablas separadas de Ventas)

Se usan tablas **propias**, no las mismas de Ventas con una columna de dirección, porque:
- **La numeración es del proveedor**, no la generamos nosotros — nunca se llama a
  `siguiente_numero()` en estos tres. La unicidad se escala por `proveedor_id`, no es un
  `UNIQUE(numero)` global como en Ventas.
- **El estado tiene otra semántica**: `pagada` en vez de `cobrada`.

```sql
CREATE TABLE facturas_compra (
  id                    SERIAL PRIMARY KEY,
  proveedor_id          INTEGER NOT NULL REFERENCES proveedores(id),
  tipo                  CHAR(1) NOT NULL DEFAULT 'A' CHECK (tipo IN ('A','B','C','M')),
  punto_venta           CHAR(5) NOT NULL,   -- del proveedor, tal cual figura en el comprobante
  numero_comp           INTEGER NOT NULL,   -- del proveedor
  numero                VARCHAR(15) NOT NULL,
  fecha                 DATE NOT NULL,                        -- fecha de emisión (del proveedor)
  fecha_recepcion       DATE NOT NULL DEFAULT CURRENT_DATE,    -- cuándo lo cargamos nosotros
  remito_compra_id      INTEGER REFERENCES remitos_compra(id) ON DELETE SET NULL,
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

CREATE TABLE facturas_compra_items (
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

CREATE TABLE remitos_compra (
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

CREATE TABLE remito_compra_items (
  id              SERIAL PRIMARY KEY,
  remito_compra_id INTEGER NOT NULL REFERENCES remitos_compra(id) ON DELETE CASCADE,
  material_id     INTEGER REFERENCES materiales(id) ON DELETE SET NULL,
  descripcion     VARCHAR(300) NOT NULL,
  cantidad        DECIMAL(10,3) NOT NULL DEFAULT 1,
  precio_unitario DECIMAL(14,2) NOT NULL DEFAULT 0,
  descuento_item  DECIMAL(5,2)  NOT NULL DEFAULT 0,
  subtotal        DECIMAL(14,2) NOT NULL DEFAULT 0,
  orden           INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE notas_compra (
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

CREATE TABLE nota_compra_items (
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
```

### 4.6 Cuenta corriente de proveedores ("composición de saldos")

Igual que Ventas: no hay tabla de ledger nueva. `informe_cta_cte` hoy calcula todo en vivo desde
facturas+notas+recibos; se replica el mismo enfoque:

```sql
CREATE FUNCTION informe_cta_cte_proveedor(p_proveedor_id integer) RETURNS jsonb
```

Agrega `facturas_compra` (debe) + `notas_compra` (`NC`=haber reduce lo que debemos, `ND`=debe) +
`pagos_proveedor` (haber) + `retenciones` (deducidas al momento del pago), en el mismo formato de
"composición de saldos" que ya existe para clientes.

### 4.7 Pagos a proveedores ("ingreso de pago")

Interpretación aplicada: es dinero que **sale**, el espejo de Recibos pero en sentido contrario —
"ingreso" se refiere a la carga/entrada del pago en el sistema, no a dinero entrante.

```sql
CREATE TABLE pagos_proveedor (
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

CREATE TABLE pago_proveedor_medios (
  id                SERIAL PRIMARY KEY,
  pago_proveedor_id INTEGER NOT NULL REFERENCES pagos_proveedor(id) ON DELETE CASCADE,
  tipo              VARCHAR(20) NOT NULL
    CHECK (tipo IN ('efectivo','transferencia','cheque_propio','cheque_tercero')),
  detalle           VARCHAR(300),
  cuenta_bancaria_id INTEGER REFERENCES cuentas_bancarias(id),  -- nullable: efectivo no la usa
  cheque_id         INTEGER REFERENCES cheques(id),             -- cheque_tercero: entregado desde cartera
  cheque_propio_id  INTEGER,  -- cheque_propio: FK a cheques_propios (Tesorería, Fase C) — nullable hasta entonces
  monto             DECIMAL(14,2) NOT NULL
);

CREATE TABLE pago_proveedor_facturas (
  id                SERIAL PRIMARY KEY,
  pago_proveedor_id INTEGER NOT NULL REFERENCES pagos_proveedor(id) ON DELETE CASCADE,
  factura_compra_id INTEGER NOT NULL REFERENCES facturas_compra(id)
);
```

Nueva fila en `contadores`:
```sql
INSERT INTO contadores (tipo, punto_venta, ultimo_numero, descripcion)
VALUES ('pago_proveedor', '00002', 0, 'Pago a Proveedor')
ON CONFLICT (tipo) DO NOTHING;
```

Cuando el medio es `cheque_tercero`, la RPC actualiza `cheques.estado = 'entregado'` y setea
`cheques.proveedor_id` (ver 4.9) — la resolución real del handoff que hoy solo existe como texto
libre.

### 4.8 Retenciones

```sql
CREATE TABLE retenciones (
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
```

Se completa por defecto desde `proveedor_alicuotas` cuando corre `crear_pago_proveedor`.
"Actualización de retenciones" = una RPC `actualizar_retencion` simple o un update directo por
PostgREST — mismo nivel de ABM simple que `productos`.

### 4.9 Extensión de `cheques`

```sql
ALTER TABLE cheques ADD COLUMN proveedor_id INTEGER REFERENCES proveedores(id) ON DELETE SET NULL;
```

Se mantiene la columna de texto libre `proveedor_destino` para registros históricos, y se agrega la
FK real ahora que existe `proveedores`.

### 4.10 Informe Libro IVA Compras ("comprobante en IVA compras")

```sql
CREATE FUNCTION informe_iva_compras(p_desde date, p_hasta date) RETURNS jsonb
```

Junta `facturas_compra` + `factura_compra_iva_detalle` + `retenciones`, agrupado/ordenado por fecha:
CUIT/razón social del proveedor, tipo/letra, punto_venta-numero, neto gravado e IVA por alícuota,
retenciones aplicadas, total. Es un informe de solo lectura sobre las tablas anteriores, no un
ledger físico nuevo (más allá de la pequeña tabla de desglose de 4.4).

### 4.11 Patrón de RPCs

Se reutiliza el patrón existente tal cual: `SECURITY DEFINER`, `SET search_path = public, pg_temp`,
`REVOKE`/`GRANT EXECUTE TO authenticated` explícito por función, la tríada
`crear_/actualizar_/anular`, un `crm_insert_*_items` helper por comprobante, y
`recalcular_estado_factura_compra` espejando a `recalcular_estado_factura`.

Diverge en: `crear_factura_compra` / `crear_remito_compra` / `crear_nota_compra` reciben
`p_punto_venta` / `p_numero_comp` como **parámetros de entrada** (validados como únicos por
`proveedor_id`), en vez de llamar a `siguiente_numero()`. Solo `crear_pago_proveedor` llama a
`siguiente_numero('pago_proveedor')`.

### 4.12 RLS

Mismo modelo `staff_all`: nueva migración que agrega todas las tablas nuevas al array `tbls`
(`proveedores, proveedor_alicuotas, materiales, alicuotas_iva, facturas_compra,
facturas_compra_items, factura_compra_iva_detalle, remitos_compra, remito_compra_items,
notas_compra, nota_compra_items, pagos_proveedor, pago_proveedor_medios, pago_proveedor_facturas,
retenciones`). Sin `FORCE`, por la misma razón documentada en la migración 0002.

### 4.13 Frontend

Nuevas carpetas de vista, planas y con prefijo (para no tocar el código de Ventas que ya funciona),
bajo `frontend/src/views/`: `ComprasProveedores/`, `ComprasMateriales/`, `ComprasFacturas/`,
`ComprasRemitos/`, `ComprasNotas/`, `ComprasPagos/`, `ComprasCtaCte/` — más nuevas pestañas dentro
del `Informes/` existente para Libro IVA Compras / nómina de proveedores / precios.

Se reutilizan `Badge`, `Modal`, `ItemsTable` de `frontend/src/components/UI/index.jsx` tal cual.
`TotalesBox` necesita una variante/prop multi-alícuota (hoy renderiza una sola línea fija "IVA
21%"). Se recomiendan componentes nuevos `CompraComprobanteForm.jsx` y `PagoProveedorForm.jsx` en
vez de agregarle más ramas de `tipo` a `ComprobanteForm`/`ReciboForm` — el comportamiento de
punto_venta/número como campos editables (no autogenerados) es lo bastante distinto como para
merecer su propio componente.

`frontend/src/api/index.js` suma nuevos objetos exportados siguiendo las convenciones existentes de
`rpc()`/`unwrap`/`one`: `ProveedoresAPI`, `MaterialesAPI`, `FacturasCompraAPI`, `RemitosCompraAPI`,
`NotasCompraAPI`, `PagosProveedorAPI`.

### 4.14 Migraciones propuestas

Fechadas después de la serie `2026072x` existente (hoy es 2026-07-30):

```
20260730120000_compras_schema.sql          -- proveedores, proveedor_alicuotas, materiales,
                                            -- alicuotas_iva(+seed), facturas_compra(+items+iva_detalle),
                                            -- remitos_compra(+items), notas_compra(+items),
                                            -- pagos_proveedor(+medios+facturas), retenciones, índices
20260730120001_compras_cheques_proveedor_fk.sql  -- ALTER cheques ADD proveedor_id FK
20260730120002_compras_rls.sql
20260730120003_rpc_compras_totales_alicuotas.sql -- crm_calc_totales_multi_alicuota
20260730120004_rpc_proveedores.sql               -- proveedores_list (nivel ABM simple)
20260730120005_rpc_compras_facturas.sql          -- crear_/actualizar_/anular factura_compra
20260730120006_rpc_compras_remitos.sql           -- crear_/anular remito_compra
20260730120007_rpc_compras_notas.sql             -- crear_nota_compra
20260730120008_rpc_pagos_proveedor.sql           -- crear_pago_proveedor, recalcular_estado_factura_compra,
                                                  -- nueva fila en contadores 'pago_proveedor'
20260730120009_rpc_reads_informes_compras.sql    -- facturas_compra_list, remitos_compra_list,
                                                  -- notas_compra_list, pagos_proveedor_list,
                                                  -- informe_cta_cte_proveedor, informe_iva_compras,
                                                  -- informe_precios_compra, informe_nomina_proveedores
```

## 5. Sector Tesorería — roadmap de diseño

> **Especificación técnica detallada:** `system_plan_fase_c_tesoreria.md` baja esta tabla a DDL
> columna por columna, RPCs, RLS, frontend y migraciones propuestas — misma profundidad que §4. La
> impresión/PDF de movimientos y cheques, las Consultas Tesorería 360° y las transferencias
> (frontend) se especifican en `system_plan_fase_d_consultas_tesoreria.md` (Fase D).

| Ítem del usuario | Tabla/concepto propuesto | Depende de |
|---|---|---|
| Agrupaciones | `agrupaciones_tesoreria` (agrupación de cuentas/cajas para reportes, ej. "Bancos", "Cajas", "Valores a depositar") | `cuentas_bancarias` (existe) |
| Tipos de comprobante | `tipos_comprobante_tesoreria` (catálogo config: Depósito, Extracción, Transferencia entre cuentas, Acreditación de cheque, etc., cada uno con signo +/-) | — |
| Cheques | `cheques` existente (cartera de terceros) **+ nueva `cheques_propios`** (cheques que emitimos nosotros — ciclo de vida distinto: emitido → entregado → pagado/rechazado, y FK a beneficiario, no a cliente) | `cuentas_bancarias` (existe), `proveedores` (Compras) |
| Conciliación | `conciliaciones_bancarias` (cabecera de extracto importado) + columnas `conciliado` / `conciliacion_id` en `movimientos_tesoreria` | `movimientos_tesoreria`, `cuentas_bancarias` |
| Movimientos de tesorería | **`movimientos_tesoreria`** — el ledger central nuevo: `cuenta_bancaria_id`, `tipo_comprobante_tesoreria_id`, `fecha`, `monto`, `signo`, `origen` (manual vs. auto-generado desde un Recibo/Pago/Cheque), `referencia_tipo`/`referencia_id` (enlace polimórfico a `recibos`, `pagos_proveedor`, `cheques`, `cheques_propios`) | `cuentas_bancarias` (existe), `tipos_comprobante_tesoreria` (nueva), `agrupaciones_tesoreria` (nueva, opcional) |
| Impresión de movimientos/cheques | No es tabla — vistas de impresión/PDF sobre `movimientos_tesoreria` y `cheques`/`cheques_propios`, reutilizando `components/PDFModal` | `movimientos_tesoreria`, `cheques_propios` |
| Informe: saldos | Saldo corriente por `cuenta_bancaria_id` desde `movimientos_tesoreria` | `movimientos_tesoreria` |
| Informe: subdiario por cuenta | Ledger cronológico filtrado a una cuenta | `movimientos_tesoreria` |
| Informe: mayor | Vista agregada tipo libro mayor; un "mayor de cuentas bancarias" (solo tesorería) puede salir sin bloqueos, pero el "mayor contable" completo depende de la Fase E | `movimientos_tesoreria`; parcial Fase E |
| Informe: movimientos por operación | Agrupado por `tipo_comprobante_tesoreria_id` | `movimientos_tesoreria`, `tipos_comprobante_tesoreria` |
| Informe: cheques | Unión de `cheques` + `cheques_propios` | ambas tablas |
| Informe: comprobantes | Listado de todos los movimientos/comprobantes de tesorería | `movimientos_tesoreria` |
| Informe: auditoría | Reutiliza el mecanismo **compartido** `audit_log` (Procesos Generales), no una tabla propia de auditoría | `audit_log` (Procesos Generales) |
| Informe: histórico | Consulta por rango de fechas, sin tabla nueva | `movimientos_tesoreria` |
| Informe: contabilidad | Núcleo Fase E **aplicado** (2026-08-01: `asientos_contables` + informes libro diario/mayor/sumas y saldos). La vista contable *de tesorería* sigue pendiente de la **matriz de imputación** (`generar_asiento_desde_movimiento_tesoreria` todavía es un stub que lanza excepción) | Fase E (matriz) |

`transferencias` (aparece en Procesos Generales, pero operativamente es un concepto de Tesorería):
sin tabla nueva — una RPC `crear_transferencia` que inserta atómicamente un par débito/crédito en
`movimientos_tesoreria` entre dos `cuentas_bancarias`.

## 6. Sector Procesos Generales — roadmap de diseño

> **Specs detalladas de los ítems que dependen de fases posteriores:** "Datos contables" →
> `system_plan_fase_e_contabilidad.md` (Fase E, bloqueada en datos). "Consultas Tesorería" →
> `system_plan_fase_d_consultas_tesoreria.md` (Fase D). "Consultas Ventas/Compras" ya resueltas en
> Fase B (§3.1). `tablas_generales` + `audit_log` ya construidos en Fase A.

| Ítem del usuario | Tabla/concepto propuesto | Notas |
|---|---|---|
| Tablas generales | `tablas_generales(id, categoria, codigo, descripcion, orden, activo, UNIQUE(categoria, codigo))` — catálogo genérico único, como el módulo real de "Tablas Generales" de Tango | Sin bloqueos, se puede construir cuando sea. Buen destino futuro para `condicion_iva`, `condicion_compra`, `clasificacion_bienes_servicios`, provincias, tipos de retención, etc. |
| Datos contables | `plan_de_cuentas` (código, descripción, tipo_cuenta, cuenta_padre_id jerárquico, imputable) + `asientos_contables` (cabecera: fecha, número, descripción, origen/referencia) + `asiento_items` (cuenta_id, debe, haber) | **Esquema + RPCs + informes APLICADOS vacíos (2026-08-01, migraciones `20260801120000`..`04`);** `crear_asiento` manual funciona. Sigue **bloqueado en datos**: poblar `plan_de_cuentas` y validar la matriz de imputación requieren las credenciales de SQL Server de Tango que faltan (`TANGO_Migration.md` §7, `MIGRATION_PLAN.md` Fase 7). Ver `system_plan_fase_e_contabilidad.md §8` |
| Empleados | `empleados(legajo, nombre, cuit, fecha_ingreso, puesto, activo)` | Sin bloqueos |
| Transferencias | Ver Tesorería §5 (`crear_transferencia`) | Depende de la Fase C |
| Auditoría | **Un solo mecanismo compartido**, no tablas por sector: `audit_log(id, tabla, registro_id, accion CHECK(INSERT/UPDATE/DELETE), datos_anteriores jsonb, datos_nuevos jsonb, usuario_id FK auth.users, ts)` + función genérica `audit_trigger()` adjuntable a cualquier tabla vía `CREATE TRIGGER` | Construir en/junto a la Fase A, para que las tablas nuevas de Compras lo tengan desde el día uno en vez de un retrofit posterior |
| Consultas Ventas: clientes, precios, pedidos, facturación, remitos, cuenta corriente, contabilidad | La mayoría ya existe (`Informes/`, `CtaCte/`); falta decidir si necesita una entrada de menú propia distinta de Informes. "Pedidos" no tiene entidad hoy (solo `presupuestos`) — a confirmar si mapea a presupuestos aceptados. "Contabilidad" bloqueado (Fase E) | — |
| Consultas Compras: proveedores, facturación, remitos, cuenta corriente, contabilidad | Depende de que exista la Fase A (Compras). "Contabilidad" bloqueado (Fase E) | Fase A |
| Consultas Tesorería: cuentas, cheques de terceros, cheques propios, cupones, comprobantes, transferencia de valores, contabilidad | Depende de que exista la Fase C (Tesorería). "Cupones" (lotes de cupones de tarjeta) no tiene modelo en el esquema actual — a confirmar alcance. "Contabilidad" bloqueado (Fase E) | Fase C |

## 7. Backlog / preguntas abiertas (no bloquean este plan)

- **"Pedidos"** (Consultas Ventas) no tiene entidad propia hoy — confirmar si mapea a presupuestos
  aceptados o si es un concepto nuevo a modelar.
- **"Cupones"** (Consultas Tesorería, lotes de cupones de tarjeta de crédito/débito) no tiene modelo
  en el esquema actual — confirmar alcance o tratarlo como backlog fuera de este plan.
- **Unificar IVA multi-alícuota entre Ventas y Compras**: Ventas queda deliberadamente en 21% fijo en
  esta pasada; extenderle soporte multi-alícuota (como se construye para Compras en §4.4) es un
  ítem legítimo para más adelante, no parte de este plan.
- **Núcleo contable (Fase E)**: esquema + RPCs + informes **aplicados vacíos** (2026-08-01) y el alta
  manual de asientos funciona; lo que sigue bloqueado por falta de credenciales del SQL Server de Tango
  es **poblar `plan_de_cuentas`** y **validar la matriz de imputación** (generación automática de
  asientos) — ver `supabase/TANGO_Migration.md` §7 y `supabase/MIGRATION_PLAN.md` (Fase 7).

## 8. Cómo validar este plan

Este documento arrancó como entrega de planificación; **su estado de ejecución vive en §3.1** —
al 2026-08-01, Fases A y B están completas, Fase C aplicada (falta sólo el deploy PDF de Fase D) y
el núcleo de Fase E está aplicado vacío. Lo que sigue abajo es el criterio de validación original del
plan de Compras (Fase A) y se conserva como referencia histórica:
- Los nombres de tabla propuestos en este documento (`proveedores`, `materiales`,
  `alicuotas_iva`, `facturas_compra`, etc.) fueron chequeados contra el esquema real aplicado
  (`supabase/migrations/20260727120001_schema.sql`) — no hay colisión de nombres.
- Antes de empezar a implementar la Fase A, revisar este documento con el equipo/proveedor de datos
  y confirmar los ítems del backlog (§7) que puedan afectar el diseño de tablas.
- La ejecución real (aplicar las migraciones de §4.14 vía Supabase MCP) es un paso posterior y
  separado — no está incluida en la redacción de este plan.
