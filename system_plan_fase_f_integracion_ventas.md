# Plan de Sistema — Fase F: Completar / integrar el módulo de Ventas (especificación técnica)

> Companion de `system_plan.md`. Ventas fue el módulo base (migraciones `0001`–`0013`) y se construyó
> **antes** de que existieran Compras (Fase A), Tesorería (Fase C) y Contabilidad (Fase E). Esta fase
> **no crea un sector nuevo**: cierra los enganches que quedaron abiertos entre Ventas y esas
> funcionalidades, y salda dos ítems del backlog de Ventas (`system_plan.md §7`).
>
> **Estado (2026-08-01):** **WS1 ✅ implementado**; **WS3 IVA multi-alícuota ✅ implementado** (DB +
> frontend + template de PDF; falta sólo redesplegar la Edge Function `pdf`). Pendientes: **WS2**
> (Ventas→Contabilidad, bloqueado en la matriz de la Fase E) y **WS3 · Pedidos** (necesita confirmar su
> definición de negocio, §4.2).

## 1. Alcance (workstreams elegidos)

| WS | Qué | Bloqueo | Tamaño |
|---|---|---|---|
| **WS1** ✅ | **Cobranzas Ventas → Tesorería**: que un recibo con medio efectivo/transferencia impacte el ledger. | **Hecho** (2026-08-01) — backend ya estaba (Fase C `0205`); se completó el frontend. | Chico |
| **WS2** | **Ventas → Contabilidad**: generar asientos desde factura/nota (y cobranza vía tesorería). | La **matriz de imputación** (Fase E §3, crédito/débito por operación) — datos de Tango. | Medio (interfaz ahora, cuerpo después) |
| **WS3** ½ | **IVA multi-alícuota en Ventas** ✅ (2026-08-01) + **Pedidos** ⏳ (backlog `system_plan.md §7`). | Multi-alícuota: ninguno; "Pedidos" necesita confirmar alcance de negocio. | Grande |

> **No incluido** (se descartó en el scoping): la pestaña "Contabilidad" de la ficha 360° del cliente
> (`ConsultaCliente`) — queda como placeholder hasta que haya asientos que mostrar (WS2 + matriz).

---

## 2. WS1 — Cobranzas de Ventas → Tesorería ✅ (implementado 2026-08-01)

> **Hecho:** `ReciboForm.jsx` ahora recolecta `cuenta_bancaria_id` por medio efectivo/transferencia
> (selector de cuenta; efectivo opcional con "— Sin impacto en tesorería —", transferencia con la cuenta
> real en vez de sólo texto en `detalle`). `npm run build` OK. Smoke E2E con rollback: recibo efectivo con
> caja → emite `movimientos_tesoreria` COBRANZA(+1), saldo de la caja sube, idempotente; sin cuenta → se
> comporta como antes. Sólo faltó frontend (el backend ya estaba). Pendiente opcional: §2.3 (caja default).

### 2.1 Qué ya existe (no tocar)
Fase C (`20260731120005_rpc_tesoreria_integracion.sql`) **ya extendió `crear_recibo`** de forma aditiva:
si un medio `efectivo`/`transferencia` trae `cuenta_bancaria_id`, emite una **COBRANZA (+1)** en
`movimientos_tesoreria` vía el helper `tes_emitir_cobranza` (idempotente por
`referencia_tipo='recibo_medios'`). Si el medio **no** trae cuenta, el recibo se comporta exactamente
como hoy. La firma de `crear_recibo` no cambió y `RecibosAPI.create` ya pasa `data.medios` tal cual —
**el backend no requiere ninguna migración nueva.**

También existe `generar_movimiento_desde_recibo(p_recibo_id, p_asignaciones jsonb)` para **backfill**
de recibos históricos (asignarles cuenta después del cutover).

### 2.2 El gap: el formulario de recibo no manda la cuenta
El editor de medios (inline en `frontend/src/views/Recibos/index.jsx` + `ReciboForm`) sólo recolecta
`tipo`/`monto`/datos de cheque; **no ofrece elegir la cuenta** para efectivo/transferencia, así que hoy
ninguna cobranza llega al ledger. Cambios (sólo frontend):

