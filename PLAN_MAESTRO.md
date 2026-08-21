# Plan Maestro — CRM Marblock (unificado)

> **Qué es este documento.** Fuente única de estado del sistema. Unifica los 5 `system_plan*.md`
> (que **fueron borrados** el 2026-08-20 — ver abajo) más el tracker de cutover
> `supabase/MIGRATION_PLAN.md`, con todas las fases en un solo lugar. Lo **ya hecho** figura sólo
> como título; lo **pendiente** va detallado, que es lo único accionable.
>
> **Dónde quedaron los planes originales.** Se eliminaron al consolidarse acá, en dos tandas. Su
> contenido (DDL columna por columna, decisiones de diseño, racional de cada fase) sigue **íntegro
> en git**:
>
> | Documento | Leerlo con |
> |---|---|
> | `system_plan.md` + fases `_c_` / `_d_` / `_e_` / `_f_` | `git show 97ad046:system_plan.md` |
> | `cuenta2.md` · `productos.md` · `docs/superpowers/plans/2026-08-19-productos-pallets.md` | `git show fbeab89:cuenta2.md` |
>
> ```bash
> git log --oneline --all -- productos.md      # historial completo de cualquiera de ellos
> ```
>
> ⚠️ **El código los cita.** 14 migraciones y ~12 archivos de `frontend/src/` los nombran en
> comentarios de cabecera (`-- Companion de cuenta2.md`, `productos.md §3.2.1`,
> *"Companion de system_plan_fase_c_tesoreria.md §3"*), igual que `supabase/MIGRATION_PLAN.md` y
> `App.jsx`. Esas referencias **se resuelven con los comandos de arriba**, no abriendo el archivo.
> Las migraciones no se tocaron a propósito: son artefactos ya aplicados, y reescribir su cabecera es
> peor que la referencia colgada. Lo que esos comentarios necesitan saber está resumido en §5.
>
> **Tercera tanda — los 4 planes de `supabase/` (2026-08-20).** `MIGRATION_PLAN.md`,
> `TANGO_Migration.md`, `AUTH_SETUP.md` y `DATA_MIGRATION.md` también quedaron volcados acá con el
> mismo criterio: lo completo como título + una línea con la leyenda *completada*, lo pendiente con
> todo el detalle. En concreto → §2.1 (las 13 migraciones de Ventas), §3.2 (el runbook entero de
> Tango + las mecánicas de carga reutilizables), §3.4 (los dos pasos de dashboard de Auth) y §5.3
> (decisiones bloqueadas y reglas transversales).
>
> ⚠️ **Estos 4 archivos NO se borraron**, a diferencia de los `system_plan*.md`. Siguen en
> `supabase/` porque llevan **SQL y comandos ejecutables que se copian y pegan tal cual**
> (`POST_LOAD_VERIFY*.sql`, el `DO $$` de reseteo de secuencias, el INSERT de `auth.users`, las
> queries de descubrimiento de Tango) y porque `MIGRATION_PLAN.md` lo citan `CLAUDE.md` y las
> cabeceras de varias migraciones. **Ante divergencia: para el *estado* manda este archivo; para el
> *cómo* (comandos exactos), el de `supabase/`.**
>
> 📌 Nota de versionado: hasta el 2026-08-20 este archivo estaba **gitignoreado**; ese día se
> comentó la línea en `.gitignore` (`#PLAN_MAESTRO.md`), así que **ahora sí entra en git**. La
> advertencia contraria que quedó escrita en `supabase/MIGRATION_PLAN.md` está desactualizada.
>
> Última actualización: **2026-08-20**.

---

## 1. Estado de un vistazo

| # | Fase | Estado |
|---|---|---|
| 0–6 | Migración Express → Supabase (schema, RLS, RPCs, Auth, capa de datos, Edge Function PDF) | ✅ completo — *salvo la config de Auth del dashboard* |
| 4-bis | **Config de Auth en el dashboard** (apagar signup público + crear staff) | ⛔ **pendiente** — manual, crítico pre-go-live |
| 7 | **Cutover de datos (Tango → Supabase)** | ⛔ **bloqueado** — credenciales SQL Server |
| A | Compras + Procesos Generales (audit_log, tablas_generales) | ✅ completo |
| B | Consultas 360° Ventas / Compras | ✅ completo |
| C | Tesorería (ledger, cheques propios, conciliación) | ✅ completo |
| D | Consultas Tesorería + impresión + transferencias | 🔄 código listo — **falta deploy PDF** |
| E | Núcleo contable (plan de cuentas, asientos, informes) | 🔄 núcleo + frontend listos — **matriz bloqueada** |
| F/WS1 | Cobranzas Ventas → Tesorería | ✅ completo |
| F/WS2 | Ventas → Contabilidad (enganche) | 🔄 aplicado en `off` (no-op) — **matriz bloqueada** |
| F/WS3a | IVA multi-alícuota en Ventas | ✅ completo (impresión espera el deploy PDF) |
| F/WS3b | **Pedidos** | ⏸ **sin empezar** — falta decisión de modelado |
| — | Cuenta 2 (circuito paralelo Ventas/Compras) | 🔄 completo — **falta deploy PDF + smoke** |
| — | Productos por pallets (catálogo 25 productos) | 🔄 completo — **falta smoke E2E** |
| — | Remito sobre talonario preimpreso | 🔄 DB + frontend listos — **falta deploy PDF + smoke** |

**Un solo bloqueo técnico** (deploy de la Edge Function `pdf`) y **un solo bloqueo de datos**
(credenciales de Tango) explican casi todo lo que falta.

---

## 2. ✅ Completado — sin detalle

### 2.1 Migración a Supabase (Fases 0–6) — **completada**
- **Fase 0** — MCP habilitado contra `kkdbvzixwlyeahgianuc`.
- **Fase 1** — Fundación de base de datos (migración `0001`, 17 tablas).
- **Fase 2** — RLS `staff_all` (`0002`).
- **Fase 3** — RPCs de comprobantes: presupuestos, remitos, facturas, notas, recibos (`0003`–`0010`).
- **Fase 4** — Auth: frontend completo y verificado E2E *(queda config de dashboard → §3.4)*.
- **Fase 5** — Capa de datos del frontend sobre supabase-js.
- **Fase 6** — Edge Function PDF portada y desplegada (v1).
- **Migraciones de soporte** — `0011` lecturas/informes, `0012` campos para PDF, `0013` columnas
  fiscales AFIP (CAE) para el import histórico.
- **Express retirado** (2026-07-28).

**Las 13 migraciones de Ventas, una línea cada una** (de `supabase/MIGRATION_PLAN.md`; el detalle
largo sigue ahí). Todas **aplicadas y verificadas en vivo** contra `kkdbvzixwlyeahgianuc`: cada
familia de RPC se probó dentro de una transacción auto-abortada — un `RAISE` final devuelve los
valores calculados y hace rollback, así las tablas quedaban vacías para el cutover real.

