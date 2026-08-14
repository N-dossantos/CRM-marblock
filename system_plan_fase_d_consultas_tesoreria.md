# Plan de Sistema — Fase D: Consultas Tesorería + Impresión + Transferencias (especificación técnica)

> Companion de `system_plan.md` (roadmap §5/§6) y de `system_plan_fase_c_tesoreria.md` (que construye
> el ledger). Esta fase **no agrega tablas ni RPCs de escritura nuevas**: es capa de presentación
> sobre lo que la Fase C ya deja en la base. Mismo espíritu que la Fase B (`system_plan.md §3.1`), que
> se resolvió "sin backend nuevo".
>
> **Estado (2026-08-01):** **código completo** — frontend + Edge Function ya editados, `npm run build`
> OK, sin migraciones de base. La precondición "Fase C aplicada" ya está **cumplida** (migraciones
> `20260731120000`..`07` en producción, ver `system_plan_fase_c_tesoreria.md`). **Queda un único paso de
> aplicación: redesplegar la Edge Function `pdf`** con los templates/rutas de tesorería — la desplegada
> sigue en `version 1` (~2026-07-27, anterior a Tesorería), así que los PDFs de movimientos/cheques no
> renderizan hasta hacerlo. Procedimiento en **§5.1 (Deploy — pendiente)**.

## 1. Alcance

`system_plan.md §3` define Fase D como **"Consultas Tesorería + impresión de movimientos/cheques +
transferencias"**. Los tres entregables:

1. **Consultas Tesorería 360°** — ficha integral por **cuenta** (patrón de Fase B, reusando el shell
   `components/Consultas/Consulta360`).
2. **Impresión / PDF** de movimientos, cheques (terceros y propios) e informes de tesorería — rutas
   nuevas en la Edge Function `pdf/` + templates, consumidas por el `PDFModal` existente.
3. **Transferencias (frontend)** — la RPC `crear_transferencia` ya se redacta en Fase C
   (`system_plan_fase_c_tesoreria.md §5.1`); acá se le pone pantalla.

### 1.1 Precondiciones (de Fase C)

- Tablas `movimientos_tesoreria`, `cheques_propios`, `tipos_comprobante_tesoreria`,
  `agrupaciones_tesoreria`, `conciliaciones_bancarias` + `cuentas_bancarias` extendida.
- RPCs de lectura: `movimientos_tesoreria_list`, `informe_subdiario_cuenta`,
  `informe_saldos_tesoreria`, `informe_mayor_tesoreria`, `informe_cheques_tesoreria`,
  `informe_comprobantes_tesoreria`; y `crear_transferencia`.
- Confirmaciones abiertas de C que tocan a D (`system_plan_fase_c_tesoreria.md §14`): el **corte C/D
  de `crear_transferencia`** (backend en C, pantalla en D — asumido acá).

## 2. Consultas Tesorería 360°

### 2.1 La entidad es la **cuenta**

En Ventas/Compras la entidad de la consulta es el cliente/proveedor. En Tesorería es la **cuenta
bancaria/caja**: se elige una cuenta y se ve todo su detalle. Los ítems que `system_plan.md §6` lista
para "Consultas Tesorería" (cuentas, cheques de terceros, cheques propios, cupones, comprobantes,
transferencia de valores, contabilidad) mapean a **sub-pestañas** de esa ficha:

| Sub-pestaña | Fuente (RPC de Fase C) | Filtro |
|---|---|---|
| **Movimientos** (subdiario con saldo corrido) | `informe_subdiario_cuenta(cuenta_id, desde, hasta)` | por cuenta (server-side) |
| **Cheques de terceros** (depositados/entregados vía esta cuenta) | `informe_cheques_tesoreria(...)` | por cuenta (cliente-side, ver §2.3) |
| **Cheques propios** (emitidos desde esta cuenta) | `informe_cheques_tesoreria(...)` | por `cuenta_bancaria_id` |
| **Transferencias** (patas que tocan esta cuenta) | `movimientos_tesoreria_list` con `origen='transferencia'` | por cuenta |
| **Comprobantes** (todos los movimientos) | `movimientos_tesoreria_list(cuenta_id, …)` | por cuenta |
| **Conciliación** (estado de conciliaciones) | `conciliaciones_bancarias` (PostgREST) | por cuenta |
| **Contabilidad** | — | **placeholder "bloqueado — Fase E"** |
| **Cupones** | — | **backlog** (sin modelo, `§6`) |