1. En el medio, cuando `tipo ∈ {efectivo, transferencia}`, mostrar un `<select>` de cuentas
   (`CuentasBancariasAPI.list()` / la API que ya usa Tesorería) y guardar `cuenta_bancaria_id` en el
   objeto del medio. Para cheque/echeq no aplica (esos van a cartera y se acreditan desde Tesorería).
2. `RecibosAPI.create` no cambia (ya reenvía `medios` completo). Verificar que el objeto del medio
   incluya `cuenta_bancaria_id` (string u int; el RPC hace `NULLIF(...,'')::int`).
3. UX: si el usuario deja la cuenta vacía, el recibo se emite igual (cobranza sin impacto de saldo,
   comportamiento legacy) — no forzar, sólo avisar suavemente.

### 2.3 Opcional — cuenta default de caja para cobranzas
Espejo de `tesoreria_caja_default_id` (que usa `crear_pago_proveedor` para efectivo): agregar
`config_empresa('ventas_caja_cobranza_default_id')` y, si está seteada, preseleccionar esa cuenta para
medios `efectivo`. Es conveniencia de UI; no cambia el backend. **Decisión abierta**: preselección vs.
elección explícita siempre.

---

## 3. WS2 — Ventas → Contabilidad (asientos) ⛔ (matriz)

### 3.1 Qué ya existe
Fase E (`20260801120003`) dejó `generar_asiento_desde_factura(p_factura_id)` como **stub que lanza
excepción** hasta validar la matriz. `crear_asiento` manual funciona; los informes libro
diario/mayor/sumas y saldos leen `asientos_contables`.

### 3.2 Diseño de la integración (lo que agrega esta fase)
1. **Nuevas interfaces** (mismas reglas que Fase E — stub que lanza hasta la matriz):
   - `generar_asiento_desde_nota(p_nota_id integer)` — NC/ND (no existía).
   - La **cobranza contable** NO se genera desde el recibo directamente: se deriva del movimiento de
     tesorería que ya emite el recibo (`generar_asiento_desde_movimiento_tesoreria`, Fase E) para **no
     contar dos veces**. Se documenta este criterio para evitar el doble asiento cobranza/depósito.
2. **Disparo (hook) config-guarded**: extender `crear_factura`/`crear_nota` de forma **aditiva** para,
   al final, invocar `generar_asiento_desde_*` **sólo si** `config_empresa('contabilidad_auto_asientos')
   = 'on'`. Default `off` → hoy es un no-op (no rompe nada mientras la matriz esté bloqueada). Cuando se
   valide la matriz, se prende el flag y los comprobantes nuevos asientan solos.
3. **Backfill**: `generar_asientos_ventas_pendientes(p_desde date, p_hasta date)` — recorre
   facturas/notas del período sin asiento (`asientos_contables` no tiene `referencia` a ese id) y las
   asienta. Idempotente por `(referencia_tipo, referencia_id)` (mismo criterio que el ledger).

### 3.3 La matriz de imputación (la parte bloqueada — validar con el contador)
Estas filas son **borrador para validar**, NO para aplicar sin revisión (`system_plan_fase_e §3`).
Cuentas de ejemplo; los códigos reales salen del `plan_de_cuentas` espejado de Tango.

| Operación | Debe | Haber |
|---|---|---|
| **Factura A** (venta gravada) | Deudores por ventas (`total`) | Ventas (`neto_gravado`) · IVA Débito Fiscal (`iva_monto`) |
| **Factura A multi-alícuota** (WS3) | Deudores por ventas (`total`) | Ventas (`neto`) · IVA DF por cada alícuota (una línea por tasa) |
| **Factura B** (cons. final) | Deudores por ventas (`total`) | Ventas (`neto`) · IVA DF (`iva_monto`) — IVA no discriminado igual se imputa |
| **Nota de Crédito** | Ventas (`neto`) · IVA DF (`iva`) | Deudores por ventas (`total`) — reversa de la factura |
| **Nota de Débito** | Deudores por ventas (`total`) | Ventas · IVA DF — mismo signo que la factura |
| **Cobranza** (desde tesorería) | Caja/Banco (cuenta del movimiento) | Deudores por ventas |

Puntos a confirmar con el contador: cuenta de Deudores (única vs. por cliente/condición), tratamiento
de percepciones/IIBB en ventas si aplicara, y si B discrimina o no IVA contablemente.

