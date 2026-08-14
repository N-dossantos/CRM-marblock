# Plan de Sistema — Fase C: Tesorería (especificación técnica)

> Documento companion de `system_plan.md`. `system_plan.md §5` da el **roadmap** de Tesorería (la
> tabla ítem→tabla); este archivo lo baja a **especificación técnica columna por columna**, al mismo
> nivel de detalle que `§4 (Compras)`. Es la "siguiente pasada" que `§1` dejó pendiente para
> Tesorería una vez construido Compras (Fases A y B ya completas, ver `system_plan.md §3.1`).
>
> **Estado:** **APLICADO y verificado en producción (2026-07-31).** Backend completo — migraciones
> `20260731120000`..`20260731120007` (8) aplicadas al proyecto `kkdbvzixwlyeahgianuc` vía Supabase MCP
> (schema, RLS, RPCs de escritura + integración + transferencias, informes jsonb, y el `_advisor_fixes`
> que revoca el helper interno `tes_emitir_cobranza`). Frontend de tesorería: código completo
> (`TesoreriaMovimientos/Cuentas/ChequesPropios/Conciliacion` + `TransferenciaForm`). La impresión/PDF de
> movimientos y cheques y las Consultas 360° de tesorería son **Fase D** (`system_plan_fase_d_consultas_tesoreria.md`);
> el único paso pendiente ahí es el redeploy de la Edge Function `pdf`.

## 1. Contexto y objetivo

Compras (Fase A) reutilizó el patrón de Ventas casi tal cual. Tesorería **no tiene análogo directo**
en el esquema actual: introduce un **ledger central de movimientos** (`movimientos_tesoreria`) con
saldos corridos por cuenta, un ciclo de vida de **cheques propios** (emitidos por nosotros, distinto
de la cartera de terceros que ya existe), y **conciliación bancaria**. Este es el motivo por el que
`system_plan.md §3` la secuencia *después* de Compras: validar una vez más el patrón RLS/RPC/vista
antes de encarar el primer problema sin espejo en Ventas.

Piezas que Tesorería **absorbe y conecta** (hoy sueltas):
- `cuentas_bancarias` — existe, hoy sólo config; pasa a ser la **dimensión "cuenta"** del ledger.
- `cheques` (cartera de terceros) — hoy `crear_recibo` ya la puebla (`en_cartera`) y
  `crear_pago_proveedor` ya resuelve el handoff (`entregado` + FK `proveedor_id`). Falta el eslabón
  **"depósito → acreditación en banco"**, que es donde el cheque impacta un saldo.
- `pago_proveedor_medios.cheque_propio_id` — se creó en Fase A como `INTEGER` **sin FK**,
  explícitamente "nullable hasta Fase C" (`system_plan.md §4.7`). Fase C crea `cheques_propios` y
  **cierra esa FK**.
- `contadores` + `siguiente_numero(p_tipo)` — disponibles si algún comprobante de tesorería necesita
  numeración propia (ver `§4.7`).
- `audit_log` + `audit_trigger()` (Procesos Generales, Fase A) — se **adjunta** a las tablas cabecera
  nuevas de Tesorería el día uno, igual que se hizo con Compras.

### 1.1 Límite Fase C ↔ Fase D (alcance de este documento)

`system_plan.md §3` reparte Tesorería en dos fases. Este documento especifica **Fase C** con este
corte (declarado acá para que sea revisable):

- **En Fase C (este spec):** todo el backend (schema, RLS, RPCs de escritura y de lectura/informes) +
  las pantallas **operativas** para llevar la tesorería día a día (ABM de cuentas/agrupaciones/tipos,
  alta de movimientos manuales, cheques propios, conciliación) + las **pestañas de informes** dentro
  del `Informes/` existente (saldos, subdiario, mayor, por operación, cheques, comprobantes,
  histórico) — mismo criterio con que Compras entregó sus informes dentro de Fase A.
- **Se difiere a Fase D** (`system_plan.md §3`): la **impresión/PDF** de movimientos y cheques (exige
  rutas nuevas en la Edge Function `pdf/`), y las **"Consultas Tesorería"** 360° (fichas por entidad,
  patrón de Fase B).
- **Zona gris — `crear_transferencia`:** `system_plan.md §3` lista "transferencias" en Fase D, pero es
  una RPC de 2 inserts sobre `movimientos_tesoreria` sin tabla nueva (`system_plan.md §5`). Decisión
  aplicada: el **backend** de la transferencia va en Fase C (el ledger la necesita para cerrar contra
  sí mismo); la **pantalla** de transferencias queda en Fase D. Está marcado como
  `(frontend → Fase D)` donde aparece. Confirmar en `§14` si se prefiere un corte más estricto.