| Migración | Qué hace | Estado |
|---|---|---|
| `0001_schema` | Port completo del schema: 17 tablas, 55 índices, funciones y triggers; FK circular `remitos↔facturas` partida (facturas primero, después `ALTER`); sin seeds. | ✅ completada |
| `0002_rls` | RLS habilitada + policy `staff_all` (sólo `authenticated`), grants a `authenticated`, revokes a `anon`, default privileges. | ✅ completada |
| `0003_rpc_presupuestos` | `crm_calc_totales` + `crear_/actualizar_/set_estado` presupuesto. **Es el patrón de referencia** del resto. | ✅ completada + probada |
| `0004_harden_function_privileges` | Fix de seguridad: `anon` podía ejecutar las RPC de escritura (las default privileges de Supabase le otorgan EXECUTE directo y `REVOKE … FROM PUBLIC` no lo saca). Revoke explícito + `search_path` fijado en 5 helpers. | ✅ completada |
| `0005_rpc_remitos` | `crear_/actualizar_/anular` remito (+ marca el presupuesto como convertido). | ✅ completada + probada |
| `0006_rpc_facturas` | `crear_/actualizar_/anular` factura, numeración A/B separada, enlaza remito→facturado y al anular lo libera. | ✅ completada + probada |
| `0007_rpc_notas` | `crear_nota` (NC/ND), hereda la letra de la factura y recalcula su estado. | ✅ completada + probada |
| `0008_fix_notas_numero_unique` | Fix de bug preexistente: NC y ND son contadores distintos que arrancan en el mismo número, pero `notas.numero` era UNIQUE global ⇒ la primera NC y la primera ND colisionaban. Relajado a UNIQUE `(tipo, numero)` — restricción **más laxa**, segura para la carga de datos reales. | ✅ completada |
| `0009_rpc_recibos` | `crear_recibo`: multi-medio (efectivo/transferencia/cheque/e-cheq) + imputación a varias facturas + alta de cheques en cartera; el total lo calcula el servidor. | ✅ completada + probada |
| `0010_revoke_item_helpers_from_anon` | Fix: los helpers de inserción de ítems creados en `0005`–`0007` conservaban EXECUTE para `anon` — el revoke de default privileges de `0004` no cubre funciones creadas después. | ✅ completada |
| `0011_rpc_reads_informes` | RPCs de lectura e informes en jsonb, **byte-idénticas al JSON del viejo Express**: los `*_list` (list+get+búsqueda cross-table+autovencer), `clientes_list` con saldo, `productos_actualizar_precios` y todos los `informe_*`. SECURITY INVOKER. | ✅ completada + probada |
| `0012_pdf_list_fields` | Soporte del port de PDF: agrega el `codigo` del producto dentro del json de ítems y la `direccion` del cliente en `notas_list` (el PDF de Express los joineaba y `0011` los había omitido). Aditiva. | ✅ completada + verificada |
| `0013_fiscal_afip_columns` | Prep del cutover de Tango: `cae`, `cae_vencimiento`, `afip_tipo_comprobante`, `afip_doc_tipo`, `afip_doc_nro` nullables en `facturas` y `notas`, para que las facturas históricas conserven su CAE. Ningún código de app las lee todavía. | ✅ completada |
| `seed.sql` | Semilla de config **sólo para fresh/dev** (empresa, contadores, cuentas). En prod se saltea: los valores reales vienen de la carga de datos. | n/a |
| Capa frontend | `lib/supabase.js` (singleton) + `api/index.js` reescrito sobre supabase-js con las mismas firmas por recurso + `PDFModal` apuntando a `{SUPABASE_URL}/functions/v1/pdf/…` con el Bearer de sesión. `client.js` y `api/pdf.js` quedaron muertos y se borraron. | ✅ completada |

- **Auth — parte de frontend: completada** (de `supabase/AUTH_SETUP.md`). `frontend/.env` con
  `VITE_SUPABASE_URL` + `VITE_SUPABASE_ANON_KEY` (la anon key es pública por diseño),
  `AuthProvider`/`useAuth` en `lib/auth.jsx`, `views/Login`, `App.jsx` con gate de sesión
  (loading → login → CRM), logout en la topbar. **Verificado E2E en el navegador con un usuario
  descartable**: gate → login → la sesión sobrevive al reload → logout. *Lo que falta es config de
  dashboard → §3.4.*
- **`DATA_MIGRATION.md` — superseded como fuente de datos (2026-07-28).** Apuntaba a un `pg_dump` del
  Postgres LAN, que era la base de **desarrollo** de este mismo sistema, no la data real de la
  empresa. Sobrevive sólo por sus **mecánicas de carga** (`session_replication_role = replica`,
  reseteo de secuencias, verificación), que el runbook de Tango reutiliza tal cual → transcriptas en
  §3.2.5 y §3.2.6.

### 2.2 Fases de expansión
- **Fase A — Compras + Procesos Generales.** Backend aplicado y verificado (2026-07-30, migraciones
  `20260730120000`–`…0011`) y frontend completo: 7 vistas `/compras/*`, formularios de comprobante de
  compra / pago a proveedor / nota de compra, IVA multi-alícuota, `audit_log` + `tablas_generales`,
  Libro IVA Compras.
- **Fase B — Consultas 360°.** `ConsultaCliente` + `ConsultaProveedor`, shell `Consulta360` y modales
  de drill-down (2026-07-31, sin migraciones).
- **Fase C — Tesorería.** Aplicada y verificada (2026-07-31, migraciones `20260731120000`–`…0007`):
  `movimientos_tesoreria`, `cheques_propios`, `conciliaciones_bancarias`, catálogos, RPCs de
  escritura/integración/informes, `crear_transferencia`, y las 4+1 pantallas operativas.
- **Fase D — Consultas Tesorería, impresión y transferencias.** Código completo y `npm run build` OK
  (2026-07-31). *Único pendiente: el deploy → §3.1.*
- **Fase E — Núcleo contable.** Aplicado vacío (2026-08-01, migraciones `20260801120000`–`…0004`):
  `plan_de_cuentas`, `asientos_contables`, `asiento_items`, alta manual `crear_asiento`/`anular_asiento`
  funcionando, e informes libro diario / libro mayor / sumas y saldos. **Frontend construido**
  (2026-08-14): `ContabilidadPlanCuentas`, `ContabilidadAsientos`, `AsientoForm`, 3 pestañas de
  informes. *(§8 paso 5 del plan de Fase E — el único que no dependía de Tango.)*
- **Fase F / WS1 — Cobranzas Ventas → Tesorería.** El recibo manda `cuenta_bancaria_id`; las cobranzas
  impactan el ledger (2026-08-01).
- **Fase F / WS3a — IVA multi-alícuota en Ventas.** Aplicado y probado E2E (2026-08-01, migraciones
  `20260802120000`–`…0002`), retrocompatible (ítem sin alícuota ⇒ 21%).
- **Fase F / WS2 — Enganche Ventas → Contabilidad.** Aplicado y probado (2026-08-14, migraciones
  `20260803120000`/`01`): `generar_asiento_desde_nota` (stub), backfill idempotente y CONSTRAINT
  TRIGGER diferido guardado por `config_empresa('contabilidad_auto_asientos')`, que arranca en `'off'`
  ⇒ **no-op verificado**. *La matriz sigue pendiente → §3.3.*

### 2.3 Trabajo posterior a la Fase F
- **Cuenta 2 — circuito informal aislado de Cuenta 1** (migraciones `20260815120000`–`…0003` +
  `20260820120001_cuenta2_material_id`). Sus 6 fases:
  - **Fase 1 — Base de datos y API.** ✅ 6 tablas (`clientes_cuenta2`, `proveedores_cuenta2`,
    `cuenta2_remitos` + items, `cuenta2_ctacte`, `cuenta2_cheques`), RLS `staff_all` y 15 funciones
    (`crear_/actualizar_/eliminar_remito_cuenta2`, `registrar_movimiento_cuenta2`,
    `transferir_cheque_cuenta2_a_cuenta1`, `informe_cta_cte_cuenta2`, los `*_list`, helpers).
  - **Fase 2 — Capa API frontend.** ✅ `frontend/src/api/cuenta2.js`.
  - **Fase 3 — Ventas → Cuenta 2.** ✅ `/cuenta2/ventas`.
  - **Fase 4 — Compras → Cuenta 2.** ✅ `/cuenta2/compras` (mismo componente `Cuenta2` con
    `tipoSector`); los proveedores C2 compran del catálogo de **materiales**, no de productos.
  - **Fase 5 — Cartera de cheques C2 + migración a C1.** ✅ `/cuenta2/cheques` con transferencia.
  - **Fase 6 — Pruebas y verificación.** ⏳ **no confirmada** → §3.6.
  *(Los checkboxes de `cuenta2.md` §4 quedaron sin tildar aunque el código está; ver §3.6.)*