Cabecera de la ficha: descripción de cuenta, banco, `clase` (banco/caja/valores), agrupación,
`saldo_inicial` y **saldo actual** (badge, reusando `selSaldo` del shell).

### 2.2 Reuso de `Consulta360` (con una generalización chica)

El shell `Consulta360` ya aporta: panel izquierdo con buscador + lista de entidades, badge de saldo
en el ítem seleccionado, cabecera + sub-pestañas `[{id,label,count,render}]`. **Pero** hoy su filtro y
su etiqueta están cableados a `razon_social`/`cuit` (líneas 27-31, 58, 66 de
`components/Consultas/Consulta360.jsx`), que una cuenta no tiene.

Dos caminos:
- **(Recomendado)** Generalizar el shell de forma retro-compatible: props opcionales
  `getLabel(e)` (default `e => e.razon_social`), `getSubtitle(e)` (default `e => e.cuit`) y
  `matchFn(e, search)` (default = el filtro actual). `ConsultaCliente`/`ConsultaProveedor` no cambian
  (usan los defaults); `ConsultaCuenta` pasa accessors de cuenta. Cambio de una sola vez, en un
  componente ya probado.
- **(Fallback sin tocar el shell)** Mapear cada cuenta a `{ id, razon_social: descripcion, cuit: banco }`
  antes de pasarla — funciona con cero cambios, pero ensucia la semántica.

Se recomienda la generalización. `VentaDetalle`/`CompraDetalle` (los modales de drill-down de Fase B)
tienen su análogo nuevo `MovimientoDetalle` (ver §3.3).

### 2.3 Sin backend nuevo

Igual que Fase B, todo sale de RPCs de Fase C. El único ajuste posible es de **cliente**: si
`informe_cheques_tesoreria` no filtra por cuenta server-side, se filtra en el cliente (precedente:
`PresupuestosAPI.list` filtró `cliente_id` en el cliente en Fase B, `system_plan.md §3.1`). No se
crean RPCs. Si se prefiere el filtro server-side, es un `p_cuenta_id` opcional agregable a esa lectura
en la migración de lecturas de C — decisión de C, no bloquea D.

## 3. Impresión / PDF

### 3.1 Cómo enchufa en lo que ya existe

La Edge Function `supabase/functions/pdf/index.ts` es un `switch (resource)` sobre
`/pdf/<resource>/<id>`: cada caso **lee con una RPC (o PostgREST) reenviando el JWT del usuario** (RLS
aplica), llama a un `generar*` de `templates.ts`/`reportes.ts`, y responde con `enviarPDF(buffer,
nombre)`. El frontend no linkea la URL: `pdfUrl(resource, id)` (en `src/api/index.js`) arma un path
legacy `/api/pdf/<resource>/<id>` y `PDFModal` lo reescribe a
`${VITE_SUPABASE_URL}/functions/v1/pdf/<path>` con `Authorization: Bearer`, renderizando el blob en un
iframe. **Agregar impresión = agregar casos al switch + templates + entradas `pdfUrl`.** No hay
esquema nuevo.

### 3.2 Rutas nuevas

```ts
// en index.ts, dentro del switch(resource):
case 'movimiento-tesoreria': {   // comprobante interno de un movimiento (orden de pago / recibo interno)
  const mov = await supabase.from('movimientos_tesoreria')
    .select('*, cuenta:cuentas_bancarias(*), tipo:tipos_comprobante_tesoreria(*)')
    .eq('id', Number(id)).single()               // lectura directa PostgREST, como getEmpresa()
  if (mov.error || !mov.data) return jsonError('Movimiento no encontrado', 404)
  const buffer = await generarComprobanteTesoreria(mov.data, await getEmpresa())
  return enviarPDF(buffer, `Movimiento-${id}`)
}
case 'cheque-propio': { /* .from('cheques_propios')… -> generarCheque(..., 'propio') */ }
case 'cheque':        { /* .from('cheques')…         -> generarCheque(..., 'tercero') */ }
// Informes (patrón de 'cta-cte'/'ventas', reusando las RPC jsonb de Fase C):
case 'subdiario-tesoreria':  { /* informe_subdiario_cuenta(id, desde, hasta) -> generarSubdiario */ }
case 'saldos-tesoreria':     { /* informe_saldos_tesoreria() -> generarSaldos */ }
case 'mayor-tesoreria':      { /* informe_mayor_tesoreria(desde, hasta) -> generarMayorTesoreria */ }
```