## 2. Modelo conceptual

```
                     ┌────────────────────────┐
   agrupaciones ───▶ │   cuentas_bancarias    │ ◀── (existe; +clase +agrupacion +saldo_inicial)
                     │  banco / caja / valores │
                     └───────────┬────────────┘
                                 │ cuenta_bancaria_id
                                 ▼
 tipos_comprobante ───▶ ┌───────────────────────────┐ ◀─── conciliaciones_bancarias
   (signo, catálogo)    │   movimientos_tesoreria   │       (conciliado / conciliacion_id)
                        │  LEDGER CENTRAL (± monto) │
                        └───────────┬───────────────┘
                          origen +  │ referencia_tipo / referencia_id  (polimórfico, sin FK)
             ┌───────────┬──────────┼───────────┬──────────────┐
             ▼           ▼          ▼           ▼              ▼
          recibos   pagos_prov   cheques   cheques_propios  (manual /
          (Ventas)  (Compras)   (terceros)  (Tesorería)      transferencia)
```

Reglas del ledger:
- **El signo es del movimiento, no del tipo.** `movimientos_tesoreria.monto` es siempre `>= 0`;
  `signo ∈ {-1, +1}` determina la dirección. El `tipo_comprobante_tesoreria` aporta la *semántica* y
  un signo *sugerido* (que puede ser `0` = "depende del movimiento", p. ej. transferencia/ajuste).
- **Saldo de una cuenta** = `saldo_inicial` + `SUM(monto * signo)` de sus movimientos no anulados.
  Se materializa `monto_con_signo` como columna generada para poder `SUM()` directo.
- **Enlace al origen es polimórfico** (`referencia_tipo` + `referencia_id`, sin FK), igual criterio que
  el plan (`system_plan.md §5`): un movimiento puede nacer de un recibo, un pago, un cheque, un cheque
  propio, otra pata de transferencia, o ser manual.
- **Nada se borra: se anula.** `anulado BOOLEAN` en vez de `DELETE`, para preservar el rastro y la
  conciliación. El `audit_log` cubre el resto.

## 3. Tablas nuevas y ALTERs

### 3.1 `agrupaciones_tesoreria`

Agrupación de cuentas/cajas para reportes (subtotales por grupo).

```sql
CREATE TABLE agrupaciones_tesoreria (
  id          SERIAL PRIMARY KEY,
  codigo      VARCHAR(20)  NOT NULL UNIQUE,
  descripcion VARCHAR(100) NOT NULL,      -- 'Bancos', 'Cajas', 'Valores a depositar'
  orden       INTEGER NOT NULL DEFAULT 0,
  activo      BOOLEAN NOT NULL DEFAULT TRUE
);
-- seed sugerido: ('BANCOS','Bancos',1), ('CAJAS','Cajas',2), ('VALORES','Valores a depositar',3)
```

### 3.2 `tipos_comprobante_tesoreria`

Catálogo config de tipos de movimiento, cada uno con signo sugerido. Se prefiere tabla propia (no
`tablas_generales`) porque necesita la columna `signo` y se referencia por FK desde el ledger.

```sql
CREATE TABLE tipos_comprobante_tesoreria (
  id          SERIAL PRIMARY KEY,
  codigo      VARCHAR(20)  NOT NULL UNIQUE,
  descripcion VARCHAR(100) NOT NULL,
  signo       SMALLINT NOT NULL DEFAULT 0 CHECK (signo IN (-1, 0, 1)),  -- 0 = lo define el movimiento
  activo      BOOLEAN NOT NULL DEFAULT TRUE
);
-- seed sugerido:
--  ('DEP','Depósito',+1), ('EXT','Extracción',-1),
--  ('TRANSF','Transferencia entre cuentas',0),        -- dos patas, signo por pata
--  ('ACRED_CHEQUE','Acreditación de cheque',+1), ('RECHAZO_CHEQUE','Rechazo de cheque',-1),
--  ('COBRANZA','Cobranza (recibo)',+1), ('PAGO_PROV','Pago a proveedor',-1),
--  ('PAGO_CHEQUE_PROPIO','Pago cheque propio',-1),
--  ('GASTO_BANCARIO','Gasto / comisión bancaria',-1), ('AJUSTE','Ajuste',0)
```

### 3.3 ALTER `cuentas_bancarias`

