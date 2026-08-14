# Plan de Sistema — Fase E: Núcleo contable (especificación técnica) — ✅ NÚCLEO APLICADO / ⛔ matriz bloqueada

> Companion de `system_plan.md` (roadmap §3 Fase E, §6 "Datos contables") — baja a DDL el núcleo
> contable que las otras fases dejan como placeholder ("Consultas > contabilidad", "Informe:
> contabilidad").
>
> **Estado (2026-08-01): NÚCLEO APLICADO VACÍO en producción; sólo la matriz de imputación sigue
> bloqueada en datos.** A pedido del usuario se aplicaron las 5 migraciones (`20260801120000`..`04`,
> ver §7) al proyecto `kkdbvzixwlyeahgianuc` vía Supabase MCP, con las **tablas vacías**: schema + RLS +
> `crear_asiento`/`anular_asiento` (alta manual, **funciona**) + informes libro diario/mayor/sumas y
> saldos. Smoke test de un asiento balanceado 121=121 con rollback: OK, cero residuo. Lo que **sigue
> bloqueado** es **poblar `plan_de_cuentas`** y **validar la matriz de imputación** (generación
> automática de asientos), porque ambas cosas requieren espejar la contabilidad real de Tango → dependen
> de las **credenciales de SQL Server que faltan** (`supabase/TANGO_Migration.md §7`,
> `supabase/MIGRATION_PLAN.md` Fase 7). Por eso `generar_asiento_desde_*` está aplicado pero **lanza una
> excepción a propósito** hasta que se valide la matriz (§3). Frontend de Contabilidad: **sin construir**.

## 1. Qué desbloquea esta fase

Todas las demás fases dejaron un mismo hueco marcado "bloqueado — Fase E":
- "Consultas > contabilidad" de Ventas, Compras y Tesorería (`system_plan.md §6`;
  `system_plan_fase_d_consultas_tesoreria.md §2.1`).
- "Informe: contabilidad" y el "mayor contable" completo de Tesorería (`system_plan.md §5`; el
  "mayor de cuentas bancarias" de Fase C es sólo el de tesorería, no el contable).
- El módulo "Datos contables" de Procesos Generales (`system_plan.md §6`).

Todos ellos pasan a ser **vistas filtradas sobre `asientos_contables`** una vez que exista este núcleo.

## 2. Tablas

### 2.1 `plan_de_cuentas` (jerárquico)

```sql
CREATE TABLE plan_de_cuentas (
  id             SERIAL PRIMARY KEY,
  codigo         VARCHAR(30)  NOT NULL UNIQUE,        -- '1.1.01.001' (espeja el código de Tango)
  descripcion    VARCHAR(200) NOT NULL,
  tipo_cuenta    VARCHAR(20)  NOT NULL
    CHECK (tipo_cuenta IN ('Activo','Pasivo','Patrimonio','Ingreso','Egreso','Orden')),
  cuenta_padre_id INTEGER REFERENCES plan_de_cuentas(id) ON DELETE RESTRICT,  -- self-FK, jerarquía
  nivel          SMALLINT NOT NULL DEFAULT 1,
  imputable      BOOLEAN NOT NULL DEFAULT TRUE,        -- sólo las hoja reciben asientos; las de agrupación no
  activo         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMP NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_plan_cuentas_padre ON plan_de_cuentas(cuenta_padre_id);
CREATE INDEX idx_plan_cuentas_tipo  ON plan_de_cuentas(tipo_cuenta);
```

> **Éste es el que hay que espejar de Tango.** El árbol de cuentas de la empresa (códigos, jerarquía,
> qué es imputable) es un dato real que vive en el SQL Server de Tango. Redactar la tabla no está
> bloqueado; llenarla con el plan correcto, sí.

### 2.2 `asientos_contables` + `asiento_items` (partida doble)

```sql
CREATE TABLE asientos_contables (
  id              SERIAL PRIMARY KEY,
  numero          INTEGER NOT NULL,                    -- correlativo por ejercicio; ver §4 numeración
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

CREATE TABLE asiento_items (
  id         SERIAL PRIMARY KEY,
  asiento_id INTEGER NOT NULL REFERENCES asientos_contables(id) ON DELETE CASCADE,
  cuenta_id  INTEGER NOT NULL REFERENCES plan_de_cuentas(id),
  debe       DECIMAL(14,2) NOT NULL DEFAULT 0 CHECK (debe  >= 0),
  haber      DECIMAL(14,2) NOT NULL DEFAULT 0 CHECK (haber >= 0),
  detalle    VARCHAR(300),
  orden      INTEGER NOT NULL DEFAULT 0,
  CONSTRAINT chk_debe_xor_haber CHECK (NOT (debe > 0 AND haber > 0))   -- una línea es debe O haber
);
CREATE INDEX idx_asiento_items_asiento ON asiento_items(asiento_id);
CREATE INDEX idx_asiento_items_cuenta  ON asiento_items(cuenta_id);
```

- **El asiento balanceado** (`SUM(debe) = SUM(haber)`) no se puede expresar como CHECK de fila; se
  valida en la RPC `crear_asiento` (raise si no cuadra), igual que los totales de comprobante se
  validan server-side en Ventas/Compras. Opcional: `CONSTRAINT TRIGGER … DEFERRABLE` como cinturón.
- **Enlace polimórfico** `referencia_tipo`/`referencia_id` — mismo criterio que `movimientos_tesoreria`
  (`system_plan_fase_c_tesoreria.md §2`): un asiento puede nacer de una factura, un pago, un
  movimiento de tesorería, o ser manual.

## 3. Integración — de dónde salen los asientos (la parte realmente bloqueada)

El **DDL** de arriba no está bloqueado. Lo que está bloqueado es la **matriz de imputación**: qué
cuenta se debita y cuál se acredita por cada tipo de operación (venta A/B, compra multi-alícuota, pago
con retención, cobranza, depósito, cheque rechazado, …). Esa matriz:
- depende del **plan de cuentas real** (§2.1) — hay que tenerlo cargado para poder referenciar cuentas;
- debe **validarse con el contador/Tango**, no inventarse — un asiento mal imputado es peor que no
  tener el módulo.

Por eso la generación automática de asientos (`generar_asiento_desde_factura(id)`,
`…desde_pago_proveedor(id)`, `…desde_movimiento_tesoreria(id)`, etc.) se **especifica como interfaz
acá** pero su cuerpo (el mapeo débito/crédito) queda para cuando se desbloquee (§8). Mientras tanto,
`crear_asiento` manual funciona (permite cargar asientos a mano sin la matriz).

```sql
-- Interfaces (cuerpo pendiente de la matriz de imputación validada):
crear_asiento(p_fecha date, p_descripcion text, p_lineas jsonb,
              p_origen text DEFAULT 'manual', p_referencia_tipo text DEFAULT NULL,
              p_referencia_id integer DEFAULT NULL) RETURNS asientos_contables
  -- valida SUM(debe)=SUM(haber) y que cada cuenta_id sea imputable; numera con siguiente_numero('asiento').
anular_asiento(p_id integer) RETURNS asientos_contables            -- estado='anulado' (no DELETE)
generar_asiento_desde_factura(p_factura_id integer)          RETURNS asientos_contables   -- ⛔ matriz
generar_asiento_desde_pago_proveedor(p_pago_id integer)      RETURNS asientos_contables   -- ⛔ matriz
generar_asiento_desde_movimiento_tesoreria(p_mov_id integer) RETURNS asientos_contables   -- ⛔ matriz
```

## 4. Numeración

Fila propia en `contadores` (patrón de `pago_proveedor`, `system_plan.md §4.7`):
```sql
INSERT INTO contadores (tipo, punto_venta, ultimo_numero, descripcion)
VALUES ('asiento', '00000', 0, 'Asiento contable') ON CONFLICT (tipo) DO NOTHING;
```
`crear_asiento` llama `siguiente_numero('asiento')`. (Si se quiere reiniciar por ejercicio, el reset
del contador se hace en el cierre anual — decisión operativa, no de esquema.)

## 5. Informes contables (desbloquean los placeholders)

Todos read-only sobre `asientos_contables` + `plan_de_cuentas`, formato `jsonb` como los demás
informes:

```sql
informe_libro_diario(p_desde date, p_hasta date)                  RETURNS jsonb  -- asientos cronológicos
informe_libro_mayor(p_cuenta_id integer, p_desde date, p_hasta date) RETURNS jsonb  -- por cuenta, con saldo corrido
informe_sumas_y_saldos(p_desde date, p_hasta date)                RETURNS jsonb  -- balance de comprobación
-- "Consulta > contabilidad" de cada sector = libro mayor / asientos filtrados por
--   (referencia_tipo, referencia_id) del comprobante que se está mirando -> se enchufa en las
--   fichas 360° de Fases B y D como la pestaña "Contabilidad" que hoy es placeholder.
```

- **Estados contables** (Balance General / Estado de Resultados) son un paso posterior sobre
  `sumas_y_saldos` + la clasificación `tipo_cuenta` — fuera de esta primera pasada del núcleo.

## 6. RLS y auditoría

- Mismo `staff_all` sin `FORCE`: agregar `plan_de_cuentas, asientos_contables, asiento_items` al array
  `tbls` (`system_plan.md §4.12`). (Podría restringirse la escritura contable a un rol más chico en el
  futuro, pero el modelo actual es "shared staff".)
- `audit_trigger()` (Fase A) adjunto a `plan_de_cuentas` y `asientos_contables` (no a `asiento_items`:
  ruido, ya cuelgan del asiento).

## 7. Migraciones propuestas

**✅ Aplicadas el 2026-08-01** (vía Supabase MCP, tablas vacías), fechadas después de la serie de
Tesorería (`2026073112xxxx`):

```
20260801120000_contabilidad_schema.sql        ✅ plan_de_cuentas, asientos_contables, asiento_items,
                                              --  índices, contador 'asiento', trigger de balanceo
                                              --  diferido (cinturón), updated_at + audit_trigger
20260801120001_contabilidad_rls.sql           ✅ staff_all a las 3 tablas
20260801120002_rpc_contabilidad_asientos.sql  ✅ crear_asiento (manual), anular_asiento — FUNCIONAN
20260801120003_rpc_contabilidad_generacion.sql✅(stub) generar_asiento_desde_* — aplicado pero lanza
                                              --  excepción hasta validar la matriz (§3)
20260801120004_rpc_reads_informes_contables.sql ✅ libro_diario, libro_mayor, sumas_y_saldos
```

> Nota: el schema real agregó, sobre el DDL de §2, un `CONSTRAINT TRIGGER` diferido `trg_asiento_balanceado`
> (valida `SUM(debe)=SUM(haber)` al confirmar, salteando los `borrador`) como cinturón además de la
> validación server-side en `crear_asiento`. Advisors post-aplicación: sólo los WARN by-design de siempre
> (`rls_policy_always_true`, `authenticated_security_definer_function_executable`) — no hizo falta
> `_advisor_fixes`.

Frontend (se difiere con la fase): sección **"Contabilidad"** en el menú —
`ContabilidadPlanCuentas/` (ABM del árbol), `ContabilidadAsientos/` (alta manual + listado),
pestañas de informes (Libro Diario / Mayor / Sumas y Saldos) en `Informes/`, y el relleno de las
pestañas "Contabilidad" placeholder de las fichas 360° (Fases B/D).

## 8. Ruta de desbloqueo

**✅ Ya hecho (2026-08-01):** aplicadas las migraciones de §7 (tablas vacías) y verificado el alta
manual — asiento balanceado cargado con `crear_asiento`, libro diario/mayor/sumas y saldos cuadrando
(smoke test con rollback, cero residuo). El núcleo manual **ya es operativo**.

Para pasar de "núcleo aplicado" a "contabilidad automática completa" **falta, en orden**:
1. **Credenciales de SQL Server de Tango** (el bloqueo raíz — mismo que frena el resto del cutover,
   `supabase/MIGRATION_PLAN.md` Fase 7, `supabase/TANGO_Migration.md §7`).
2. **Espejar `plan_de_cuentas`** desde Tango (códigos, jerarquía, imputables) → poblar §2.1.
3. **Definir y validar la matriz de imputación** con el contador (qué cuentas mueve cada operación) →
   **reemplazar el cuerpo de `generar_asiento_desde_*`** (hoy stubs que lanzan excepción) por la
   construcción de `p_lineas` que delega en `crear_asiento` (§3).
4. **Smoke test de la generación automática**: generar un asiento desde una factura/pago/movimiento de
   prueba y ver que imputa a las cuentas correctas y cuadra.
5. **Frontend de Contabilidad** (§7): menú + `ContabilidadPlanCuentas/` + `ContabilidadAsientos/` +
   pestañas de informes + relleno de las pestañas "Contabilidad" placeholder de las fichas 360° (Fases B/D).

El paso 5 (y el alta manual de asientos) **no depende de Tango** y puede encararse ya; los pasos 2-4 sí
esperan las credenciales. Nada de esto bloquea a las Fases A–D.