- **Productos por pallets** — catálogo de 25 productos sembrado, columnas `pallets` /
  `unidades_por_pallet` en `productos` y en los `*_items`, combobox de productos, línea automática de
  pallet vacío, exclusión de "Pallet de Madera Vacío" / "Transporte" del descuento general
  (migraciones `20260819120000`–`…0003`, `20260820120000`). Sus 8 tareas:
  - **Task 1** — schema + seed de las 25 filas. ✅
  - **Task 2** — `pallets`/`unidades_por_pallet` a través de las RPC de escritura y lectura. ✅
  - **Task 3** — campos de pallets en el ABM de Productos (`api/index.js`). ✅
  - **Task 4** — hook `usePalletsVacios` (auto-sync de la línea de pallet de madera). ✅
  - **Task 5** — `ItemsTable`: combobox de productos + columnas Pallets/Unidades. ✅
  - **Task 6** — defaults de pallets + `usePalletsVacios` en los formularios de comprobante. ✅
  - **Task 7** — columna "Unidades por Pallet" en la vista de administración. ✅
  - **Task 8 — verificación manual end-to-end.** ⏳ **no confirmada** → §3.6.
- **Remito sobre talonario preimpreso** — `remito_numero_sugerido()` (peek que no consume),
  `crear_remito` con `p_numero`, campos `condiciones_venta` / `domicilio_obra` / `telefono_entrega`,
  contador cargado con el talonario real AGEE (próxima hoja **00001-00010325**), y template de
  sobreimpresión `preimpreso.ts` calibrado en mm sobre escaneo A4 (migraciones `20260820120001`/`02`).
  *Pendientes asociados: §3.1 (deploy) y §3.6 (smoke).*

---

## 3. ⏳ Pendiente — detallado

### 3.1 Deploy de la Edge Function `pdf` — **el bloqueo técnico #1**

Es el **único paso de aplicación** que separa a la Fase D, al desglose impreso de la Fase F/WS3 y a
todo el circuito de impresión de remitos preimpresos de estar terminados. Confirmado en vivo el
2026-08-20: la función desplegada es **`version 1` (~2026-07-27)**, anterior a Tesorería.

**Qué hay escrito localmente y no está en producción**
- 6 casos nuevos en el `switch` de `index.ts` (comprobantes de tesorería, cheques propios y de
  terceros, informes de saldos / subdiario / mayor de tesorería).
- `templates.ts`: `generarComprobanteTesoreria`, `generarCheque`.
- `reportes.ts`: `generarSubdiario`, `generarSaldos`, `generarMayorTesoreria`.
- Desglose de IVA por alícuota en los templates de factura y nota (`base.ts` / `templates.ts`).
- **Caso `cta-cte-cuenta2`** — el resumen de cuenta corriente de Cuenta 2. La v1 desplegada es del
  2026-07-27 y Cuenta 2 es del 2026-08-15, así que **este PDF tampoco funciona hoy en producción**.
  Su template está deliberadamente despegado del resumen oficial (`templates.ts`), porque puede
  terminar en manos de un cliente/proveedor y el circuito es informal.
- `preimpreso.ts` + rutas `?preimpreso=1` y `/pdf/remito/calibracion`.

**Por qué no se hizo todavía.** No hay sesión del CLI (`~/.supabase` sólo tiene telemetría) ni
`SUPABASE_ACCESS_TOKEN` en el entorno; y `deploy_edge_function` del MCP exige pegar inline el
contenido de los 5 `.ts` (~75 KB), con riesgo de corromper el bundle en silencio.

**Cómo hacerlo** (requiere un login interactivo, una sola vez — el usuario lo corre):
```bash
npx -y supabase@latest login
npx -y supabase@latest functions deploy pdf --project-ref kkdbvzixwlyeahgianuc
```
`deploy pdf` bundlea **la carpeta entera**, no hay que listar archivos.

**Riesgo: bajo.** Es aditivo (los casos existentes — factura/remito/nota/recibo/cta-cte/ventas — no se
tocan) y falla-seguro: si el bundle no compila, sigue corriendo la v1. No hay migraciones, ni cambios
de env/secrets, ni advisors que revisar. Rollback = redesplegar la carpeta anterior.

**Post-deploy — smoke de navegador** (era `system_plan_fase_d_consultas_tesoreria.md §6`, pasos 2–4 —
`git show 97ad046:system_plan_fase_d_consultas_tesoreria.md`):
1. Consultas → Cuenta → en un movimiento, "📄 PDF" abre el `PDFModal` en iframe.
2. Imprimir un cheque propio y uno de tercero.
3. Imprimir los 3 informes de tesorería (saldos, subdiario, mayor) desde `Informes/`.
4. Factura con dos alícuotas → el PDF muestra ambas tasas desglosadas.
5. Remito preimpreso: `?preimpreso=1` sobre la hoja **00001-00010325** (que después se anula).
6. Cuenta 2 → cta. cte. de un cliente C2 → "📄 PDF" del resumen.

> El frontend **no** requiere acción manual: Vercel (`crm-marblock`) despliega solo al pushear a `main`.

---

### 3.2 Cutover de datos desde Tango (Fase 7) — **el bloqueo de datos raíz**

Todo lo demás está construido sobre una base **vacía**. El bloqueo es el mismo que frena la
contabilidad automática (§3.3): **no hay credencial funcional de SSMS / SQL Server para la instancia
de Tango**.

Esta sección absorbe `supabase/TANGO_Migration.md` (**qué** se carga) y las mecánicas reutilizables de
`supabase/DATA_MIGRATION.md` (**cómo** se carga). Los dos archivos siguen en `supabase/` porque tienen
el SQL para copiar y pegar.

**Lo que sí está listo: el lado Supabase.** Verificación pre-cutover del 2026-07-28 vía MCP —
migraciones `0001`–`0013` aplicadas, **17/17 tablas con RLS + policy `staff_all`**, 33 funciones
públicas, **`anon` ejecuta 0 funciones y lee 0 tablas**, Edge Function `pdf` ACTIVE con
`verify_jwt=true`. Los security advisors devuelven sólo los warns **esperados por diseño**
(`rls_policy_always_true` ×17 por el `USING(true)` de shared-staff y
`authenticated_security_definer_function_executable` ×11 porque las RPC de escritura están hechas
para que las llame `authenticated`). No hay ítems de acción del lado de la base: **lo que falta es
data**.

#### 3.2.1 Decisiones bloqueadas (2026-07-28)

- **Reemplazo total, no convivencia.** Tango **se retira**; el CRM queda como único sistema de
  registro. Se migra **toda la historia** (cada entidad de ventas, años para atrás), no sólo los
  saldos abiertos.
- **Fuente: Tango Gestión (desktop) sobre Microsoft SQL Server**, por acceso directo a la base
  (restore de `.bak` o conexión read-only) ⇒ método de extracción **A** (§3.2.3). Los métodos B
  (Excel/Tango Live) y C (delta) quedaron descartados.
- **El volumen es chico** (< ~1k clientes, < ~10k comprobantes) ⇒ un ETL scripteado en Python/SQL
  alcanza y sobra; no hay que preocuparse por batching ni sharding.
- **El CRM emite los comprobantes de acá en adelante** ⇒ `contadores` tiene que retomar **después**
  del último número emitido por Tango, por tipo y punto de venta.
- **La emisión fiscal AFIP/CAE es un build futuro** (proyecto aparte), pero las facturas históricas de
  Tango **ya vienen con CAE** ⇒ se preservan los campos fiscales en el import (migración `0013`, ya
  aplicada) en vez de tener que re-migrar después.