Se extiende la tabla existente (no se crea una nueva) para que sea la dimensión "cuenta" del ledger,
incluyendo cajas de efectivo y "valores a depositar" como cuentas de tipo distinto.

```sql
ALTER TABLE cuentas_bancarias
  ADD COLUMN IF NOT EXISTS clase VARCHAR(20) NOT NULL DEFAULT 'banco'
    CHECK (clase IN ('banco','caja','valores')),
  ADD COLUMN IF NOT EXISTS agrupacion_id INTEGER REFERENCES agrupaciones_tesoreria(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS saldo_inicial DECIMAL(14,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS fecha_saldo_inicial DATE;
```

> **`saldo_inicial` importa para el cutover.** Los saldos de arranque (venidos de Tango) se cargan
> acá; el ledger sólo guarda los deltas desde esa fecha. Sin esto, el informe de saldos arranca en
> cero y no cuadra con el banco.
> **Cajas de efectivo** son filas de `cuentas_bancarias` con `clase='caja'` (así el efectivo también
> tiene cuenta destino en el ledger). La caja por defecto para mapear medios "efectivo" se apunta por
> config (ver `§3.8`).

### 3.4 `conciliaciones_bancarias`

Cabecera de un extracto conciliado. Se crea **antes** de `movimientos_tesoreria` porque el ledger la
referencia (`conciliacion_id`).

```sql
CREATE TABLE conciliaciones_bancarias (
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
```

> **Alcance de la conciliación en esta pasada:** se concilia **marcando movimientos del sistema**
> contra el extracto en papel/PDF y registrando el saldo final + la diferencia. La **importación
> del extracto** (parsear un CSV/PDF del banco a líneas) queda como backlog (`§12`) — no hay tabla de
> líneas de extracto importadas en este pase.

### 3.5 `movimientos_tesoreria` — ledger central

```sql
CREATE TABLE movimientos_tesoreria (
  id                            SERIAL PRIMARY KEY,
  numero                        VARCHAR(15),          -- opcional; sólo comprobantes manuales imprimibles (§4.7)
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

CREATE INDEX idx_mov_tes_cuenta_fecha ON movimientos_tesoreria(cuenta_bancaria_id, fecha);
CREATE INDEX idx_mov_tes_fecha        ON movimientos_tesoreria(fecha);
CREATE INDEX idx_mov_tes_tipo         ON movimientos_tesoreria(tipo_comprobante_tesoreria_id);
CREATE INDEX idx_mov_tes_ref          ON movimientos_tesoreria(referencia_tipo, referencia_id);
CREATE INDEX idx_mov_tes_concil       ON movimientos_tesoreria(conciliacion_id);
CREATE INDEX idx_mov_tes_pendientes   ON movimientos_tesoreria(cuenta_bancaria_id)
  WHERE conciliado = FALSE AND anulado = FALSE;   -- acelera la pantalla de conciliación
```

### 3.6 `cheques_propios`

Cheques que **emitimos nosotros** — ciclo de vida distinto de la cartera de terceros (`cheques`):
`emitido → entregado → pagado / rechazado / anulado`. Impactan el saldo bancario recién cuando el
banco los debita (`pagado`), no al emitirlos.

```sql
CREATE TABLE cheques_propios (
  id                 SERIAL PRIMARY KEY,
  numero             VARCHAR(30)  NOT NULL,
  cuenta_bancaria_id INTEGER NOT NULL REFERENCES cuentas_bancarias(id),  -- chequera / banco emisor
  tipo               VARCHAR(10)  NOT NULL DEFAULT 'fisico' CHECK (tipo IN ('fisico','echeq')),
  beneficiario       VARCHAR(200),                                       -- texto libre
  proveedor_id       INTEGER REFERENCES proveedores(id) ON DELETE SET NULL,  -- si el beneficiario es proveedor
  fecha_emision      DATE NOT NULL DEFAULT CURRENT_DATE,
  fecha_pago         DATE NOT NULL,                                      -- diferido: cuándo se paga
  monto              DECIMAL(14,2) NOT NULL,
  estado             VARCHAR(20)  NOT NULL DEFAULT 'emitido'
    CHECK (estado IN ('emitido','entregado','pagado','rechazado','anulado')),
  pago_proveedor_id  INTEGER REFERENCES pagos_proveedor(id) ON DELETE SET NULL,  -- si nació de un pago
  observaciones      TEXT,
  created_at         TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMP NOT NULL DEFAULT NOW(),
  CONSTRAINT cheques_propios_numero_cuenta_key UNIQUE (cuenta_bancaria_id, numero)
);

CREATE INDEX idx_cheques_propios_estado    ON cheques_propios(estado);
CREATE INDEX idx_cheques_propios_proveedor ON cheques_propios(proveedor_id);
```