> **Lecturas directas por PostgREST** (no RPC) para movimiento/cheque: precedente `getEmpresa()` en
> `index.ts` ya hace `.from('config_empresa')`. RLS igual aplica (JWT reenviado). Así D **no necesita
> agregar `p_id` a las listas de C** ni ninguna migración de base.

### 3.3 Templates y drill-down

- **`templates.ts`**: `generarComprobanteTesoreria` (cabecera empresa + cuenta + tipo + monto/signo +
  concepto + referencia al origen) y `generarCheque` (detalle del cheque — **no** es la impresión legal
  del cartular; es un comprobante interno de respaldo, ver `§7`).
- **`reportes.ts`**: `generarSubdiario`, `generarSaldos`, `generarMayorTesoreria` (mismo molde que
  `generarRankingDeudores`/`generarResumenVentas`).
- **Frontend**: `pdfUrl` suma `movimiento-tesoreria`, `cheque-propio`, `cheque`, `subdiario-tesoreria`,
  `saldos-tesoreria`, `mayor-tesoreria`. El botón "📄 PDF" vive en el modal `MovimientoDetalle` (nuevo,
  espeja `VentaDetalle`) y en las cabeceras de los informes de tesorería (`Informes/`).
- **Deploy**: `supabase functions deploy pdf` (o `deploy_edge_function` vía MCP) tras editar la función
  — es una sola función, se re-despliega entera. **Procedimiento completo (pendiente de ejecutar) en
  §5.1.**

## 4. Transferencias (frontend)

Backend (`crear_transferencia`, par débito/crédito atómico) ya está en Fase C. Falta:
- **`TransferenciaForm`** (`components/Forms/`): cuenta origen, cuenta destino (≠ origen), monto,
  fecha, concepto. Preview del efecto en ambos saldos. Llama `MovimientosTesoreriaAPI.transferencia`.
- **Entrada**: botón "Transferencia" dentro de `TesoreriaMovimientos/` **o** una vista
  `TesoreriaTransferencias/` dedicada + entrada de menú. Se recomienda el botón en Movimientos (menos
  superficie), con el listado de transferencias filtrado por `origen='transferencia'`.
- **Impresión**: el comprobante de transferencia reutiliza la ruta `movimiento-tesoreria` (se imprime
  cualquiera de las dos patas, que se referencian entre sí).

## 5. Inventario de frontend (Fase D)

```
frontend/src/views/ConsultaCuenta/index.jsx        -- ficha 360° por cuenta (usa Consulta360 + tabs de §2.1)
frontend/src/components/Consultas/MovimientoDetalle.jsx  -- modal drill-down + botón PDF
frontend/src/components/Forms/TransferenciaForm.jsx -- (si no se hizo en C)
frontend/src/components/Consultas/Consulta360.jsx   -- + props getLabel/getSubtitle/matchFn (retro-compatible)
frontend/src/api/index.js                           -- pdfUrl: +6 recursos; MovimientosTesoreriaAPI.transferencia (si falta)
frontend/src/App.jsx                                -- ruta /consultas/cuenta
frontend/src/components/Layout/index.jsx            -- 3ra entrada "Cuenta" en la sección "Consultas"
supabase/functions/pdf/index.ts                     -- +6 casos en el switch
supabase/functions/pdf/templates.ts                 -- generarComprobanteTesoreria, generarCheque
supabase/functions/pdf/reportes.ts                  -- generarSubdiario, generarSaldos, generarMayorTesoreria
```

**Migraciones de base: ninguna.** Sólo cambia frontend + la Edge Function (que se re-despliega).