#### 3.2.2 Alcance — qué puede recibir el destino

| Entra (tiene tabla destino) | No entra (sin destino al 2026-07-28) |
|---|---|
| Clientes, Productos/Artículos | Proveedores, Compras, Órdenes de compra |
| Presupuestos, Remitos, Facturas A/B, Notas C/D, Recibos | Stock / movimientos de inventario |
| Cheques (cartera), Cuentas bancarias, Config empresa, Contadores | Tesorería / caja-bancos, Asientos contables |

> ⚠️ **La columna derecha quedó desactualizada a favor.** Es del 2026-07-28, cuando el sistema era
> sólo Ventas. Desde entonces **Compras (Fase A), Tesorería (Fase C) y Contabilidad (Fase E) existen
> como módulos con sus tablas**, así que ya **no hay impedimento de schema** para traer esos datos.
> Lo que falta es el mapeo: el de §3.2.4 sólo cubre Ventas. **Decidir en el cutover si Compras /
> Tesorería / plan de cuentas también se cargan desde Tango** — el plan de cuentas en particular es
> el paso 1 de §3.3. Stock sigue sin destino.

#### 3.2.3 Secuencia del cutover (extracción método A — SQL Server directo)

Tango guarda todo en SQL Server y hay acceso directo, así que se toma el camino de mayor fidelidad:
leer las tablas fuente y scriptear el ETL. Como la data está en la LAN (inalcanzable desde acá), el
reparto de tareas es explícito:

1. **Conseguir la credencial de SQL Server** — es el bloqueo actual → §3.2.7.
2. **Descubrimiento de esquema — lo corre el usuario.** El schema de Tango es propietario y con
   códigos crípticos (`GVA*` para ventas, `STA*` para stock/artículos…), así que las tablas reales
   **se confirman contra la instancia, no se adivinan**. Correr en SSMS las dos queries de solo
   lectura de §3.2.7 (o `supabase/tango_discovery.sql`, ya listo) y pasar el resultado.
3. **Mapeo source→target + spec de export** — sale de ese output, completando la columna Tango de la
   tabla §3.2.4.
4. **Export** — a CSV (`bcp` o "Export Data" de SSMS), o restore del `.bak` donde se puedan producir
   los CSV; los archivos van a una carpeta local de esta Mac. Un **`.bak` o CSV, más una muestra de
   una factura con sus renglones y su cliente**, es lo que cierra el mapeo rápido.
5. **ETL (Python)** — transforma los CSV y carga en Supabase por la conexión directa (`psql`/`COPY`)
   → §3.2.5.
6. **Reset de secuencias + carga de `contadores`** → §3.2.5.
7. **Verificación** → §3.2.6.

> **Dry-run primero:** cargar una muestra chica en la base (hoy vacía), verificar, borrar, y **recién
> ahí** hacer el cutover real.

#### 3.2.4 Mapeo de entidades (Tango → Supabase)

Las columnas listadas son las del **destino** (confirmadas contra el schema vivo). Las de origen se
completan cuando llegue el export del paso 2 — cambian según la versión de Tango.

| Entidad Tango | → tabla(s) destino | Columnas clave a llenar | Gotchas |
|---|---|---|---|
| Clientes | `clientes` | `razon_social`, `cuit`, `condicion_iva`, `direccion`, `localidad`, `provincia`, `telefono`, `email`, `descuento_porcentaje`, `activo` | `cuit` y `condicion_iva` son **NOT NULL** ⇒ hace falta un default para los clientes sin CUIT (consumidor final). Los códigos de condición IVA de Tango se mapean a nuestros valores de texto. |
| Artículos | `productos` | `codigo`, `descripcion`, `precio_sin_iva`, `activo` | **El precio se guarda sin IVA.** Si Tango lo tiene con IVA, dividir por 1.21 al importar. `codigo` es único. |
| Presupuestos (+ renglones) | `presupuestos` + `presupuesto_items` | cabecera: `numero`, `punto_venta`, `numero_comp`, `fecha`, `fecha_vcto`, `cliente_id`, totales, `estado`; ítems: `descripcion`, `cantidad`, `precio_unitario`, `subtotal`, `orden` | Ver numeración y totales más abajo. |
| Remitos (+ renglones) | `remitos` + `remito_items` | `numero`, `punto_venta`, `numero_comp`, `fecha`, `cliente_id`, `estado`, opcional `factura_id`/`presupuesto_id` | Los remitos no llevan plata en nuestro schema. |
| Facturas A/B (+ renglones) | `facturas` + `factura_items` | `numero`, `punto_venta`, `numero_comp`, `tipo` (`factura_a`/`factura_b`), `fecha`, `cliente_id`, `neto_gravado`, `iva_alicuota`, `iva_monto`, `total`, `estado` | El CAE **sí** tiene dónde ir (migración `0013`). El `estado` (pendiente/parcial/cobrada) depende de si además se cargan las cobranzas. |
| Notas de Crédito/Débito (+ renglones) | `notas` + `nota_items` | `numero`, `punto_venta`, `numero_comp`, `tipo`, `tipo_letra`, `fecha`, `factura_id`, totales | **Siempre colgadas de una factura** (`factura_id` NOT NULL): cada NC/ND de origen tiene que resolver a una factura migrada o queda huérfana. |
| Recibos / Cobranzas | `recibos` + `recibo_medios` + `recibo_facturas` | recibo: `numero`, `punto_venta`, `numero_comp`, `fecha`, `cliente_id`, `total`; medios: `tipo`, `monto` (+ datos del cheque); imputaciones: `factura_id` | Multi-medio y multi-factura. Sólo se puede migrar con fidelidad completa si el origen trae el desglose de medios de pago **y** qué facturas canceló cada recibo. |
| Cheques en cartera | `cheques` | `numero`, `tipo`, `banco`, `titular`, `cuit_titular`, `fecha_emision`, `fecha_vcto`, `monto`, `estado`, opcional `cliente_id` | Si sólo interesan los ítems abiertos, traer únicamente los que siguen en cartera (no depositados/entregados). |
| Cuentas bancarias / empresa | `cuentas_bancarias`, `config_empresa` | — | Son pocos: normalmente se recargan a mano. |
| Numeración (últimos emitidos) | `contadores` | `tipo`, `punto_venta`, `ultimo_numero` | Tiene que continuar **después** del último número que emitió Tango, por tipo y punto de venta. |

**Dos formas de columna que conviene tener claras:** todo comprobante tiene `numero` (varchar, el
string formateado `PPPPP-NNNNNNNN`) **y** `numero_comp` (integer, sólo la parte numérica) — se setean
las dos al importar. El `id` es SERIAL: dejamos que Postgres asigne ids nuevos y el ETL cablea las FK
(`cliente_id`, `factura_id`, …) con esos ids nuevos; **los ids de Tango no necesitan sobrevivir**.

**Decisiones de diseño que fuerza esta migración**

- **Los comprobantes históricos entran por INSERT directo, no por las RPC.** Las `crear_*` sacan un
  número fresco de `contadores`; las filas históricas **ya traen el suyo**. Se insertan directo
  preservando `numero`/`punto_venta`/`numero_comp`/`fecha`, y recién después se setea cada
  `contadores.ultimo_numero` para que la próxima emisión desde la app no colisione.
- **Los totales se recalculan/verifican como netos + 21%.** `POST_LOAD_VERIFY` chequea
  `round(neto*0.21,2)=iva` y `neto+iva=total`. Cualquier dato de Tango con otra alícuota, otro
  redondeo o precios IVA incluido **aparece acá** y necesita una regla de mapeo.
- **Historia completa vs. sólo saldos abiertos era la gran palanca de esfuerzo** — quedó decidido:
  historia completa (§3.2.1).