### 3.4 Migraciones (propuestas, no aplicadas)
- `..._rpc_contabilidad_generacion_ventas.sql` — `generar_asiento_desde_nota` (stub) +
  `generar_asientos_ventas_pendientes` (usa las de Fase E) + hook config-guarded en
  `crear_factura`/`crear_nota`. El cuerpo real de imputación se completa recién con la matriz (§3.3).
- `INSERT config_empresa('contabilidad_auto_asientos','off')`.

---

## 4. WS3 — IVA multi-alícuota + Pedidos

### 4.1 IVA multi-alícuota en Ventas ✅ (implementado 2026-08-01)

> **Hecho** (migraciones `20260802120000`..`02`, aplicadas): `alicuota_iva_id` en los 4 `*_items`;
> `crear_/actualizar_` presupuesto/factura + `crear_nota` recalculan con `crm_calc_totales_multi_alicuota`
> (firmas idénticas → backward-compat: ítem sin alícuota ⇒ 21%); los `*_list` exponen `alicuota_iva_id` +
> `iva_porcentaje` por ítem. Frontend: `ItemsTable` con columna IVA opcional, `ComprobanteForm` (factura) y
> `NotaForm` con selector por ítem + `TotalesBoxMulti`; `Facturas`/`Notas` cargan `AlicuotasIvaAPI`. Template
> de PDF (`base.ts`/`templates.ts`) desglosa IVA por alícuota. `npm run build` OK. Smoke E2E con rollback:
> factura 21%+10.5% → neto 2000 / IVA 315 / total 2315; factura sin alícuota → 21% (1210). **Pendiente: el
> redeploy de la Edge Function `pdf`** para que el desglose salga impreso (mismo deploy pendiente de Fase D).
> Presupuesto/remito quedan en 21% (la columna existe y se hereda; su UI multi es una extensión futura).

Hoy Ventas es **21% fijo a nivel cabecera** (`facturas.iva_alicuota=21`, `crm_calc_totales`); los
`*_items` de Ventas **no tienen** columna de alícuota. Compras ya resolvió multi-alícuota y **casi toda
la infraestructura es reutilizable**:
- `alicuotas_iva(id, descripcion, porcentaje)` — **catálogo ya existe** (seed 21/10.5/27/0…).
- `crm_calc_totales_multi_alicuota(p_items jsonb, p_descuento numeric) RETURNS jsonb` — **ya existe**
  (agrupa por alícuota → neto/IVA/total; ítem sin `alicuota_iva_id` ⇒ 21%).
- Frontend: `TotalesBoxMulti` + `calcTotalesMulti` — **ya existen** (los usa Compras).

Trabajo del port:
1. **Schema** (`ALTER`, aditivo y retrocompatible): agregar `alicuota_iva_id INTEGER REFERENCES
   alicuotas_iva(id)` (**nullable**; `NULL` ⇒ fila 21%) a `presupuesto_items`, `factura_items`,
   `remito_items`, `nota_items`. Las filas y formularios viejos que no lo mandan siguen dando 21% →
   **cero data migration**.
2. **RPCs**: re-crear `crear_/actualizar_presupuesto`, `crear_/actualizar_factura`, `crear_nota`
   (y sus items helpers) para leer `alicuota_iva_id` por ítem y computar con
   `crm_calc_totales_multi_alicuota` en vez de `crm_calc_totales`. El total lo sigue calculando el
   servidor (regla anti-tamper intacta). La cabecera guarda los agregados; `iva_alicuota` de cabecera
   queda como legacy (tasa "principal" para el caso simple).
3. **Frontend**: en `ComprobanteForm`/`ItemsTable`, selector de alícuota por ítem + cambiar el preview
   a `TotalesBoxMulti`/`calcTotalesMulti` (ya construidos). Default 21% para no cambiar el flujo común.
4. **PDF**: los templates de factura/nota deben mostrar el **desglose por alícuota** cuando haya más de
   una (update de la Edge Function `pdf`, aditivo).

> Decisión abierta: ¿todos los comprobantes de Ventas o sólo factura/nota? Presupuesto/remito no
> liquidan IVA fiscal, pero conviene que el ítem arrastre su alícuota para que la conversión
> presupuesto→factura la herede. Recomendado: la columna en los 4, la UI activa en factura/nota.