### 3.7 ALTER `pago_proveedor_medios` — cerrar la FK que Fase A dejó abierta

```sql
-- Fase A creó cheque_propio_id como INTEGER sin FK ("nullable hasta Fase C", system_plan §4.7).
ALTER TABLE pago_proveedor_medios
  ADD CONSTRAINT pago_proveedor_medios_cheque_propio_fk
  FOREIGN KEY (cheque_propio_id) REFERENCES cheques_propios(id) ON DELETE SET NULL;
```

### 3.8 Config (`config_empresa`)

```sql
INSERT INTO config_empresa (clave, valor) VALUES
  ('tesoreria_caja_default_id', '')     -- cuenta_bancaria_id (clase='caja') destino de medios 'efectivo'
ON CONFLICT (clave) DO NOTHING;
```

> Se setea con el id real de la caja de efectivo tras crearla. Si está vacío, la generación de
> movimientos desde efectivo (`§5`) no corre y lo avisa, en vez de inventar una cuenta.

## 4. Integración con Ventas / Compras — cómo nacen los movimientos

Esta es la parte sin espejo en Ventas y donde están las decisiones reales. Regla general: **el
comprobante origen es el dueño de su movimiento**; Tesorería no re-teclea nada que ya se cargó.

| Origen | Momento en que impacta el saldo | Cómo |
|---|---|---|
| **Pago a proveedor** (Compras) — medio `efectivo` | Al crear el pago | Movimiento `-1` (`PAGO_PROV`) sobre la **caja default** (`config`) |
| **Pago a proveedor** — medio `transferencia` | Al crear el pago | Movimiento `-1` sobre `medio.cuenta_bancaria_id` |
| **Pago a proveedor** — medio `cheque_tercero` | No impacta banco | El valor ya existía en cartera; sólo cambia de manos (`entregado`, ya resuelto en Fase A) |
| **Pago a proveedor** — medio `cheque_propio` | **Diferido** a que el banco lo debite | Se liga el `cheque_propio` (`entregado`); el `-1` se genera al pasar a `pagado` (ver abajo) |
| **Cheque de tercero** (cartera) | Al **depositar** y acreditarse | `depositar_cheque_tercero` → `+1` (`ACRED_CHEQUE`) en la cuenta de depósito |
| **Cheque de tercero** rechazado tras depósito | Al rechazarse | `-1` (`RECHAZO_CHEQUE`) que revierte la acreditación |
| **Cheque propio** | Al pasar a `pagado` | `-1` (`PAGO_CHEQUE_PROPIO`) en `cheques_propios.cuenta_bancaria_id` |
| **Recibo** (Ventas) — `efectivo`/`transferencia` | Al crear el recibo | **Ver nota** ⚠ (requiere el único retoque a Ventas) |
| **Recibo** (Ventas) — `cheque`/`echeq` | Al depositar (no al cobrar) | Ya entran a `cheques` cartera (lo hace `crear_recibo`); impactan al depositarse, igual que arriba |
| **Manual** (depósito, extracción, gasto, ajuste) | Al cargarlo | `crear_movimiento_tesoreria` directo |
| **Transferencia entre cuentas** | Al cargarla | `crear_transferencia` → par `-1`/`+1` atómico |

> ⚠ **El único retoque a Ventas.** `pago_proveedor_medios` ya trae `cuenta_bancaria_id` → los pagos de
> Compras enganchan limpio. Pero `recibo_medios` (Ventas) **no** tiene `cuenta_bancaria_id`: guarda el
> banco como texto libre (`detalle`). Para que las cobranzas en efectivo/transferencia impacten un
> saldo hay dos caminos:
> 1. **(Recomendado, acotado)** Extender `crear_recibo` para aceptar un `cuenta_bancaria_id` opcional
>    por medio efectivo/transferencia y emitir el movimiento `COBRANZA (+1)`. Es la **única** función de
>    Ventas que se toca; se hace *aditivo y opcional* (si no viene la cuenta, no se genera movimiento y
>    el recibo se comporta exactamente como hoy), para no perturbar el flujo que ya funciona.
> 2. **(Alternativa sin tocar Ventas)** No generar nada en tiempo de recibo; ofrecer en Tesorería una
>    acción "asignar cobranza a cuenta" (`generar_movimiento_desde_recibo(p_recibo_id, p_cuenta_id)`)
>    que el usuario corre después.
>
> Decisión propuesta: implementar **(1)** como cambio aditivo, dejar **(2)** como el backfill para los
> recibos históricos. Marcado como ítem a confirmar en `§14` por ser el único punto que cruza a Ventas.