#### 3.2.5 Mecánica de carga (reutilizada de `DATA_MIGRATION.md`)

**Prerequisito.** El **connection string directo** de Supabase: Dashboard → Project Settings →
Database → *Connection string* → **URI**
(`postgresql://postgres:[PASSWORD]@db.kkdbvzixwlyeahgianuc.supabase.co:5432/postgres`).
⚠️ **La contraseña no va por chat**: dejar el URI en un archivo gitignoreado y exportarlo local
(`export SUPABASE_DB_URL="…"`).

**1. Cargar con FKs y triggers diferidos.** La FK circular `remitos ↔ facturas` y los triggers de
`updated_at` pelean contra una carga masiva, así que el import va envuelto en
`session_replication_role = replica` (saltea validación de FK y triggers **sólo en esa sesión**):

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 <<SQL
BEGIN;
SET session_replication_role = replica;
\i datos.sql
SET session_replication_role = origin;
COMMIT;
SQL
```

Orden de dependencias: clientes/productos → presupuestos → remitos → facturas → notas → recibos →
cheques. Si alguna tabla ya tiene filas sembradas, `TRUNCATE … RESTART IDENTITY CASCADE` antes, o el
`COPY` choca con la PK (→ §3.2.8).

**2. Resetear todas las secuencias `SERIAL`.** El `COPY` inserta ids explícitos **sin avanzar** las
secuencias, así que el próximo insert de la app colisionaría. Re-sincronizar cada secuencia de
`public` con el `MAX(id)` de su tabla:

```sql
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT s.relname AS seq, t.relname AS tbl, a.attname AS col
    FROM pg_class s
    JOIN pg_depend d   ON d.objid = s.oid AND d.deptype = 'a'
    JOIN pg_class t    ON t.oid = d.refobjid
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
    WHERE s.relkind = 'S' AND t.relnamespace = 'public'::regnamespace
  LOOP
    EXECUTE format(
      'SELECT setval(%L, COALESCE((SELECT MAX(%I) FROM %I), 1), (SELECT MAX(%I) IS NOT NULL FROM %I))',
      r.seq, r.col, r.tbl, r.col, r.tbl);
  END LOOP;
END $$;
```

**3. Setear `contadores`.** No es una secuencia — está tecleada por `tipo` (+ `punto_venta`), así que
el `DO $$` de arriba no la toca: hay que **cargarla a mano** con el último número emitido por Tango
por tipo y punto de venta. *(Excepción ya resuelta: el contador de `remito` no sale de Tango sino del
talonario preimpreso AGEE — ya está cargado en `00001-00010324`, próxima hoja `00001-00010325`.)*

#### 3.2.6 Verificación post-carga

No inventar chequeos a mano: está escrito el script que cubre **todas** las tablas y controles —
conteo de filas (contra el origen), continuidad de numeración en `contadores`, integridad referencial
(11 chequeos de huérfanos), cordura de secuencias vs `MAX(id)`, coherencia de totales con IVA 21%, y
el cerrojo de RLS/`anon`/auth. Dos ediciones, los mismos chequeos:

- **`supabase/POST_LOAD_VERIFY.sql`** — edición psql (`\echo` + un `DO` con `RAISE NOTICE`):
  ```bash
  psql "$SUPABASE_DB_URL" -f supabase/POST_LOAD_VERIFY.sql
  ```
- **`supabase/POST_LOAD_VERIFY_MCP.sql`** — edición de una sola query que devuelve
  `seccion | item | status | detalle`. Se pega en el SQL Editor del dashboard, **o se corre desde acá
  por el MCP de Supabase** una vez terminada la carga.

Leer la columna `status`: todo debería dar `OK` / `ⓘ`, salvo **`usuarios auth` mientras no exista el
staff** (§3.4), que legítimamente muestra `⚠ FALTA staff`. Las filas de conteo y de `max emitido`
están marcadas `ⓘ` porque se comparan a ojo contra el origen (correr los mismos conteos allá).

Después: entrar por la app (ejercita Auth + RLS), abrir la cuenta corriente de un cliente y **emitir
un comprobante de prueba en un cliente descartable** para confirmar numeración y totales antes de
salir en vivo.

#### 3.2.7 Desbloquear la credencial de SQL Server — **el paso que frena todo**

Al 2026-07-28 el usuario no tiene un login de SQL Server que funcione en SSMS contra la instancia de
Tango (contraseña olvidada), así que las queries de descubrimiento no se pueden correr. Es un problema
de acceso LAN/organizacional, fuera de lo que un asistente sin acceso a la red puede resolver. Opciones,
de más barata a más cara:

1. **Windows Authentication en vez de SQL auth.** Si la instancia tiene autenticación integrada
   habilitada y la cuenta de Windows con la que se está logueado (u otra de admin) tiene un login
   mapeado, SSMS entra **sin contraseña de SQL** — elegir "Windows Authentication" en el diálogo de
   conexión en lugar de "SQL Server Authentication".
2. **La conexión que ya guarda el propio Tango.** El cliente de Tango Gestión se autentica contra ese
   mismo SQL Server todos los días: la instalación suele dejar el perfil de conexión (servidor, base,
   login) en un `.ini`/config local o en el registro de Windows, bajo el directorio de instalación.
   Vale la pena mirar antes de escalar.
3. **Preguntarle a quien lo instaló.** Quien haya puesto Tango/SQL Server (IT interno, o el revendedor
   Axoft/Tango que vendió la licencia) probablemente tenga la contraseña de `sa` o pueda emitir un
   login read-only nuevo — suele ser el arreglo real más rápido.
4. **Gestor de contraseñas / notas de traspaso** de un admin anterior, si existen.
5. **Último recurso — reset con admin local.** Con permisos de administrador de Windows en la máquina
   del SQL Server (RDP o acceso físico), la contraseña de `sa` se resetea arrancando el servicio en
   single-user mode (`sqlservr.exe -m`) y corriendo `ALTER LOGIN sa WITH PASSWORD = '...'` por
   `sqlcmd`. Requiere admin de sistema operativo y una ventana de mantenimiento (reinicio del
   servicio). *Si es el camino elegido, pedir los comandos exactos.*

**Queries de descubrimiento** (read-only, correr en SSMS contra la base de Tango y mandar el
resultado en CSV o pegado):

```sql
-- (a) Todas las tablas + columnas — para armar el mapeo origen → destino
SELECT c.TABLE_NAME, c.ORDINAL_POSITION, c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH
FROM INFORMATION_SCHEMA.COLUMNS c
JOIN INFORMATION_SCHEMA.TABLES t
  ON t.TABLE_NAME = c.TABLE_NAME AND t.TABLE_TYPE = 'BASE TABLE'
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;