### 4.2 Pedidos (backlog `system_plan.md §7`) — **necesita confirmar definición**
Hoy no existe entidad "pedido"; el más cercano es `presupuestos`. Dos modelados posibles:
- **(A) Reusar presupuestos**: un "pedido" = presupuesto en estado `aceptado`. Cero schema; sólo una
  vista/filtro. Sirve si "pedido" es sólo "presupuesto confirmado".
- **(B) Entidad propia** `pedidos` + `pedido_items` (espejo de presupuestos, con contador, RLS, audit,
  y FKs `presupuesto_id?`/que remito y factura puedan referenciarlo): un eslabón real en la cadena
  documental **presupuesto → pedido → remito/factura**. Necesario si el pedido tiene numeración,
  estado y reserva propios distintos del presupuesto.

**Antes de escribir DDL hay que confirmar cuál** (pregunta abierta del backlog). El resto del plan no
depende de esto.

---

## 5. Migraciones propuestas (Fase F — ninguna aplicada)

Fechadas después de Contabilidad (`202608011200xx`). WS1 no lleva migración (backend ya hecho).

```
20260802120000_ventas_multialicuota_schema.sql        WS3  ALTER *_items ADD alicuota_iva_id (nullable→21%)
20260802120001_rpc_ventas_multialicuota.sql           WS3  re-crea crear_/actualizar_ presupuesto/factura/nota
                                                            con crm_calc_totales_multi_alicuota
20260802120002_rpc_contabilidad_generacion_ventas.sql WS2  generar_asiento_desde_nota (stub) +
                                                            generar_asientos_ventas_pendientes + hook
                                                            config-guarded ⛔ (cuerpo tras validar matriz)
20260802120003_config_flags_ventas.sql                WS1/2 config_empresa: contabilidad_auto_asientos='off',
                                                            ventas_caja_cobranza_default_id=''
20260802120004_pedidos_schema.sql                     WS3  pedidos + pedido_items (+ RLS/audit/contador)
                                                            — SÓLO si se elige el modelado (B) (§4.2)
20260802120005_rpc_pedidos.sql                        WS3  crear_/actualizar_/convertir pedido — idem
```

## 6. RLS y auditoría
- Tablas nuevas (si va Pedidos-B): `pedidos`, `pedido_items` al array `staff_all` **sin FORCE** (mismo
  patrón de siempre); `audit_trigger()` a `pedidos` (no a items); `set_updated_at` a `pedidos`;
  contador `'pedido'` en `contadores`.
- `ALTER *_items ADD COLUMN` (WS3) no toca RLS (las tablas ya tienen `staff_all`).
- RPCs nuevas/recreadas: `SECURITY DEFINER`, `search_path` fijado, `REVOKE ... FROM PUBLIC, anon` +
  `GRANT EXECUTE TO authenticated` explícito (regla aprendida de `MIGRATION_PLAN.md`).

## 7. Orden de ejecución y dependencias
1. **WS1** — hacerlo ya (sólo frontend; backend probado en Fase C). Da valor inmediato: las cobranzas
   empiezan a impactar el ledger.
2. **WS3 multi-alícuota** — cuando se priorice; no bloqueado. Aditivo/retrocompatible (NULL ⇒ 21%), así
   que se puede aplicar el schema sin migrar datos y activar la UI gradualmente.
3. **WS2 hooks** — aplicar los stubs + el flag `off` en cualquier momento (no-op). **Prender el flag y
   completar la matriz** recién cuando se desbloquee Tango (Fase E §8, pasos 1–3).
4. **Pedidos** — bloqueado en la decisión de negocio (§4.2), no en datos.

## 8. Cómo validar
- **WS1**: emitir un recibo efectivo con cuenta elegida → aparece un `movimientos_tesoreria` COBRANZA
  (+1) por ese medio; el saldo de la cuenta sube; reejecutar no duplica (idempotencia). Sin cuenta → se
  comporta como hoy. Smoke con rollback como en las otras fases.
- **WS3**: factura con dos ítems a 21% y 10,5% → `crm_calc_totales_multi_alicuota` devuelve el desglose,
  el total server-side cuadra, el PDF muestra ambas tasas; una factura vieja (sin `alicuota_iva_id`)
  sigue liquidando 21%.
- **WS2**: con el flag `on` y una matriz de prueba, `crear_factura` deja un asiento balanceado que
  aparece en libro diario y cuadra en sumas y saldos; con el flag `off`, ningún asiento (no-op).