## 5. RPCs

Se reutiliza el patrón existente **tal cual** (referencia:
`supabase/migrations/20260727120003_rpc_presupuestos.sql` y las de Compras): `SECURITY DEFINER`,
`SET search_path = public, pg_temp`, y por cada función el trío
`REVOKE ALL … FROM PUBLIC, anon` + `GRANT EXECUTE … TO authenticated` (los defaults de Supabase
filtran `EXECUTE` a `anon` si no se hace explícito — lección de las migraciones 0004/0010). Las
lecturas siguen el cierre por bucle `EXECUTE format('GRANT EXECUTE … %s TO authenticated', r.sig)`
que ya usa `20260730120010`.

### 5.1 Escritura — ledger y transferencias

```sql
crear_movimiento_tesoreria(
  p_cuenta_bancaria_id integer, p_tipo_id integer, p_signo smallint, p_monto numeric,
  p_fecha date DEFAULT NULL, p_concepto text DEFAULT NULL,
  p_origen text DEFAULT 'manual', p_referencia_tipo text DEFAULT NULL, p_referencia_id integer DEFAULT NULL
) RETURNS movimientos_tesoreria

anular_movimiento_tesoreria(p_id integer) RETURNS movimientos_tesoreria
  -- set anulado=true; rechaza si el movimiento ya está conciliado (integridad del extracto cerrado).

crear_transferencia(                                   -- (frontend → Fase D; backend en C)
  p_cuenta_origen_id integer, p_cuenta_destino_id integer, p_monto numeric,
  p_fecha date DEFAULT NULL, p_concepto text DEFAULT NULL
) RETURNS jsonb
  -- inserta la pata débito (signo -1, tipo TRANSF) sobre origen, obtiene su id, inserta la pata
  -- crédito (+1) sobre destino con referencia a la pata débito, y cruza la referencia de vuelta.
  -- Ambas origen='transferencia'. Devuelve {debito_id, credito_id}. Valida cuentas distintas y monto>0.
```

### 5.2 Escritura — cheques

```sql
-- Cheques de TERCEROS (cartera existente): los engancha al ledger al depositarse.
depositar_cheque_tercero(p_cheque_id integer, p_cuenta_bancaria_id integer, p_fecha date DEFAULT NULL)
  RETURNS movimientos_tesoreria
  -- cheques.estado 'en_cartera' -> 'depositado'; genera ACRED_CHEQUE (+1) en la cuenta de depósito,
  -- origen='cheque', referencia_tipo='cheques'. Rechaza si el cheque no está en_cartera.

rechazar_cheque_tercero(p_cheque_id integer) RETURNS movimientos_tesoreria
  -- cheques.estado -> 'rechazado_banco'; genera RECHAZO_CHEQUE (-1) revirtiendo la acreditación.

-- Cheques PROPIOS (nuevos):
crear_cheque_propio(
  p_cuenta_bancaria_id integer, p_numero text, p_monto numeric, p_fecha_pago date,
  p_tipo text DEFAULT 'fisico', p_beneficiario text DEFAULT NULL, p_proveedor_id integer DEFAULT NULL,
  p_fecha_emision date DEFAULT NULL, p_pago_proveedor_id integer DEFAULT NULL, p_observaciones text DEFAULT NULL
) RETURNS cheques_propios
  -- estado inicial 'emitido' (o 'entregado' si viene ligado a un pago).

actualizar_estado_cheque_propio(p_id integer, p_nuevo_estado text) RETURNS cheques_propios
  -- transición validada. Al pasar a 'pagado': genera PAGO_CHEQUE_PROPIO (-1) sobre su cuenta.
  -- Al pasar a 'rechazado' habiendo estado 'pagado': revierte (+1). 'anulado' sólo desde 'emitido'/'entregado'.
```

> **Interacción con `crear_pago_proveedor` (Compras).** La función ya existe (Fase A) y ya resuelve el
> handoff del cheque de tercero. Fase C la **extiende** (no la reescribe) para: (a) emitir movimientos
> `-1` por cada medio `efectivo`/`transferencia`; (b) si el medio es `cheque_propio` con
> `cheque_propio_id`, marcar ese cheque `entregado` y ligar `pago_proveedor_id`. El débito bancario del
> cheque propio sigue difiriéndose a su `pagado`. Esta extensión vive en la migración de integración
> (`20260731120005`), no dentro de la migración original de pagos.