-- (b) Conteo de filas por tabla — para detectar cuáles tienen data de verdad
SELECT s.name AS schema_name, t.name AS table_name, SUM(p.rows) AS filas
FROM sys.tables t
JOIN sys.schemas s     ON s.schema_id = t.schema_id
JOIN sys.partitions p  ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY s.name, t.name
HAVING SUM(p.rows) > 0
ORDER BY filas DESC;
```

Con (a)+(b) se identifican las tablas fuente reales, se completa la columna Tango del mapeo §3.2.4 y
se construye el ETL. **Definir también si se comparte un `.bak` o CSV**, y adjuntar una **muestra de
una factura + sus renglones + su cliente**.

#### 3.2.8 Minas conocidas antes del `COPY`

- **`contadores` está casi vacío.** Hoy sólo existen `asiento`, `pago_proveedor` y `remito` (este
  último ya cargado con el talonario real). **El resto de los contadores de Ventas no está sembrado**,
  así que hoy `crear_factura` y compañía fallan con *"Contador no encontrado"* — **no es un bug**, se
  cargan en el cutover.
- **La base ya no está vacía.** Quedan `clientes` id=1 ("Marblock SA") y, sobre todo, el **catálogo de
  25 productos sembrado por la migración `20260819120000`**. Si el dump de Tango trae esos mismos ids
  hay **conflicto de PK**. La nota de "base pristina" de `MIGRATION_PLAN.md` quedó desactualizada por
  el seed de pallets: **decidir explícitamente si el catálogo de productos viene de Tango o se
  conserva el sembrado**, antes de cargar.
- **Rollback.** Express fue borrado sin backup en git ⇒ el camino de vuelta es el **LAN Postgres que
  sigue corriendo**, no este repo.

---

### 3.3 Matriz de imputación contable (Fase E §8 pasos 2–4 + Fase F/WS2)

El DDL, las RPCs, los informes y el frontend contable **ya están**. Lo que falta es **qué cuenta se
debita y cuál se acredita por cada operación** — y eso **se valida con el contador, no se inventa**:
un asiento mal imputado es peor que no tener el módulo.

Hoy `generar_asiento_desde_factura` / `…_pago_proveedor` / `…_movimiento_tesoreria` / `…_nota`
**lanzan una excepción a propósito**, y el flag `config_empresa('contabilidad_auto_asientos')` está en
`'off'` (no-op verificado).

**Pasos, en orden** (los 3 primeros dependen de §3.2):
1. **Espejar `plan_de_cuentas` desde Tango** — códigos, jerarquía (`cuenta_padre_id`, `nivel`) y flag
   `imputable`.
2. **Definir y validar la matriz** con el contador. Borrador a revisar (transcripto acá desde
   `system_plan_fase_f_integracion_ventas.md §3.3`, hoy en git):

   | Operación | Debe | Haber |
   |---|---|---|
   | Factura A | Deudores por ventas (`total`) | Ventas (`neto_gravado`) · IVA Débito Fiscal (`iva_monto`) |
   | Factura A multi-alícuota | Deudores por ventas (`total`) | Ventas (`neto`) · una línea de IVA DF por cada tasa |
   | Factura B | Deudores por ventas (`total`) | Ventas (`neto`) · IVA DF (`iva_monto`) |
   | Nota de Crédito | Ventas (`neto`) · IVA DF | Deudores por ventas (`total`) |
   | Nota de Débito | Deudores por ventas (`total`) | Ventas · IVA DF |
   | Cobranza | Caja / Banco (cuenta del movimiento) | Deudores por ventas |

   **A confirmar con el contador:** ¿cuenta de Deudores única o por cliente/condición? ¿tratamiento de
   percepciones / IIBB en ventas? ¿la Factura B discrimina IVA contablemente? Y las operaciones de
   Compras y Tesorería (compra multi-alícuota, pago con retención, depósito, cheque rechazado…), que
   ni siquiera tienen borrador todavía.
3. **Reemplazar el cuerpo de los `generar_asiento_desde_*`** por la construcción de `p_lineas`
   delegando en `crear_asiento` (que ya valida `SUM(debe)=SUM(haber)` y que cada cuenta sea imputable).
4. **Smoke de generación automática** — con el flag en `on`, emitir una factura/pago/movimiento de
   prueba y verificar que imputa a las cuentas correctas, que el asiento cuadra, que aparece en el
   libro diario y que sumas y saldos da 0. Usar `generar_asientos_ventas_pendientes` para el backfill
   (es idempotente por `(referencia_tipo, referencia_id)`).
5. **Prender el flag** `contabilidad_auto_asientos = 'on'` — recién después de 1–4.

**Lo que se desbloquea al terminar:** las pestañas "Contabilidad" hoy vacías en las fichas 360° de
cliente / proveedor / cuenta (Fases B y D), y el informe "contabilidad" de Tesorería. Fuera de alcance
de esta pasada: Balance General y Estado de Resultados (paso posterior sobre sumas y saldos +
`tipo_cuenta`).

---

### 3.4 Configuración de Auth en el dashboard (Fase 4) — **no se puede vía MCP**

Absorbe `supabase/AUTH_SETUP.md`. El frontend ya está y verificado E2E (§2.1); lo que falta es
**config del proyecto que el MCP no puede tocar**, a mano en el dashboard de `kkdbvzixwlyeahgianuc`.
Son dos pasos, los dos **críticos antes del go-live**.

**1. ⚠️ CRÍTICO — deshabilitar el signup público.**
El modelo de auth es **"shared staff": todo usuario `authenticated` tiene CRUD completo** sobre
facturas, CUIT y cheques (policy `staff_all`, migración `0002`). La anon key es pública y viaja en el
browser, así que **si el self-signup queda prendido, cualquiera en internet se registra y entra con
acceso total**. El alta de staff tiene que ser **sólo por invitación**.

> **Dashboard → Authentication → Sign In / Providers → Email → apagar "Allow new users to sign up".**
> (Equivalente: Authentication → Settings → "Allow new users to sign up" = off, o sea
> `GOTRUE_DISABLE_SIGNUP=true`.)

Con el signup apagado, los usuarios sólo los crea un admin (paso 2) y `signInWithPassword` sigue
funcionando igual.

**2. Crear los usuarios reales del staff.**
*Recomendado — Dashboard:* Authentication → Users → **Add user** → email + contraseña → tildar
**"Auto Confirm User"** (así no hace falta mail de confirmación) → Create. Repetir por persona.

*Alternativa — SQL:* correr en el **SQL Editor del dashboard**, **no** por este chat, para que la
contraseña no quede escrita en la conversación. `crypt`/`gen_salt` (pgcrypto) están disponibles en el
proyecto. Crea el usuario **confirmado** + su identidad de email:

```sql
DO $$
DECLARE
  v_id    uuid := gen_random_uuid();
  v_email text := 'staff@empresa.com';   -- ← cambiar
  v_pass  text := 'CHANGE_ME';           -- ← cambiar; no commitear