### 5.1 Deploy — pendiente (hacerlo más adelante)

> El código ya está escrito y `npm run build` pasa. Este es el **único paso de aplicación que falta**.
> Es **aditivo** (6 casos nuevos en el `switch` + templates nuevos; los casos existentes —
> factura/remito/nota/recibo/cta-cte/ventas — no se tocan) y **reversible** (se redespliega la versión
> anterior). Un deploy fallido **no** reemplaza la función en vivo: si el bundle no compila, sigue
> corriendo la versión previa. **No hay migraciones, ni cambios de env/secrets, ni advisors que revisar.**

**Qué se despliega.** Una sola función (`pdf`): se bundlean juntos todos los archivos de
`supabase/functions/pdf/` (`index.ts`, `base.ts`, `templates.ts`, `reportes.ts`). No hay que listar
archivos: `deploy pdf` toma la carpeta entera.

**Frontend (aparte, automático).** Las 6 entradas nuevas de `pdfUrl` + las vistas nuevas viajan en el
build del frontend, que **Vercel despliega solo al hacer push** a `main` (proyecto `crm-marblock`). No
requiere acción manual más allá del commit/push. El deploy manual de abajo es **sólo** para la Edge
Function.

**Opción A — Supabase CLI** (desde la raíz del repo):

```bash
# requiere estar logueado (supabase login) y el ref del proyecto de .mcp.json
supabase functions deploy pdf --project-ref kkdbvzixwlyeahgianuc
```

**Opción B — MCP** (en sesión con Claude Code): herramienta `deploy_edge_function`, project
`kkdbvzixwlyeahgianuc`, function slug `pdf`, incluyendo los 4 archivos de la carpeta.

**Pre-check opcional** (si hay Deno instalado): `deno check supabase/functions/pdf/index.ts`. Sin Deno,
alcanza con confiar en el bundle del deploy (falla-seguro, ver arriba).

**Post-deploy:** correr el browser smoke de §6 (los pasos 2–4 —PDFs de movimiento, cheques e informes—
recién funcionan con la función desplegada). Rollback = redeploy de la versión anterior de la carpeta.

## 6. Cómo validar (browser smoke)

> Los pasos **1 y 5** ya funcionan con el código actual (sólo frontend). Los pasos **2, 3 y 4**
> (cualquier "📄 PDF") requieren la Edge Function desplegada — hacer **§5.1** antes.

1. Consultas → Cuenta: elegir un banco → la cabecera muestra saldo actual; pestaña Movimientos muestra
   el subdiario con saldo corrido; pestañas de cheques/transferencias/comprobantes cargan filtradas a
   esa cuenta.
2. En un movimiento, "📄 PDF" abre el `PDFModal` con el comprobante en iframe (JWT en el header, no en
   la URL).
3. Imprimir un cheque propio y uno de tercero → PDFs correctos.
4. Imprimir los 3 informes (saldos, subdiario, mayor) desde `Informes/`.
5. Hacer una transferencia banco→caja → aparecen ambas patas; el saldo de ambas cuentas cambió; se
   puede imprimir.
6. `npm run build` OK (ya verificado). Único paso de aplicación pendiente: **deploy de la Edge Function
   `pdf`** (§5.1). No hay migraciones que aplicar ni advisors que revisar en esta fase.

## 7. Backlog / preguntas abiertas

- **Impresión legal del cheque cartular**: `generarCheque` es un comprobante **interno** de respaldo,
  no el llenado del cheque físico/bancario (formato/posiciones bancarias, implicancias legales). Si se
  necesita imprimir sobre chequera pre-impresa, es un diseño aparte a confirmar.
- **"Cupones"** (`system_plan.md §6/§7`): sin modelo — la pestaña queda fuera hasta definir alcance.
- **Pestaña "Contabilidad"** de la ficha de cuenta: placeholder hasta Fase E
  (`system_plan_fase_e_contabilidad.md`).
- **Filtro server-side de cheques por cuenta**: si se prefiere sobre el filtro cliente-side, se agrega
  `p_cuenta_id` a `informe_cheques_tesoreria` en la migración de lecturas de C.