### 5.3 Escritura — conciliación

```sql
abrir_conciliacion(p_cuenta_bancaria_id integer, p_desde date, p_hasta date, p_saldo_extracto numeric)
  RETURNS conciliaciones_bancarias

marcar_conciliado(p_conciliacion_id integer, p_movimiento_ids integer[]) RETURNS void
  -- set conciliado=true, conciliacion_id=... a los movimientos indicados (deben ser de la cuenta).

cerrar_conciliacion(p_conciliacion_id integer) RETURNS conciliaciones_bancarias
  -- calcula saldo_sistema (saldo_inicial + SUM de conciliados), diferencia = extracto - sistema,
  -- estado='cerrada'. A partir de acá esos movimientos no se pueden anular (ver anular_movimiento).
```

### 5.4 Integración (migración `…120005`)

```sql
-- Extensión de crear_pago_proveedor -> movimientos (ver nota en §5.2).
-- Recibos (Ventas), camino recomendado (§4, opción 1 + backfill opción 2):
generar_movimiento_desde_recibo(p_recibo_id integer, p_asignaciones jsonb) RETURNS SETOF movimientos_tesoreria
  -- p_asignaciones: [{recibo_medio_id, cuenta_bancaria_id}] para efectivo/transferencia; emite COBRANZA (+1).
  -- Idempotente por (origen='recibo', referencia_id=recibo_medio_id) para no duplicar en re-corridas.
```

### 5.5 Lectura e informes (migración `…120006`)

Todas `SETOF jsonb` (listados) o `jsonb` (informes con cabecera+detalle+totales), mismo formato que
`informe_cta_cte` / `informe_iva_compras`.

```sql
movimientos_tesoreria_list(p_cuenta_id int, p_desde date, p_hasta date, p_tipo_id int, p_q text)
  -- listado filtrable (todos opcionales); une descripción de cuenta y tipo.

informe_saldos_tesoreria()                              RETURNS jsonb
  -- por cuenta: saldo_inicial, entradas, salidas, saldo_actual; agrupado por agrupacion + total general.
informe_subdiario_cuenta(p_cuenta_id int, p_desde date, p_hasta date)  RETURNS jsonb
  -- ledger cronológico de una cuenta con SALDO CORRIDO (running balance) vía window SUM() OVER (ORDER BY fecha,id).
informe_mayor_tesoreria(p_desde date, p_hasta date)     RETURNS jsonb
  -- "mayor de cuentas bancarias" (sólo tesorería): por cuenta saldo inicial/débitos/créditos/saldo final.
  -- OJO: el "mayor contable" completo es Fase E (bloqueado) — esto es sólo el de tesorería.
informe_movimientos_por_operacion(p_desde date, p_hasta date) RETURNS jsonb
  -- agrupado por tipo_comprobante_tesoreria (conteo + total por signo).
informe_cheques_tesoreria(p_estado text, p_desde date, p_hasta date) RETURNS jsonb
  -- UNIÓN de cheques (terceros, con origen='tercero') + cheques_propios (origen='propio').
informe_comprobantes_tesoreria(p_desde date, p_hasta date) RETURNS jsonb
  -- listado de todos los movimientos/comprobantes del período.
```

- **Histórico:** sin función nueva — es `movimientos_tesoreria_list` con rango de fechas amplio
  (`system_plan.md §5`: "sin tabla nueva").
- **Auditoría:** reutiliza `audit_log` (Procesos Generales). Un lector genérico
  `informe_auditoria(p_tabla, p_desde, p_hasta)` es de Procesos Generales, no de Tesorería — se
  construye una vez y sirve a los tres sectores; se referencia acá pero no se duplica.
- **Contabilidad:** **bloqueado (Fase E)** — depende del núcleo contable / credenciales SQL Server de
  Tango (`system_plan.md §3 Fase E`, `§7`).

## 6. RLS

Mismo modelo `staff_all` (`authenticated` CRUD, `anon` denegado), **sin `FORCE`** (las RPC
`SECURITY DEFINER` corren como owner). Nueva migración que agrega al array `tbls`:

```
agrupaciones_tesoreria, tipos_comprobante_tesoreria, conciliaciones_bancarias,
movimientos_tesoreria, cheques_propios
```

`cuentas_bancarias` y `cheques` **ya** tienen RLS de la migración de Ventas (`0002`) — sólo se les
agregan columnas/estados, no reciben política nueva. `ALTER DEFAULT PRIVILEGES` (de `0002`) ya otorga
CRUD a `authenticated` y revoca `anon` para tablas futuras, pero **habilitar RLS + política sigue
siendo explícito por tabla**.