BEGIN
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    -- GoTrue escanea estas columnas de token como `string`: deben ser '' (NUNCA NULL),
    -- si no el login falla con 500 "converting NULL to string is unsupported".
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token
  ) VALUES (
    v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    v_email, crypt(v_pass, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
    '', '', '', '', '', '', '', ''
  );
  INSERT INTO auth.identities (
    id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
  ) VALUES (
    gen_random_uuid(), v_id, v_id::text,
    jsonb_build_object('sub', v_id::text, 'email', v_email), 'email', now(), now(), now()
  );
END $$;
```

> Preferir el camino del Dashboard: maneja bien la fila de `auth.identities` y los campos de
> confirmación en todas las versiones de GoTrue. Usar el INSERT sólo si hay que scriptearlo, y
> **verificar el login después**.
>
> ⚠️ **El gotcha que ya nos mordió:** los usuarios creados por SQL necesitan las columnas de token en
> `''`, **nunca `NULL`**, o GoTrue tira 500 *"converting NULL to string is unsupported"*.

**3. Confirmación por email — nota.** Como el staff se crea desde admin con **Auto Confirm**, no hace
falta ningún envío de mails y "Confirm email" puede quedar como está. Si alguna vez se crea un usuario
por `signUp` con "Confirm email" en ON, ese usuario **no puede loguear hasta confirmar** — por eso la
regla es quedarse siempre en admin-created + auto-confirm.

**4. Verificación end-to-end.** Ya se corrió el 2026-07-27 con un usuario descartable (pasos 1–4 OK);
**hay que repetirla con los usuarios reales y sumar el paso 5, que es el que nunca se hizo**:
1. `cd frontend && npm run dev` → abrir la URL de LAN.
2. Sin sesión debe caer en la **pantalla de login** (`anon` ⇒ RLS niega todo).
3. Loguear con un usuario de staff → carga el CRM; la topbar muestra el email + **Salir**.
4. Recargar → la sesión persiste (localStorage). **Salir** → vuelve al login.
5. **Chequeo negativo (pendiente):** con el signup deshabilitado, intentar registrar una cuenta nueva
   tiene que **fallar**.

---

### 3.5 Pedidos (Fase F / WS3b) — **bloqueado en una decisión de negocio, no en datos**

Hoy no existe la entidad "pedido"; lo más cercano es `presupuestos`. **Hay que elegir antes de
escribir DDL:**

- **(A) Reusar presupuestos** — un "pedido" es un presupuesto en estado `aceptado`. Cero schema, sólo
  una vista/filtro. Sirve si "pedido" significa nada más que "presupuesto confirmado".
- **(B) Entidad propia** — `pedidos` + `pedido_items` (espejo de presupuestos, con contador `'pedido'`,
  RLS `staff_all` sin FORCE, `audit_trigger` sobre la cabecera, `set_updated_at`, FK opcional
  `presupuesto_id`, y que remito/factura puedan referenciarlo). Convierte la cadena documental en
  **presupuesto → pedido → remito/factura**. Necesario si el pedido tiene numeración, estado y reserva
  propios.

Migraciones ya bosquejadas para el caso (B): `…_pedidos_schema.sql` + `…_rpc_pedidos.sql`
(`crear_/actualizar_/convertir`). Nada más del plan depende de esta decisión.

---

### 3.6 Verificaciones pendientes

- **Frontend de Contabilidad — sin smoke contra la base.** Se construyó el 2026-08-14 con el proyecto
  Supabase caído; `npm run build` pasó pero las vistas `ContabilidadPlanCuentas` / `ContabilidadAsientos`
  y las 3 pestañas de informes **nunca se ejercitaron en el navegador**.
- **Remito con talonario — sin smoke de navegador.** Las migraciones se probaron contra la base
  (peek que no consume, formato inválido rechazado, duplicado traducido a mensaje legible, parseo
  `00001-00012345` → pv/comp, el contador adopta el talonario y no retrocede), pero el flujo en la UI
  requiere login y no se corrió.
- **Cuenta 2 — Fase 6 (pruebas) sin confirmar.** El código y las 4 migraciones están, pero no hay
  registro de que se haya corrido el flujo completo que `cuenta2.md §4/§5` pedía. Falta ejercitar en
  el navegador: ① venta C2 completa (cliente C2 → Remito X → cta. cte. → cobro con cheque);
  ② transferencia de ese cheque de la cartera C2 a la de C1, verificando que quede
  `estado='transferido_cuenta1'` y con `cheque_cuenta1_id` apuntando al cheque nuevo; ③ compra C2
  completa; ④ **el criterio de aceptación central: que ninguna operación de Cuenta 2 toque
  `clientes`, `proveedores`, `facturas`, `remitos` ni los movimientos de cta. cte. de Cuenta 1** —
  el aislamiento es la razón de ser del módulo, y es lo único que un bug silencioso rompería sin
  aviso.
- **Pallets — Task 8 (verificación E2E) sin confirmar.** Las 7 tareas de código tienen commit; la
  octava era una pasada manual sin commit y no hay registro de que se corriera. Falta: Productos
  muestra 25 filas en orden numérico; búsqueda por texto parcial (`holanda` → 20 y 21) y por código
  (`23` → Cordón); la línea de pallet vacío suma bien **excluyéndose a sí misma y a la de
  transporte**; el producto 25 sugiere $300.000 y sigue editable; los pallets se arrastran de
  presupuesto/remito a factura; en Notas se ven las columnas pero sin línea automática; el flujo
  completo en Cuenta 2 para `venta` y `compra`; y consola sin errores en todo el recorrido.
- **Sobreimpresión — verificada sin gastar hojas** (template corrido en Node + superposición sobre el
  escaneo), pero **falta la prueba sobre papel real** con la impresora de producción, después del
  deploy (§3.1).
- **Auth — falta el chequeo negativo.** La verificación E2E del login se corrió con un usuario
  descartable, pero **nunca se probó que el registro esté cerrado**, porque el signup público sigue
  prendido. Es el paso 5 de §3.4 y sólo se puede hacer después de apagarlo.
- **Go-live smoke-test completo — post-cutover.** Con la data real cargada y los usuarios de staff
  creados: entrar por la app y recorrer **todos** los módulos (clientes → presupuestos → remitos →
  facturas → notas → recibos), los informes y **todos los botones de PDF**, confirmando que la
  numeración continúa desde `contadores` y que los totales/IVA dan bien. Es el último paso antes de
  declarar el sistema en producción.

---

### 3.7 Riesgos operativos y decisiones con fecha

- ⚠️ **El proyecto Supabase se pausa por inactividad.** Pasó el 2026-08-02 → 08-14 (~12 días sin uso
  bastaron; toda consulta MCP daba timeout). Restaurado a mano desde el dashboard. **Decidir plan pago
  o un ping programado antes del go-live.**
- 📅 **El CAI del talonario de remitos vence el 25/11/2026.** El talonario actual abarca
  `00010101–00010400`. **Hay que reponer antes de esa fecha.**
- ⚠️ **Riesgo residual asumido en remitos:** el número lo tipea un humano. El `UNIQUE` impide
  duplicados pero **no** detecta un error de tipeo que caiga en un número libre. El prellenado con
  `remito_numero_sugerido()` + el aviso de desvío (>10 hojas) son mitigación, no garantía.
- ⚠️ **Hojas arruinadas: el flujo es anular y reemitir, no renumerar** — por eso el campo N° es
  readonly en edición. El número anulado queda ocupado para siempre: es el hueco esperado del talonario.
- ⚠️ **`RENGLONES_TALONARIO = 19` está duplicado** en `supabase/functions/pdf/preimpreso.ts` y en
  `frontend/src/components/Forms/ComprobanteForm.jsx`. **Si se cambia uno hay que cambiar el otro.**

---

### 3.8 Backlog / preguntas abiertas (no bloquean nada)

> La columna **Origen** cita los `system_plan*.md` borrados; se leen con
> `git show 97ad046:<archivo>`. El contenido accionable de cada ítem ya está resumido acá.

| Ítem | Origen | Estado |
|---|---|---|
| **Cupones** (lotes de cupones de tarjeta) | `system_plan.md §6/§7`, Fase C §12, Fase D §7 | Sin modelo. La pestaña de la ficha de cuenta queda fuera hasta definir alcance. |
| **Importación de extracto bancario** (parsear CSV/PDF del banco para conciliar automáticamente) | Fase C §12 | Fuera de alcance; hoy la conciliación es por tildado manual. |
| **Numeración de comprobantes de tesorería** | Fase C §12/§14 | `movimientos_tesoreria.numero` quedó opcional. Confirmar si extracciones/depósitos manuales necesitan `siguiente_numero('mov_tesoreria')` o alcanza el id. |
| **Impresión legal del cheque cartular** | Fase D §7 | `generarCheque` es un comprobante **interno** de respaldo, no el llenado del cheque físico. Imprimir sobre chequera pre-impresa es un diseño aparte. |
| **Filtro server-side de cheques por cuenta** | Fase D §7 | Hoy filtra en el cliente. Si se prefiere server-side, agregar `p_cuenta_id` a `informe_cheques_tesoreria`. |
| **Cuenta default de caja para cobranzas** | Fase F §2.3 | Espejo de `tesoreria_caja_default_id`. Conveniencia de UI (preselección vs. elección explícita siempre); no cambia el backend. |
| **Multi-alícuota en presupuesto / remito** | Fase F §4.1 | La columna existe y se hereda hacia la factura; activar la UI multi ahí es extensión futura. |
| **Momento de impacto del cheque propio** | Fase C §14 | Implementado al `pagado`; confirmar si debería ser al emitir/entregar. |
| **Estados contables** (Balance General / Estado de Resultados) | Fase E §5 | Paso posterior sobre `sumas_y_saldos` + `tipo_cuenta`. |
| **Checkboxes de `cuenta2.md` §4** | — | Sin tildar aunque el módulo está implementado; actualizar o marcar el doc como histórico. |

---

## 4. Orden recomendado

1. **Deploy de la Edge Function `pdf`** (§3.1) — un comando, riesgo bajo, cierra Fase D + WS3a +
   impresión de remitos de una sola vez. **Empezar por acá.**
2. **Smokes pendientes** (§3.6) — contabilidad en el navegador, remito en la UI, prueba sobre papel.
3. **Config de Auth en el dashboard** (§3.4) — barato y crítico antes del go-live.
4. **Credenciales de Tango** (§3.2) — es el bloqueo raíz; todo lo de abajo espera acá.
5. **Cutover de datos** (§3.2) — con las minas de PK y `contadores` resueltas de antemano.
6. **Go-live smoke-test completo** (§3.6) — todos los módulos, informes y PDFs contra la data real.
7. **Matriz de imputación + prender el flag contable** (§3.3).
8. **Decidir Pedidos (A o B)** (§3.5) — se puede hacer en paralelo, no depende de datos.

---

## 5. Referencia — reglas transversales

Lo que no se deduce del código de un vistazo. §5.1 y §5.2 vienen de `cuenta2.md` y `productos.md`
(**borrados**; el detalle completo está en git, ver header); §5.3 es lo mismo para
`MIGRATION_PLAN.md`, que **sigue en `supabase/`**.

### 5.1 Catálogo de productos — la fuente de verdad es la migración

La planilla de 25 productos (descripción, unidades por pallet, precio unitario sin IVA) **está
replicada exacta** en el seed de `supabase/migrations/20260819120000_productos_pallets_schema.sql`
—verificado fila por fila—, con `ON CONFLICT (codigo) DO UPDATE`. Esa migración, no un `.md`, es
donde se lee o se corrige el catálogo.

Reglas del modelo que no son obvias leyendo el schema:

- **El precio se guarda siempre por unidad**, nunca por pallet. Al cargar `X` pallets, el frontend
  escribe `cantidad = X × unidades_por_pallet` y el precio unitario queda intacto.
- **`cantidad` sigue siendo `DECIMAL(10,3)` a propósito.** El requisito de "sin decimales" se cumple
  del lado de la aplicación (`pallets × unidades_por_pallet` es entero por construcción); **ninguna
  migración cambia el tipo de la columna**, y cambiarlo rompería filas históricas.
- **`pallets` es nullable** en los `*_items`: las filas viejas no lo tienen y eso es válido.
- **`nota_items` también recibió las columnas** aunque `productos.md` no lo pedía, porque `NotaForm`
  usa el mismo `ItemsTable` compartido: sin eso la grilla mostraría un input de Pallets que no
  persiste, en silencio.
- **La línea de pallet vacío (`es_pallet_vacio`) se auto-calcula excluyéndose a sí misma y a la de
  transporte**, y deja de auto-sincronizarse en cuanto el usuario la edita o la elige a mano.
- **`es_pallet_vacio` / `es_transporte` quedan fuera del descuento general** (migración
  `20260820120000`).
- ⚠️ **Inconsistencia de nombre, deliberadamente sin tocar:** el producto 24 se llama `'Pallet'` en
  la base y en la planilla, pero los requisitos y varios comentarios lo llaman "Pallet de Madera
  Vacío". Es el mismo ítem; el flag `es_pallet_vacio` —no el nombre— es lo que lo identifica en el
  código.

### 5.2 Cuenta 2 — los invariantes del circuito informal

Circuito paralelo **sin IVA y sin numeración fiscal**, cuya razón de ser es el **aislamiento total**
del circuito oficial. Los invariantes que hay que no romper:

- **Entidades propias**: `clientes_cuenta2` / `proveedores_cuenta2` son tablas separadas, no un flag
  sobre `clientes` / `proveedores`. La cta. cte. C2 **no se mezcla** con la oficial.
- **Remito X es el único comprobante**, de venta y de compra. Su número es **texto libre cargado a
  mano** — sin `contadores`, sin punto de venta fiscal, sin autonumeración.
- **No se emiten recibos ni órdenes de pago**: el cobro/pago impacta el saldo directo (debe/haber).
- **No toca tesorería oficial**: ni cajas ni cuentas bancarias de Cuenta 1. Los cheques van a la
  cartera C2 y sólo pasan a la oficial por la transferencia explícita
  (`transferir_cheque_cuenta2_a_cuenta1`), que marca `estado='transferido_cuenta1'` y guarda
  `cheque_cuenta1_id`.
- **No mueve stock** (el sistema todavía no lleva control de stock).
- **Comparte el catálogo de productos** con los mismos precios de lista, aplicando el descuento del
  cliente/proveedor. Excepción posterior al doc: **los proveedores C2 compran del catálogo de
  `materiales`**, no de `productos` (commit `e3d0643`).
- **Acceso para todos los usuarios** — por eso la RLS es la misma `staff_all` de siempre, sin rol
  aparte.
- El PDF de resumen C2 usa un template **despegado** del oficial a propósito: puede terminar en manos
  de un cliente y el circuito es informal.

### 5.3 Migración a Supabase — decisiones y reglas transversales

Lo que `supabase/MIGRATION_PLAN.md` fijó de una vez y aplica a todo lo que se escriba después.

**Decisiones bloqueadas**

| Área | Decisión |
|---|---|
| **Modelo de auth** | **Shared staff** — todo usuario autenticado tiene CRUD completo; `anon` denegado. Una sola puerta de login, sin ownership por fila. |
| **Datos existentes** | Migrar la data operativa real al cutover. *(Al fijarse era el Postgres LAN; el 2026-07-28 la fuente pasó a ser **Tango** → §3.2.)* |
| **PDF** | **Edge Function** — el `routes/pdf.js` de Express portado a Supabase; Express desaparece por completo. |
| **Totales** | Recalculados **dentro de las RPC** (autoritativo, anti-tamper). El browser nunca setea un total. |

**Arquitectura destino**

- **Frontend**: `@supabase/supabase-js` (`VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`), Supabase Auth
  (email/password), rutas con gate de sesión. Lecturas por PostgREST, escrituras por `.rpc()`.
- **Transacciones → RPC**: cada operación atómica de comprobante (numeración + cabecera + N ítems +
  estado) es una función `SECURITY DEFINER` que reutiliza `siguiente_numero()` y
  `recalcular_estado_factura()`.
- **Totales en SQL**: `crm_calc_totales()` porta la lógica de IVA del viejo `utils/calculos.js`.
- **Seguridad**: RLS en todas las tablas; `authenticated` full, `anon` nada; `GRANT EXECUTE` de las
  RPC sólo a `authenticated`.

**Regla aprendida — vale para toda migración de RPC futura:** **revocar EXECUTE de `PUBLIC, anon`
explícitamente en cada función, helpers incluidos.** No alcanza con `ALTER DEFAULT PRIVILEGES`: las
default privileges de Supabase otorgan EXECUTE a `anon` directo, `REVOKE … FROM PUBLIC` no lo saca, y
el revoke de default privileges **no cubre funciones creadas después**. Fue el mismo bug dos veces
(`0004` y `0010`).

> ⚠️ Ojo con el enunciado viejo *"RLS `FORCE`d on every table"* de `MIGRATION_PLAN.md`: **quedó
> superado**. Las tablas llevan RLS habilitada **sin `FORCE`**, justamente porque las RPC
> `SECURITY DEFINER` corren como dueñas de la tabla y `FORCE` les aplicaría RLS a ellas también,
> bloqueando las escrituras. Está documentado inline en la migración `0002` y en `CLAUDE.md`.