## 7. Auditoría

Se adjunta `audit_trigger()` (ya existe, Fase A) a las tablas cabecera/operativas nuevas —no a config
ni a tablas de alta frecuencia sin valor de rastro—, con el mismo `DO … FOREACH` de
`20260730120002`:

```
movimientos_tesoreria, cheques_propios, conciliaciones_bancarias
```

(Se puede sumar `cuentas_bancarias` para rastrear cambios de `saldo_inicial`/`clase`.) Va al final de
la migración de schema (`…120000`), como Compras hizo en `procesos_generales_core`.

## 8. Frontend

Carpetas de vista nuevas, planas y con prefijo `Tesoreria` (no se toca el código de Ventas/Compras),
bajo `frontend/src/views/`:

- `TesoreriaCuentas/` — ABM de `cuentas_bancarias` (con `clase`/`agrupacion`/`saldo_inicial`) +
  `agrupaciones_tesoreria` + `tipos_comprobante_tesoreria`. Muestra el **saldo actual** por cuenta.
- `TesoreriaMovimientos/` — ledger: alta manual (`MovimientoTesoreriaForm`), listado filtrable por
  cuenta/fecha/tipo, anulación.
- `TesoreriaChequesPropios/` — emisión (`ChequePropioForm`) y transición de estado.
- `TesoreriaConciliacion/` — abrir conciliación, tildar movimientos pendientes, cerrar con
  saldo extracto/diferencia.
- **Depósito de cheques de terceros:** se agrega la acción "Depositar" a la vista `Cheques/` existente
  (Ventas) en vez de duplicarla — dispara `depositar_cheque_tercero`.
- `TesoreriaTransferencias/` — **Fase D** (la RPC ya está lista en C).
- **Informes:** nuevas pestañas en el `Informes/` existente (saldos, subdiario por cuenta, mayor de
  tesorería, movimientos por operación, cheques, comprobantes, histórico) — mismo criterio con que
  Compras sumó sus 3 pestañas.

Componentes UI: se reutilizan `Badge`, `Modal`, `ItemsTable` tal cual. Formularios nuevos:
`MovimientoTesoreriaForm`, `ChequePropioForm`, `ConciliacionForm` (y `TransferenciaForm` en Fase D).

`frontend/src/api/index.js` suma objetos siguiendo las convenciones `rpc()`/`unwrap`/`one`:
`CuentasBancariasAPI`, `AgrupacionesTesoreriaAPI`, `TiposComprobanteTesoreriaAPI`,
`MovimientosTesoreriaAPI` (incluye `transferencia`), `ChequesPropiosAPI`, `ConciliacionAPI`, y
extensiones de `InformesAPI` (`saldosTesoreria`, `subdiarioCuenta`, `mayorTesoreria`,
`movimientosPorOperacion`, `chequesTesoreria`, `comprobantesTesoreria`). `ChequesAPI` (Ventas) suma
`depositar`/`rechazar`.

Sección **"Tesorería"** nueva en el menú (`components/Layout`) con las entradas de arriba.

## 9. Migraciones propuestas

Fechadas después de la serie de Compras (`2026073012xxxx`); hoy es 2026-07-31.

```
20260731120000_tesoreria_schema.sql          -- agrupaciones_tesoreria, tipos_comprobante_tesoreria(+seed),
                                              -- ALTER cuentas_bancarias (clase/agrupacion/saldo_inicial),
                                              -- conciliaciones_bancarias, movimientos_tesoreria(+índices),
                                              -- cheques_propios, ALTER pago_proveedor_medios (FK cheque_propio),
                                              -- config_empresa (caja default), adjuntar audit_trigger
20260731120001_tesoreria_rls.sql             -- staff_all a las 5 tablas nuevas
20260731120002_rpc_tesoreria_movimientos.sql -- crear_/anular_movimiento_tesoreria, crear_transferencia
20260731120003_rpc_tesoreria_cheques.sql     -- depositar_/rechazar_cheque_tercero,
                                              -- crear_cheque_propio, actualizar_estado_cheque_propio
20260731120004_rpc_tesoreria_conciliacion.sql-- abrir_/marcar_/cerrar conciliacion
20260731120005_rpc_tesoreria_integracion.sql -- extensión crear_pago_proveedor -> movimientos,
                                              -- generar_movimiento_desde_recibo
20260731120006_rpc_reads_informes_tesoreria.sql -- movimientos_tesoreria_list + los 6 informes de §5.5
```

## 10. Secuenciación interna y dependencias

1. `…120000` schema → `…120001` RLS (bloque base; nada corre sin esto).
2. `…120002` movimientos → habilita alta manual + transferencias (ledger utilizable solo).
3. `…120003` cheques → engancha cartera de terceros (Ventas) y cheques propios.
4. `…120005` integración → conecta Compras (`crear_pago_proveedor`) y, con el retoque de `§4`, Ventas.
5. `…120004` conciliación y `…120006` informes son independientes entre sí una vez existe `…120002`.
6. **Standalone posible:** `crear_movimiento_tesoreria` + informe de saldos ya dan valor sin tocar
   Ventas/Compras — buen primer entregable verificable.

## 11. Cómo validar (smoke test propuesto)

Mismo estilo que el smoke test de Compras (`system_plan.md §3.1`):
1. Crear una caja (`clase='caja'`, `saldo_inicial=1000`) y un banco (`saldo_inicial=50000`); setear
   `tesoreria_caja_default_id`.
2. Movimiento manual: extracción `-500` del banco → saldo banco `49500`.
3. Transferencia banco→caja `2000` → banco `47500`, caja `3000` (par de movimientos cruzados).
4. Depositar un cheque de tercero en cartera → cartera baja, banco sube por `ACRED_CHEQUE`.
5. Crear un pago a proveedor con medio transferencia → aparece `-1` automático en la cuenta.
6. Emitir un cheque propio, pasarlo a `pagado` → `-1` en su cuenta.
7. Abrir conciliación del banco, tildar los movimientos, cerrar → diferencia esperada `0`.
8. Informe de saldos cuadra con la suma manual; subdiario muestra saldo corrido correcto.
9. Revisar `audit_log` para los INSERT/UPDATE de las tablas nuevas.
10. Revisar advisors (esperado: sólo los WARN deliberados de "shared staff" + RPC `SECURITY DEFINER`).
11. Borrar datos de prueba; resetear el contador de `mov_tesoreria` si se usó; base pristina.

## 12. Backlog / preguntas abiertas (no bloquean esta redacción)

- **Importación de extracto bancario** (parsear CSV/PDF del banco a líneas para conciliar
  automáticamente) — fuera de alcance de esta pasada; la conciliación es por tildado manual.
- **"Cupones"** (lotes de cupones de tarjeta, `system_plan.md §6/§7`) — no tienen modelo; confirmar si
  entran a Tesorería como un tipo de valor más o quedan como backlog aparte.
- **Numeración de comprobantes de tesorería** — se deja `movimientos_tesoreria.numero` opcional;
  confirmar si extracciones/depósitos manuales necesitan un número imprimible propio
  (`siguiente_numero('mov_tesoreria')`) o alcanza con el id.
- **Impresión/PDF** (movimientos, cheques) y **Consultas Tesorería 360°** — Fase D (`§1.1`).
- **Contabilidad** (asientos desde tesorería, informe "contabilidad") — Fase E, bloqueado.

## 13. Estado de este documento

Entrega de planificación, no código. Verificación previa hecha contra el esquema real aplicado:
- `cuentas_bancarias`, `cheques`, `recibos`/`recibo_medios`, `contadores`, `config_empresa` — DDL leído
  de `20260727120001_schema.sql`.
- `pago_proveedor_medios.cheque_propio_id` sin FK, `crear_pago_proveedor` (medios con
  `cuenta_bancaria_id`/`cheque_id`) y el handoff de cheque de tercero — leídos de
  `20260730120009_rpc_pagos_proveedor.sql`.
- `crear_recibo` ya puebla la cartera `cheques` y **no** referencia `cuenta_bancaria` — leído de
  `20260727120009_rpc_recibos.sql` (base del ⚠ de `§4`).
- Patrón RLS `staff_all` sin FORCE y adjunte de `audit_trigger` — `20260730120003_compras_rls.sql`,
  `20260730120002_procesos_generales_core.sql`.
- No hay colisión de nombres de tabla nuevos contra el esquema aplicado.

## 14. A confirmar antes de implementar

1. **Corte C/D de `crear_transferencia`:** ¿backend en C (propuesto) o todo en D?
2. **Retoque a Ventas (`§4` ⚠):** ¿se acepta extender `crear_recibo` de forma aditiva/opcional, o se
   prefiere la opción de asignación posterior sin tocar Ventas?
3. **Momento de impacto del cheque propio:** ¿al `pagado` (propuesto) o al emitir/entregar?
4. **Numeración** de movimientos manuales (ver `§12`).
