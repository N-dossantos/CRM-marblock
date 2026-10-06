# Plan de migración Tango → Supabase desde `MARBLOCK_SA.bak`

> **Para agentes:** SUB-SKILL REQUERIDA: usar `superpowers:subagent-driven-development` (recomendado) o
> `superpowers:executing-plans` para ejecutar este plan tarea por tarea. Los pasos usan checkboxes (`- [ ]`).
>
> **Regla de este repo:** antes de escribir en el repo o en Supabase, se presentan los cambios y se
> espera la confirmación de Nico. Este documento no aplicó ningún cambio: sólo leyó el `.bak`.

**Objetivo:** llevar a Supabase los datos de Tango (Ventas, Compras, Tesorería y Contabilidad) usando como
**única fuente un backup `.bak`** sacado de la máquina vieja, sin ejecutar nada en ella.

**Arquitectura:** el `.bak` se lee directamente en esta Mac con un lector propio en Python: no hace falta
SQL Server, ni Docker, ni red. El lector vuelca las 57 tablas a los mismos CSV `|~|` que ya valida
`02_verificar_export.py`. Sobre esos CSV, un ETL en Python arma un `.sql` por módulo y `psql` lo carga en
una sola transacción con FKs y triggers diferidos (la mecánica de `PLAN_MAESTRO.md` §3.2.5). Todo el
pipeline se vuelve a correr en segundos, así que el cutover real se hace con un **`.bak` nuevo**, tomado
en el momento de congelar Tango.

**Stack:** Python 3.9 de macOS (sólo biblioteca estándar, tests con `unittest`) · `psql`
(`/opt/homebrew/bin/psql`) · Supabase Postgres, proyecto `kkdbvzixwlyeahgianuc`.

**Spec:** `PLAN_MAESTRO.md` §3.2 (cutover de Tango) · `supabase/tango/tablas.tsv` (57 tablas → destino) ·
`supabase/tango/esquema_tango.tsv` (las 1.415 columnas) · §1 de este documento (verificación del `.bak`).

## Global Constraints

- **En la máquina vieja no se ejecuta nada.** La única entrada es un `.bak` completo generado desde la GUI
  (Tango → *Copias de seguridad*, o SSMS → *Tasks → Back Up…*) y copiado en un pendrive.
- **Sin Docker y sin SQL Server local** (regla de `CLAUDE.md`). Extracción y ETL usan Python 3.9 **sólo
  con la biblioteca estándar** (no se instala nada con `pip`). La carga usa `psql`.
- **El lector sólo acepta SQL Server 2005 (versión de base 611).** Si un `.bak` futuro trae otra versión,
  tiene que cortar con `BakError`, nunca leer a medias.
- **Nada de datos a git:** `*.bak` ya está ignorado (`.gitignore:56`); `supabase/tango/.gitignore` ignora
  `csv/` y `*.csv`; los `.sql` generados van a `supabase/tango/sql/`, que hay que agregar a ese `.gitignore`.
- **La contraseña de la base nunca pasa por el chat:** el URI va en un archivo ignorado por git y se exporta
  como `SUPABASE_DB_URL`.
- **Los comprobantes históricos entran por `INSERT` directo, no por las RPC.** Conservan número, fecha,
  importes y estado de Tango; `contadores` se setea al final (`PLAN_MAESTRO.md` §3.2.4).
- **RLS:** no se agrega `FORCE ROW LEVEL SECURITY` y no se expone nada nuevo a `anon`.
- **Fechas centinela:** Tango guarda "sin fecha" como `1800-01-01` → se carga `NULL`.
- **Codificación:** los `varchar` de Tango son cp1252; los CSV se escriben en UTF-8.

## Review Focus

1. **Un `.bak` nuevo cuyo esquema cambió** (por ejemplo, si una actualización de Tango agregó columnas):
   la exportación tiene que fallar y decir en qué tabla, no exportar columnas corridas. Lo cubre
   `test_las_57_tablas_coinciden_con_esquema_y_con_rcrows` (Tarea 1).
2. **Un campo de texto que contiene `|~|` o `@#@`:** el export aborta y muestra el valor, en vez de generar
   un CSV con registros partidos. Lo cubre `test_aborta_si_un_campo_trae_separador_o_terminador` (Tarea 2).
3. **Páginas liberadas que todavía tienen filas viejas** (registros borrados en Tango): no pueden
   reaparecer. Lo cubre la igualdad entre filas decodificadas y `rcrows` (Tarea 1).
4. **Fechas `1800-01-01` y fechas absurdas** (por ejemplo, 2 cheques con vencimiento posterior a 2027): se
   cargan como `NULL` o quedan en el reporte de anomalías, nunca como fechas reales. Es un test obligatorio
   de la Tarea 4.
5. **Correr la carga dos veces** tiene que dar el mismo resultado, sin duplicados. Para eso se hace
   `TRUNCATE … RESTART IDENTITY` dentro de la misma transacción. Se verifica en la Tarea 10 cargando dos
   veces.
6. **Percepciones mezcladas con el IVA** (H13): en Compras, los slots `COD_IVA1..5` de `CPA04` traen IVA y
   percepción de IVA juntos. Un slot con código 3 / 4 que termine en `factura_compra_iva_detalle` infla el
   crédito fiscal sin que nada falle. Lo cubren el diccionario `CPA14`, que aborta ante un código
   desconocido, y el control `IMPORTE_TO = neto + IVA + internos + percepciones` de la Tarea 7.

---

## 1. Veredicto: ¿el `.bak` trae lo que hace falta? — **Sí**

Leí el archivo completo en esta Mac, sin restaurarlo y sin modificar nada del repo. **Contiene las 57
tablas del alcance, con el esquema idéntico al relevado el 21/08 y datos al 25/09/2026.** Es suficiente
para todo el ETL de los cuatro módulos.

| Campo | Valor |
|---|---|
| Archivo | `MARBLOCK_SA.bak`, 512 MB, en la raíz del repo (ignorado por `.gitignore:56 *.bak`) |
| Formato | Microsoft Tape Format (MTF), backup **completo** (*full*) de SQL Server, sin compresión ni cifrado |
| Servidor / base | `COLOSO\SQLEXPRESS_AXOFT` / `MARBLOCK_SA` (archivos lógicos `9_50_000_TangoDefGVAR`) |
| Motor | **SQL Server 2005** Express: versión de base 611. Se creó en SQL 2000 (539) y después se migró |
| Fecha del backup | **2026-09-25 09:00:16** |
| Último dato | Ventas hasta el 24/09; Compras y Tesorería hasta la mañana del 25/09 |
| Contenido útil | Stream `MQDA` = imagen completa del `.mdf`: 62.528 páginas de 8 KB |
| sha256 | `908e954d46f5249159840989ac16aa15dad1de573e433f8277df21e1a8092f42` |

**Cómo lo verifiqué** (todo reproducible con el código de las Tareas 1 y 2):

1. **Catálogo:** 1.906 tablas de usuario (el 21/08 eran 1.907), 306 con filas (igual que el 21/08) y
   329.640 filas en total (328.393 el 21/08).
2. **Esquema:** las 57 tablas de `tablas.txt` existen con **exactamente** las mismas columnas (nombre,
   orden y tipo) que `esquema_tango.tsv`.
3. **Completitud:** en las 57 tablas, las filas decodificadas coinciden con el contador interno del motor
   (`sysrowsets.rcrows`, que es lo que devuelve `sys.partitions.rows`).
4. **Importes:** los 17.460 asientos contables (4.351 de Ventas, 6.270 de Compras y 6.839 de Tesorería)
   cuadran Debe = Haber al centavo.
5. **Sin topes ni recortes:** `CPA04` y `MOVIMIENTO_CHEQUE_TERCERO` tienen exactamente 10.000 filas cada
   una, pero es una coincidencia: los IDs llegan a 10.040 y 10.021 con huecos, las dos tablas crecieron
   desde el 21/08 y hay carga hasta el 25/09.
6. **Texto:** los acentos y la ñ salen bien (cp1252), por ejemplo "Molino Cañuelas S.A.C.I.F.I.A." y
   "Asociación de los Testigos de Jehova".
7. **Export:** `03_exportar_bak.py` genera 57 CSV (58 MB) en 8 segundos, y `02_verificar_export.py`, sin
   ningún cambio, devuelve `[OK] Export integro: columnas y conteos coinciden con el origen`.

**Volumen por módulo** (el detalle por tabla está en el Apéndice A):

| Módulo | Tablas | Filas 21/08 | Filas `.bak` 25/09 | Δ |
|---|---:|---:|---:|---:|
| Ventas | 21 | 88.662 | 89.142 | +480 |
| Compras | 13 | 41.142 | 41.287 | +145 |
| Tesorería | 9 | 48.568 | 48.779 | +211 |
| Contabilidad | 14 | 71.144 | 71.470 | +326 |
| **Total** | **57** | **249.516** | **250.678** | **+1.162** |

Ninguna tabla tiene menos filas que el 21/08, y el crecimiento corresponde a unas cinco semanas de
operación (por ejemplo, `GVA12` sumó 52 comprobantes y `STA14` 41 remitos).

---

## 2. Qué cambia respecto del plan anterior

**Se desbloquea la extracción.** Los pasos 1 a 4 de `PLAN_MAESTRO.md` §3.2.3 y toda la §3.2.7 (conseguir la
credencial de SQL Server) **dejan de ser necesarios**: no hace falta contraseña, red ni SSMS.

**La "Vía 2" del `supabase/tango/README.md` no habría funcionado, ni siquiera con Docker permitido:** SQL
Server 2016 o posterior (y Azure SQL Edge, que es el contenedor que proponía) **no restaura backups de
2005**. Habría hecho falta un SQL Server 2008–2014 intermedio. Esa vía se reemplaza por la lectura
directa del `.bak` (Tarea 2). La extracción por LAN tampoco sigue: `01_export_remoto.py` (pymssql),
`01_backup_helper.sql` y `01_conteo_filas.sql` se borraron el 2026-10-06 (nunca estuvieron en git), y
`supabase/tango/README.md` ya quedó reescrito con el `.bak` directo como única vía.

**Hallazgos del `.bak` que corrigen supuestos del plan anterior:**

| # | Hallazgo | Qué corrige | Dónde se resuelve |
|---|---|---|---|
| H1 | **Tango no guarda CAE desde 2017.** `GVA12.CAICAE` está vacío en todas las facturas de 2017–2026; sólo 71 de 2016 tienen valor (probablemente CAI). `DOC_ELECTR = 0` en las 9 series de talonarios y en todas las facturas. La facturación electrónica se hace por fuera de Tango. | `PLAN_MAESTRO.md` §3.2.1 dice "las facturas históricas ya vienen con CAE", y el mapeo `facturas.cae ← CAICAE` de la memoria del proyecto | D4 |
| H2 | **`GVA43.PROXIMO` no es un número:** es un valor ofuscado de 16 caracteres hexadecimales (por ejemplo `7407437B537D0567`). | El mapeo `contadores ← PROXIMO − 1` de `tablas.tsv` | D5: se toma el último número emitido por fecha |
| H3 | **El contador de remitos de Supabase quedó atrasado.** Según `PLAN_MAESTRO.md` §3.2.5 se cargó en `00001-00010324`, y Tango ya emitió hasta `R0001-00010366` (23/09). (No pude confirmarlo en vivo porque Supabase no respondió.) | La nota de `PLAN_MAESTRO.md` §3.2.5 paso 3 | D5 |
| H4 | En recibos (`REC 0001`), el máximo número es `00041189` (03/03/2026, un error de carga), mientras que la serie real va por `00004288` (24/09). | Calcular contadores con `MAX(N_COMP)` | D5: último número **por fecha**, no el máximo |
| H5 | **Imputaciones parciales:** 913 de 3.674 recibos cancelan más de una factura, y 615 facturas se cobraron con más de un recibo. `recibo_facturas` no tiene columna de importe y `recalcular_estado_factura` le acredita **el recibo entero a cada factura imputada**. | El supuesto de que alcanza con vincular recibo ↔ factura. Además, es un bug que la app ya tiene hoy con los recibos de varias facturas | D1 |
| H6 | De 375 NC/ND, **30 no están imputadas a ninguna factura** (23 "a cuenta" y 7 anuladas) y **44 están imputadas a más de una**. `notas.factura_id` es `NOT NULL` y apunta a una sola factura. | "Cada NC/ND resuelve a una factura" | D2 |
| H7 | `clientes.descuento_porcentaje` sólo admite 0, 10, 15 o 20, pero en Tango hay 12 clientes con 5, 7 o 18 %. | El `CHECK` del schema `0001` | D3 |
| H8 | Calidad de datos: hay 60.553 celdas con `1800-01-01` sólo en `GVA12`, y 2 cheques con vencimiento posterior a 2027 (uno en 2031). | Que todas las fechas sean válidas | Tarea 4 |
| H9 | Las columnas `text` de observaciones (`GVA12.OBSERVAC`, `SBA04.OBSERVACIONES`) están **vacías** en todas las filas. | El temor a perder observaciones multilínea | No requiere acción |
| H10 | Todos los renglones de asientos tienen importe positivo con `D_H` = D o H, y los asientos cuadran. | — | Entran directo a `asiento_items` (`debe` o `haber`, nunca los dos) |
| H11 | **`GVA42` no son percepciones: es el desglose de IVA por alícuota** de cada comprobante de venta. Sus 4.874 filas usan sólo `COD_ALICUO` 1 (21 %) y 2 (10,5 %), `PERCEP = 0` en todas, y Σ `IMPORTE` = `GVA12.IMPORTE_IV` en el 100 % de los comprobantes. `GVA88` (61) es lo mismo. **Tango no tiene percepciones de venta:** en las 4.971 FAC/NC/ND, `IMPORTE = IMPORTE_GR + IMPORTE_IV + IMPORTE_EX`. | El mapeo `percepciones ← GVA42` del relevamiento del 21/08 (y la migración `20260821140000_ventas_percepciones`, que queda inerte, en 0) | Tarea 6 |
| H12 | **Ventas exentas:** 64 comprobantes con `IMPORTE_EX ≠ 0` (61 ND A, la última del 26/02/2026; 28 todo exento). En el CRM el exento es un ítem con alícuota `Exento (0%)` y `neto_gravado` suma **todos** los ítems, exentos incluidos. | Que `neto_gravado = IMPORTE_GR` alcance | Tarea 6 |
| H13 | **Percepciones de compras (sufridas), activas hoy:** ① en los slots `COD_IVA1..5` de `CPA04` van mezcladas con el IVA. Según `CPA14`, el código 3 es *"PERCEPCION DE IVA"* 3 % (1.263 comprobantes, hasta el 19/09/2026; $4,3 M en 2024, $5,3 M en 2025 y $5,0 M en 2026, sobre todo de Loma Negra) y el 4 es *"PERCEPCION 10 %"* (9). ② **`CPA18` no son retenciones**: sus 703 filas cuelgan de facturas/NC/ND de proveedor (`FP`/`CP`/`DP`), nunca de una O/P, con códigos de `CPA14`: 51 *"PERCEPCION I.B."* (Bs. As.), 54 *"PERCEPCION IB CAP"*, 40 impuestos internos, 53 ganancias (2011 → 2022, más 1 del 31/12/2025). Con `CPA18`, `IMPORTE_TO = NE + ΣIVA + EX + IN + ΣCPA18` cierra en 637 comprobantes; quedan 19 sin explicar. **El CRM no tiene dónde guardarlas:** `facturas_compra.total = neto + IVA`, `factura_compra_iva_detalle` sólo admite 0 / 10,5 / 21 / 27 % y `retenciones` exige un `pago_proveedor_id`. | Los mapeos `factura_compra_iva_detalle ← COD_IVA1..5` y `retenciones ← CPA18` | D9, Tarea 7 |
| H14 | **`GVA63` y `CPA63` son la clasificación SIAP/CITI de cada comprobante** (`CLASIF_SIA` / `CLAS_SIAP` = V1, V2, C1, C3, SIN), no la alícuota de los ítems ni la configuración de retenciones del proveedor. La alícuota de cada renglón de venta sale de `GVA53.PORC_IVA`. | Los mapeos `alicuota_iva_id ← GVA63` y `proveedor_alicuotas ← CPA63` | Tareas 6 y 7: no se cargan |
| H15 | **Marblock no practica retenciones:** `CPA29` (retenciones hechas al pagar) tiene 4 filas de 2011, todas por $0, y no está entre las 57. | Que `retenciones` tenga historia que cargar | Tarea 7: queda vacía |

**Hallazgos del ETL (Tareas 5–9, 2026-10-06).** Los H1–H15 salieron de leer el `.bak`; estos
aparecieron recién al armar los `.sql` y chocar contra el schema del destino:

| # | Hallazgo | Qué corrige | Dónde se resuelve |
|---|---|---|---|
| H16 | **NC A y NC B comparten numerador.** `contadores.tipo` es PK y `crear_nota` elegía `nota_credito` / `nota_debito` sin mirar la letra, así que una NC B tomaba el número que seguía de la serie A. Son series fiscales independientes: en Tango la N/C A 0002 va por 165 y la N/C B 0002 por 1. | Que un contador por tipo de nota alcance | `20261006140002`: cuatro contadores (`nota_credito`, `nota_credito_b`, `nota_debito`, `nota_debito_b`) y `crear_nota` elige por letra |
| H17 | **La numeración se repite entre letras.** En el punto de venta 00002 Tango numera Factura A y Factura B por separado: hay **62 pares** con el mismo `00002-NNNNNNNN`, y una NC A y una NC B comparten `00002-00000001`. `facturas.numero` era UNIQUE global y `notas` era UNIQUE `(tipo, numero)`. | Que `numero` identifique un comprobante por sí solo | `20261006130000`: UNIQUE `(tipo, numero)` en `facturas` y `(tipo, tipo_letra, numero)` en `notas` — mismo criterio que el fix `0008` |
| H18 | **3 ND de proveedor "a cuenta"** (`ESTADO` = CTA) no cuelgan de ninguna factura, igual que las 30 NC/ND de Ventas de H6. `notas_compra.factura_compra_id` era `NOT NULL`, y el `JOIN` de `notas_compra_list` era INNER, así que esas notas desaparecían de la lista. | Que toda nota de compra tenga factura (D2 sólo se había aplicado a Ventas) | `20261006130000` (nullable) + `20261006140001` (`LEFT JOIN` en `notas_compra_list`) |
| H19 | **Los renglones de las notas de compra están repartidos en dos tablas.** `CPA47` (conceptos de `CPA45`) y `CPA46` (artículos de stock) cuelgan del comprobante por `(TCOMP_IN_C, NCOMP_IN_C)`, y el **tipo** es lo que desempata: el mismo `NCOMP_IN_C` puede estar en una `FP` y en una `CP`. Son **531 renglones** de nota: 368 CP + 20 DP de `CPA47` y 143 DP de `CPA46`. Los ids de las dos tablas colisionan entre sí, así que se renumeran. | Que `nota_compra_items` salga de una sola tabla de origen | `etl/compras.py` (`items()`), con test de reparto y de renumeración |
| H20 | **Las órdenes de pago no tienen punto de venta fiscal:** los 3.358 pagos de la historia de Tango van en el punto de venta **00000**, no en el 00002 que traía `seed.sql`. | El punto de venta sembrado para `pago_proveedor` | `supabase/tango/05_cargar.sh`: el UPSERT de `contadores` lo deja en `00000` |
| H21 | **La serie FAC A 00003 se queda sin contador.** Es el talonario *"Factura de Crédito Electrónica MiPyME"* (4 comprobantes, el último del 2023-05-24) y `contadores` tiene **un solo punto de venta por tipo**. Está inactiva desde 2023, así que no se modela; si se vuelve a usar hay que agregarle una fila propia. | Que `contadores` cubra todas las series de Tango | Decisión registrada: no se carga (ver `05_cargar.sh`) |
| H22 | **Las notas sin factura quedaban sin cliente.** `notas` nunca tuvo `cliente_id`: se deducía con `JOIN` a `facturas`. Al volver `factura_id` nullable (D2), las **23 notas reales "a cuenta"** (18 clientes, $5,59 M netos) quedaban invisibles en `notas_list` y fuera del saldo de cuenta corriente — con lo cual la base **no podía reproducir `GVA14.SALDO_CC`**, que es el control de aceptación de la Tarea 10. | Que el cliente de una nota se pueda deducir siempre de su factura | `20261006140002`: `notas.cliente_id` con backfill, `crear_nota` la setea, y `notas_list` / `informe_cta_cte` leen con `COALESCE`; el ETL la carga de `GVA12.COD_CLIENT` |

---

## 3. Decisiones abiertas — bloquean el ETL (Fase 3), no la extracción (Fase 1)

| # | Tema | Opciones | Recomendación |
|---|---|---|---|
| **D1** | ✅ **decidida 2026-10-06: (a)** · Importe imputado por factura (H5) | **(a)** Agregar `importe` (nullable) a `recibo_facturas` y a `pago_proveedor_facturas`, cargarlo desde `GVA07.IMPORT_CAN` / `CPA05.IMPORT_CAN`, y que `recalcular_estado_factura` use `importe` cuando exista y caiga al cálculo actual cuando sea `NULL` (recibos creados por la app). **(b)** Cargar sin importe y conservar el estado de Tango, aceptando que un recálculo posterior lo rompa. | **(a)**: es la única forma de que la cuenta corriente histórica cierre. No cambia el comportamiento de la app. |
| **D2** | ✅ **decidida 2026-10-06: (a)** · NC/ND sin factura o con varias (H6) | **(a)** `factura_id` = la factura con mayor `IMPORT_CAN` en `GVA07`, y `factura_id` pasa a admitir `NULL` sólo para las 30 notas sin imputar. **(b)** Igual que (a), pero sin migrar las 30 notas sin imputar (sus saldos se pierden). | **(a)**. Las 7 anuladas pueden igual entrar con `NULL`. |
| **D3** | ✅ **decidida 2026-10-06: (b)**, redondear al valor permitido más cercano (sin cambio de schema ni de UI) · Descuentos 5 / 7 / 18 % (H7) | **(a)** Cambiar el `CHECK` a `BETWEEN 0 AND 100` y agregar los valores al selector de `Clientes`. **(b)** Redondear al valor permitido más cercano. | **(a)**: los datos reales mandan. Son 12 clientes. |
| **D4** | ✅ **decidida 2026-10-06: (a)**, `cae = NULL` en todo lo histórico (se puede completar con (b) después del go-live) · CAE histórico (H1) | **(a)** Cargar `cae = NULL` para todo lo histórico. **(b)** Bajar de ARCA el CSV de *Mis Comprobantes* (emitidos) y cruzarlo por tipo + punto de venta + número para completar `cae` y `cae_vencimiento`. | **(b)** si se van a reimprimir facturas viejas desde el CRM; si no, **(a)**. Es independiente del resto y se puede hacer después del go-live. |
| **D5** | ⏳ **se confirma serie por serie el día del cutover** · Contadores al salir en vivo (H2–H4) | Último número **por fecha** de cada serie (ver tabla abajo), confirmado contra la fuente real: ARCA (`FECompUltimoAutorizado` o *Mis Comprobantes*) para facturas y notas, y el talonario físico para remitos. | Confirmar serie por serie el mismo día del cutover. |
| **D6** | ⏳ **pendiente: Nico abre en Tango un cheque de cada código** · Estados de cheques de terceros | `SBA14.ESTADO` tiene sólo tres códigos: `A` (4.976), `X` (21) y `C` (10). El destino usa `en_cartera / depositado / entregado / rechazado_banco`. El estado se deriva de `FECHA_SAL` / `TIPO_SAL` (salida), `FECHA_RECH` (rechazo) y el último `MOVIMIENTO_CHEQUE_TERCERO`. | Que Nico abra en Tango un cheque de cada código y confirme qué significa. |
| **D7** | ✅ **decidida 2026-10-06: (a)**, historia completa · Alcance de Tesorería y Contabilidad | **(a)** Historia completa: 7.150 movimientos y 17.460 asientos. **(b)** Sólo saldos de apertura a la fecha de corte. | **(a)**: es coherente con "historia completa" (decisión del 2026-07-28) y el volumen es chico. |
| **D8** | ⏳ **fecha por definir** (el principio queda fijo) · Fecha de corte | Congelar Tango, hacer un `.bak` nuevo, correr el pipeline y cargar, todo el mismo día. | Elegir un día de poco movimiento: el pipeline completo tarda minutos. |
| **D9** | Percepciones de compras (H13) — ✅ **decidida 2026-10-06: (a)**, ver `PLAN_MAESTRO.md` §3.9 | **(a)** Tabla nueva `percepciones_compra` (`factura_compra_id` XOR `nota_compra_id`, `tipo` = `iva` / `iibb` / `ganancias` / `imp_internos`, `jurisdiccion`, `base_imponible`, `alicuota`, `monto`) + `percepciones_monto` en `facturas_compra` y `notas_compra`, con `total = neto + IVA + percepciones`; `crear_/actualizar_factura_compra` y `crear_nota_compra` reciben `p_percepciones`; el formulario de compra las carga; el Libro IVA Compras suma columnas de percepción IVA e IIBB. **(b)** Meter la percepción de IVA como alícuota 3 % / 10 % en `factura_compra_iva_detalle`. **(c)** Cargar el `total` de Tango sin desglose. | **(a).** (b) mezcla crédito fiscal con pagos a cuenta y deja el Libro IVA mal; (c) rompe `total = neto + IVA` y el saldo con cada proveedor. **No es sólo un tema de la migración:** hoy no se puede cargar en el CRM una factura de Loma Negra con su total correcto. Es un desarrollo de Compras con sub-plan propio. La tabla `percepciones` de Ventas no se reutiliza: modela percepciones practicadas y tiene FK a `facturas` / `notas`. |

**Ya decididas, sólo hay que reconfirmarlas** (`supabase/tango/README.md`, "Decisiones clave"):
el catálogo de productos queda con los 25 sembrados, y `STA11` sólo aporta la descripción de los
renglones históricos; los ítems de compra salen de `CPA47` contra `materiales` sembrados desde `CPA45`;
Stock no tiene destino y por eso de `STA14` sólo entran los 6.835 `REM`.

**Último número emitido por serie (dato del `.bak` del 25/09; se recalcula con el `.bak` del cutover):**

| Serie Tango | `contadores.tipo` | Punto de venta | Último por fecha | Fecha | Comentario |
|---|---|---|---|---|---|
| FAC A 0002 | `factura_a` | 00002 | 2321 | 2026-09-23 | Serie activa, numeración continua (2.321 comprobantes del 1 al 2321) |
| FAC B 0002 | `factura_b` | 00002 | 63 | 2026-05-19 | 62 comprobantes, falta un número |
| N/C A 0002 | `nota_credito` | 00002 | 165 | 2026-05-04 | Continua |
| N/C B 0002 | `nota_credito_b` | 00002 | 1 | 2025-12-16 | Serie propia desde H16 |
| N/D A 0002 | `nota_debito` | 00002 | 41 | 2026-02-26 | Continua |
| N/D B 0002 | `nota_debito_b` | 00002 | 0 | — | Sin emitir; existe sólo para que la primera ND B arranque en 1 (H16) |
| REC 0001 | `recibo` | 00001 | 4288 | 2026-09-24 | **No usar el máximo (00041189, H4)** |
| REM R 0001 | `remito` | 00001 | 10366 | 2026-09-23 | Talonario preimpreso AGEE; **el contador de Supabase está en 10324 (H3)** |
| O/P (sin serie fiscal) | `pago_proveedor` | **00000** | 3358 | — | El punto de venta es 00000, no el 00002 del seed (H20) |
| — | `presupuesto` | 00002 | 0 | — | Tango no tiene presupuestos |
| — | `asiento` | — | *(lo setea el ETL)* | — | `sql/50_contabilidad.sql` lo deja en la cantidad de asientos cargados |
| FAC A 0003 | — | — | 4 | 2023-05-24 | Talonario "Factura de Crédito Electrónica MiPyME": **sin contador** (H21) |
| Series 0001 (FAC/NC/ND) | — | — | — | ≤ 2016 | Históricas, sin uso |

Los diez contadores los carga `supabase/tango/05_cargar.sh` con un `INSERT … ON CONFLICT (tipo) DO
UPDATE` dentro de la misma transacción que la carga — no es un `UPDATE` a mano, porque la mayoría de
las filas **no existen** en la base (§3.2.8 del plan maestro: hoy sólo están `asiento`,
`pago_proveedor` y `remito`). Los recalcula `python3 -m etl.contadores`.

---

## 4. Estructura de archivos

```
supabase/tango/
├── bak_reader.py          HECHO  (T1) lector del .bak: páginas, catálogo, filas
├── test_bak_reader.py     HECHO  (T1) tests unitarios + contra el .bak real
├── 03_exportar_bak.py     HECHO  (T2) .bak → csv/ en el formato de 02_verificar_export.py
├── test_exportar_bak.py   HECHO  (T2)
├── README.md              HECHO  (2026-10-06) reescrito con el ".bak directo" como única vía
├── .gitignore             HECHO  (T2) ignora csv/, sql/ y *.csv
├── etl/                   HECHO  (Fase 3) un módulo por dominio + comun.py, con sus tests
│   ├── comun.py           (T4) lectura de CSV, fechas centinela, COPY, reset de secuencias
│   ├── maestros.py ventas.py compras.py tesoreria.py contabilidad.py   (T5–T9)
│   ├── controles_*.py     (T6–T8) controles de aceptación contra los saldos de Tango
│   ├── contadores.py      (T10/T11) último número por serie, por fecha → el bloque de 05_cargar.sh
│   └── test_*.py          64 tests (`python3 -m unittest discover -s . -p 'test_*.py' -t .`)
├── sql/                   GENERADO, gitignoreado (Fase 3) un .sql de carga por módulo + _anomalias.txt
├── sql_conteos.sql        HECHO  (T10) conteo por tabla con el esperado del .bak al lado
├── sql_reset_secuencias.sql  HECHO (T10) setval de cada SERIAL (paso 2 de §3.2.5 del plan maestro)
└── 05_cargar.sh           HECHO  (T10) psql: una transacción, replica role, TRUNCATE + carga + contadores
supabase/migrations/       HECHAS (T3) 20261006120000 … 20261006150000 — escritas y **aplicadas**
supabase/POST_LOAD_VERIFY*.sql  MODIF. (T10) §1 dinámico, §3b/3c integridad, §5b totales de Compras
PLAN_MAESTRO.md            MODIF. (T3) §3.2: estado nuevo y referencia a este plan
```

Cada script hace una sola cosa: el lector no sabe nada de CSV; el exportador no sabe nada del destino; el
ETL lee **sólo** CSV, nunca el `.bak`. Así, cualquier cambio de mapeo se prueba sin volver a leer los
512 MB.

---

## 5. Tareas

### Fase 1 — Extracción (lista para ejecutar; no depende de ninguna decisión)

### Tarea 1: Lector del `.bak`

**Archivos:**
- Crear: `supabase/tango/bak_reader.py`
- Test: `supabase/tango/test_bak_reader.py`

**Interfaces:**
- Consume: el `.bak` (por defecto `MARBLOCK_SA.bak` en la raíz del repo, o la ruta de la variable
  `TANGO_BAK`), más `tablas.txt` y `esquema_tango.tsv`.
- Produce: `Bak(path)` con los atributos `.backup_date: datetime`, `.db_version: int` (611),
  `.db_create_version`, `.npages`, `.tables: dict[str, int]`, y los métodos
  `.columns(tabla) -> list[Column]`, `.rows(tabla) -> Iterator[list]` (un valor por columna, en orden de
  `colid`) y `.meta_rowcount(tabla) -> int`. También `decode_value()`, `fix_torn_bits()`,
  `parse_record()` y `BakError`. Tipos Python que devuelve: `int`, `Decimal`, `datetime`, `str` (cp1252)
  y `None`.

Particularidades del formato que el código resuelve. Cada una la descubrí al fallar la lectura; están
documentadas para que nadie las "simplifique":
- **Torn page detection:** en cada sector de 512 B, SQL Server pisa los 2 bits bajos del último byte y
  guarda los originales en `m_tornBits` (offset 60 del header). Si no se restauran, se rompen los offsets
  de los registros.
- **PFS:** el byte de asignación de la página *p* está en la PFS `(p // 8088) * 8088` (la primera PFS es
  la página 1) y su índice es `p − base`, **no** `p − 1`. Un error de uno acá hace que se pierdan páginas
  del catálogo.
- **Catálogo de 2005** (distinto del de 2008+): `sysschobjs` (34), `syscolpars` (41), `sysrowsets` (5),
  `sysallocunits` (7), `syshobtcolumns` (13) y `sysrowsetcolumns` (4). Para ubicar físicamente cada
  columna, `colid → hobtcolid` se resuelve **siempre** con `sysrowsetcolumns`: en tablas que Tango alteró,
  por ejemplo `SBA01`, los dos números difieren.
- **`money` es un `int64` little-endian / 10⁴.** Leído como dos mitades de 32 bits, 213 asientos daban
  descuadrados.
- **Páginas por posición:** la página N está en `base + N·8192`. Hay páginas viejas desalineadas dentro de
  los slots sin asignar, y no se usan.
- **Versión:** está en el offset 4 del registro de la página de arranque (1:9).

- [x] **Paso 1: Escribir los tests** (`supabase/tango/test_bak_reader.py`)

```python
"""
Tests de bak_reader.py.   Correr:  python3 -m unittest -v test_bak_reader
(desde supabase/tango/). Los de integracion usan el .bak real: TANGO_BAK=/ruta.bak
o, por defecto, MARBLOCK_SA.bak en la raiz del repo; si no esta, se saltean.
"""
import collections
import csv
import datetime
import decimal
import os
import struct
import unittest

from bak_reader import Bak, decode_value, fix_torn_bits, parse_record

AQUI = os.path.dirname(os.path.abspath(__file__))
BAK = os.environ.get("TANGO_BAK", os.path.join(AQUI, "..", "..", "MARBLOCK_SA.bak"))
SNAPSHOT_2026_09_25 = datetime.datetime(2026, 9, 25, 9, 0, 16)


class Decodificacion(unittest.TestCase):
    def test_money_es_int64_little_endian(self):
        self.assertEqual(decode_value(60, struct.pack("<q", -12345678)), decimal.Decimal("-1234.5678"))

    def test_decimal_signo_y_escala(self):
        raw = (123456789).to_bytes(12, "little")
        self.assertEqual(decode_value(106, b"\x01" + raw, 22, 7), decimal.Decimal("12.3456789"))
        self.assertEqual(decode_value(106, b"\x00" + raw, 22, 7), decimal.Decimal("-12.3456789"))

    def test_datetime_dias_y_ticks(self):
        self.assertEqual(decode_value(61, struct.pack("<ii", 300, 1)), datetime.datetime(1900, 1, 2, 0, 0, 1))

    def test_varchar_cp1252(self):
        self.assertEqual(decode_value(167, "Cañuelas".encode("cp1252")), "Cañuelas")

    def test_torn_bits_restaura_el_original_de_cada_sector(self):
        p = bytearray(8192)
        struct.pack_into("<H", p, 4, 0x0100)
        for s in range(1, 16):
            p[512 * (s + 1) - 1] = 0b10                      # patron de escritura en todos
        struct.pack_into("<I", p, 60, 0b10 | (0b01 << 6))   # original del sector 3 = 01
        fixed = fix_torn_bits(bytes(p))
        self.assertEqual(fixed[2047] & 3, 0b01)
        self.assertEqual(fixed[1023] & 3, 0)

    def test_parse_record_fijo_null_y_variable(self):
        rec = bytes([0x30, 0]) + struct.pack("<H", 8) + struct.pack("<i", 42)
        rec += struct.pack("<H", 2) + b"\x00" + struct.pack("<H", 1) + struct.pack("<H", 18) + b"abc"
        fx, ncol, nullbm, var = parse_record(rec, 0)
        self.assertEqual(struct.unpack_from("<i", fx, 4)[0], 42)
        self.assertEqual((ncol, nullbm, var), (2, b"\x00", [(b"abc", False)]))


@unittest.skipUnless(os.path.exists(BAK), "no esta el .bak")
class BackupReal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bak = Bak(BAK)
        with open(os.path.join(AQUI, "tablas.txt")) as f:
            cls.tablas = f.read().split()

    def test_es_sql_server_2005(self):
        self.assertEqual(self.bak.db_version, 611)

    def test_las_57_tablas_coinciden_con_esquema_y_con_rcrows(self):
        esq = collections.defaultdict(list)
        with open(os.path.join(AQUI, "esquema_tango.tsv")) as f:
            for r in csv.DictReader(f, delimiter="\t"):
                esq[r["tabla"]].append((int(r["ordinal"]), r["columna"]))
        for t in self.tablas:
            with self.subTest(tabla=t):
                self.assertEqual([c.name for c in self.bak.columns(t)], [n for _, n in sorted(esq[t])])
                self.assertEqual(sum(1 for _ in self.bak.rows(t)), self.bak.meta_rowcount(t))

    def test_asientos_cuadran_debe_igual_haber(self):
        for m in ("GV", "CP", "SB"):
            cols = [c.name for c in self.bak.columns("ASIENTO_" + m)]
            i_cab, i_dh = cols.index("ID_ASIENTO_COMPROBANTE_" + m), cols.index("D_H")
            i_imp = cols.index("IMPORTE_RENGLON_BASE_" + m)
            saldo = collections.defaultdict(decimal.Decimal)
            for r in self.bak.rows("ASIENTO_" + m):
                saldo[r[i_cab]] += r[i_imp] if r[i_dh] == "D" else -r[i_imp]
            with self.subTest(modulo=m):
                self.assertEqual([k for k, v in saldo.items() if abs(v) > decimal.Decimal("0.01")], [])

    def test_acentos_y_enie_en_razon_social(self):
        cols = [c.name for c in self.bak.columns("GVA14")]
        i = cols.index("RAZON_SOCI")
        self.assertTrue(any("ñ" in (r[i] or "") for r in self.bak.rows("GVA14")))

    def test_snapshot_2026_09_25(self):
        if self.bak.backup_date != SNAPSHOT_2026_09_25:
            self.skipTest("solo para el backup del 2026-09-25")
        self.assertEqual(self.bak.meta_rowcount("GVA12"), 8672)
        self.assertEqual(sum(self.bak.meta_rowcount(t) for t in self.tablas), 250678)


if __name__ == "__main__":
    unittest.main()
```

- [x] **Paso 2: Correrlos y ver que fallan**

Run: `cd supabase/tango && python3 -m unittest -v test_bak_reader`
Expected: `ModuleNotFoundError: No module named 'bak_reader'`

- [x] **Paso 3: Escribir el lector** (`supabase/tango/bak_reader.py`)

```python
"""
bak_reader.py - Lee un backup completo (.bak) de SQL Server 2005 sin SQL Server.

Tango (MARBLOCK_SA) corre sobre SQL Server 2005 Express (version de base 611). Un
SQL Server moderno (2016+) no restaura backups de 2005 y la regla del repo prohibe
Docker, asi que el .bak se lee directo: el stream MQDA del formato MTF es una imagen
completa del .mdf (pagina N en base + N*8192) y de ahi se decodifican el catalogo y
las filas. Solo stdlib de Python 3.9.

Particularidades del formato verificadas contra MARBLOCK_SA.bak (2026-09-25):
  - torn page detection: cada sector de 512 B tiene pisados los 2 bits bajos de su
    ultimo byte; los originales estan en m_tornBits (header, offset 60).
  - PFS: la pagina p tiene su byte en la PFS (p // 8088) * 8088 (la 1ra es la 1),
    en el offset 100 + (p - base). Bit 0x40 = asignada.
  - Catalogo 2005: sysschobjs (34), syscolpars (41), sysrowsets (5),
    sysallocunits (7), syshobtcolumns (13), sysrowsetcolumns (4). colid se mapea
    a la columna fisica por sysrowsetcolumns (difiere cuando Tango hizo ALTER).
  - money es int64 little-endian / 10^4 (no dos mitades).
"""
import collections
import datetime
import decimal
import mmap
import struct
import uuid

PAGE = 8192
PFS_INTERVAL = 8088
D1900 = datetime.datetime(1900, 1, 1)
LOB_TYPES = (34, 35, 99)            # image, text, ntext
FIXED_SIZE = {48: 1, 52: 2, 56: 4, 127: 8, 58: 4, 61: 8, 59: 4, 62: 8, 60: 8, 122: 4, 36: 16}


class BakError(Exception):
    pass


Column = collections.namedtuple(
    "Column", "name colid xtype maxlen prec scale offset bitpos nullbit")


def fix_torn_bits(raw):
    """Restaura los 2 bits originales del ultimo byte de los sectores 1..15."""
    if not struct.unpack_from("<H", raw, 4)[0] & 0x0100:
        return bytes(raw)
    p = bytearray(raw)
    torn = struct.unpack_from("<I", p, 60)[0]
    for s in range(1, 16):
        i = 512 * (s + 1) - 1
        p[i] = (p[i] & 0xFC) | ((torn >> (2 * s)) & 3)
    return bytes(p)


def decode_value(xtype, b, prec=0, scale=0):
    if xtype == 56: return struct.unpack("<i", b)[0]
    if xtype == 52: return struct.unpack("<h", b)[0]
    if xtype == 48: return b[0]
    if xtype == 127: return struct.unpack("<q", b)[0]
    if xtype == 61:
        ticks, days = struct.unpack("<ii", b)
        return D1900 + datetime.timedelta(days=days, milliseconds=round(ticks * 10 / 3))
    if xtype == 58:
        minutes, days = struct.unpack("<HH", b)
        return D1900 + datetime.timedelta(days=days, minutes=minutes)
    if xtype in (106, 108):
        v = int.from_bytes(b[1:], "little")
        return decimal.Decimal(v if b[0] == 1 else -v).scaleb(-scale)
    if xtype == 60: return decimal.Decimal(struct.unpack("<q", b)[0]).scaleb(-4)
    if xtype == 122: return decimal.Decimal(struct.unpack("<i", b)[0]).scaleb(-4)
    if xtype == 62: return struct.unpack("<d", b)[0]
    if xtype == 59: return struct.unpack("<f", b)[0]
    if xtype in (175, 167, 35): return bytes(b).decode("cp1252")
    if xtype in (239, 231, 99): return bytes(b).decode("utf-16le")
    if xtype == 36: return str(uuid.UUID(bytes_le=bytes(b)))
    return bytes(b).hex()                                    # binary/varbinary/image/timestamp


def mtf_date(b):
    v = int.from_bytes(b, "big")
    sec, v = v & 63, v >> 6
    mi, v = v & 63, v >> 6
    h, v = v & 31, v >> 5
    d, v = v & 31, v >> 5
    mo, y = v & 15, v >> 4
    return datetime.datetime(y, mo, d, h, mi, sec)


def parse_record(p, o):
    """-> (fixed_bytes, ncols, null_bitmap, [(var_bytes, is_complex)])"""
    sa = p[o]
    fixed_end = struct.unpack_from("<H", p, o + 2)[0]
    pos = o + fixed_end
    ncol = struct.unpack_from("<H", p, pos)[0]
    pos += 2
    nb = (ncol + 7) // 8 if sa & 0x10 else 0
    nullbm = p[pos:pos + nb]
    pos += nb
    var = []
    if sa & 0x20:
        nv = struct.unpack_from("<H", p, pos)[0]
        pos += 2
        start = pos + 2 * nv
        for i in range(nv):
            end = struct.unpack_from("<H", p, pos + 2 * i)[0]
            var.append((p[start:o + (end & 0x7FFF)], bool(end & 0x8000)))
            start = o + (end & 0x7FFF)
    return p[o:o + fixed_end], ncol, nullbm, var


class Bak:
    def __init__(self, path):
        self._f = open(path, "rb")
        self.m = mmap.mmap(self._f.fileno(), 0, access=mmap.ACCESS_READ)
        if self.m[:4] != b"TAPE":
            raise BakError("no es un backup MTF de SQL Server")
        sset = self.m.find(b"SSET")
        self.backup_date = mtf_date(self.m[sset + 88:sset + 93])
        self.base, self.npages = self._locate_data()
        self._cache = {}
        boot = self._record(9, 0)                               # pagina de arranque (1:9)
        self.db_version, self.db_create_version = struct.unpack_from("<HH", boot, 4)
        if self.db_version != 611:
            raise BakError("version de base %d: este lector es solo para SQL Server 2005 (611)"
                           % self.db_version)
        self._index_pages()
        self._load_catalog()

    # ---- paginas -------------------------------------------------------
    def _locate_data(self):
        h = self.m.find(b"MQDA")
        if h < 0:
            raise BakError("no hay stream MQDA")
        length = struct.unpack_from("<Q", self.m, h + 8)[0]
        start = h + 22
        for base in range(start, start + 512):              # pagina 0 = file header (tipo 15)
            pg = self.m[base:base + 96]
            if pg[0] == 1 and pg[1] == 15 and struct.unpack_from("<IH", pg, 32) == (0, 1):
                return base, (length - (base - start)) // PAGE
        raise BakError("no se encontro la pagina 0 del .mdf dentro de MQDA")

    def page(self, pid):
        if pid in self._cache:
            return self._cache[pid]
        if not 0 <= pid < self.npages:
            return None
        off = self.base + pid * PAGE
        raw = self.m[off:off + PAGE]
        if raw[0] != 1 or struct.unpack_from("<IH", raw, 32) != (pid, 1):
            return None                                     # slot no formateado / basura vieja
        p = fix_torn_bits(raw)
        self._cache[pid] = p
        return p

    def allocated(self, pid):
        base = (pid // PFS_INTERVAL) * PFS_INTERVAL
        pfs = self.page(base or 1)
        return pfs is not None and bool(pfs[100 + pid - base] & 0x40)

    def _record(self, pid, slot):
        p = self.page(pid)
        o = struct.unpack_from("<H", p, PAGE - 2 - 2 * slot)[0]
        return p[o:]

    def _index_pages(self):
        self._by_owner = collections.defaultdict(list)       # (objid, indexid, tipo) -> [pid]
        for pid in range(self.npages):
            p = self.page(pid)
            if p is not None:
                key = (struct.unpack_from("<I", p, 24)[0], struct.unpack_from("<H", p, 6)[0], p[1])
                self._by_owner[key].append(pid)

    def _records(self, obj, idx):
        """Registros vivos (primarios y forwarded) de las paginas de datos asignadas."""
        for pid in self._by_owner.get((obj, idx, 1), []):
            if not self.allocated(pid):
                continue
            p = self.page(pid)
            for s in range(struct.unpack_from("<H", p, 22)[0]):
                o = struct.unpack_from("<H", p, PAGE - 2 - 2 * s)[0]
                if o and (p[o] >> 1) & 7 in (0, 1):            # 0 primario, 1 forwarded
                    yield p, o

    # ---- catalogo -------------------------------------------------------
    def _load_catalog(self):
        self.objects = {}
        for p, o in self._records(34, 1):                       # sysschobjs
            fx, _, _, var = parse_record(p, o)
            oid = struct.unpack_from("<i", fx, 4)[0]
            self.objects[oid] = (bytes(var[0][0]).decode("utf-16le"), fx[17:19].decode("latin1").strip())
        self.tables = {n: i for i, (n, t) in self.objects.items() if t == "U"}
        self._cols = collections.defaultdict(list)
        for p, o in self._records(41, 1):                       # syscolpars
            fx, _, _, var = parse_record(p, o)
            oid, number, colid = struct.unpack_from("<ihi", fx, 4)
            if number == 0:
                self._cols[oid].append((colid, bytes(var[0][0]).decode("utf-16le"), fx[14]))
        self._rowsets = {}
        for p, o in self._records(5, 0):                        # sysrowsets
            fx = parse_record(p, o)[0]
            rsid = struct.unpack_from("<q", fx, 4)[0]
            self._rowsets[rsid] = struct.unpack_from("<iiq", fx, 13)[0:2] + (struct.unpack_from("<q", fx, 31)[0],)
        self._allocunits = {}
        for p, o in self._records(7, 0):                        # sysallocunits
            fx = parse_record(p, o)[0]
            self._allocunits[struct.unpack_from("<q", fx, 4)[0]] = (fx[12], struct.unpack_from("<q", fx, 13)[0])
        self._hobtcols = collections.defaultdict(dict)
        for p, o in self._records(13, 0):                       # syshobtcolumns
            fx = parse_record(p, o)[0]
            hobt, hcid = struct.unpack_from("<qi", fx, 4)
            self._hobtcols[hobt][hcid] = (fx[22], struct.unpack_from("<H", fx, 23)[0], fx[25], fx[26],
                                          struct.unpack_from("<h", fx, 31)[0], fx[35],
                                          struct.unpack_from("<i", fx, 37)[0])
        self._rscols = collections.defaultdict(dict)
        for p, o in self._records(4, 0):                        # sysrowsetcolumns
            fx = parse_record(p, o)[0]
            rsid, rscolid, hcid = struct.unpack_from("<qii", fx, 4)
            self._rscols[rsid][rscolid] = hcid

    def _rowset(self, table):
        tid = self.tables[table]
        rs = [k for k, v in self._rowsets.items() if v[0] == tid and v[1] in (0, 1)]
        if len(rs) != 1:
            raise BakError("%s: se esperaba 1 heap/clustered, hay %d" % (table, len(rs)))
        return rs[0]

    def columns(self, table):
        rs = self._rowset(table)
        out = []
        for colid, name, xtype in sorted(self._cols[self.tables[table]]):
            h = self._hobtcols[rs].get(self._rscols[rs].get(colid, colid))
            if h is None or h[0] != xtype:
                raise BakError("%s.%s: columna fisica no encontrada o de otro tipo" % (table, name))
            out.append(Column(name, colid, *h))
        return out

    def meta_rowcount(self, table):
        """sysrowsets.rcrows: el conteo que mantiene el motor (= sys.partitions.rows)."""
        return self._rowsets[self._rowset(table)][2]

    # ---- filas ------------------------------------------------------------
    def _lob(self, ptr):
        pid, _fid, slot = struct.unpack_from("<IHH", ptr, 8)    # 8 B timestamp + RID
        return self._lob_fetch(pid, slot)

    def _lob_fetch(self, pid, slot):
        rec = self._record(pid, slot)
        length, = struct.unpack_from("<H", rec, 2)
        kind, = struct.unpack_from("<H", rec, 12)
        if kind == 0:                                           # SMALL_ROOT
            size, = struct.unpack_from("<H", rec, 14)
            return rec[20:20 + size]
        if kind == 3:                                           # DATA
            return rec[14:length]
        if kind in (2, 5):                                      # INTERNAL / LARGE_ROOT_YUKON
            _maxl, cur, _lvl = struct.unpack_from("<HHH", rec, 14)
            q, out = (20 if kind == 2 else 24), b""
            for _ in range(cur):
                cpid, _f, cslot = struct.unpack_from("<IHH", rec, q + 4)
                out += self._lob_fetch(cpid, cslot)
                q += 12
            return out
        raise BakError("LOB de tipo %d no soportado (pagina %d slot %d)" % (kind, pid, slot))

    def rows(self, table):
        cols = self.columns(table)
        rs = self._rowset(table)
        au = [k for k, (typ, owner) in self._allocunits.items() if owner == rs and typ == 1][0]
        obj, idx = (au >> 16) & 0xFFFFFFFF, au >> 48
        for p, o in self._records(obj, idx):
            fx, ncol, nullbm, var = parse_record(p, o)
            row = []
            for c in cols:
                nb = c.nullbit - 1
                if nb >= ncol or (nullbm and nullbm[nb // 8] >> (nb % 8) & 1):
                    row.append(None)
                elif c.offset > 0:
                    if c.xtype == 104:
                        row.append(fx[c.offset] >> c.bitpos & 1)
                    else:
                        size = FIXED_SIZE.get(c.xtype) or (
                            (5 if c.prec <= 9 else 9 if c.prec <= 19 else 13 if c.prec <= 28 else 17)
                            if c.xtype in (106, 108) else c.maxlen)
                        row.append(decode_value(c.xtype, fx[c.offset:c.offset + size], c.prec, c.scale))
                else:
                    i = -c.offset - 1
                    b = var[i][0] if i < len(var) else b""
                    if c.xtype in LOB_TYPES:
                        row.append(decode_value(c.xtype, self._lob(b)) if len(b) == 16 else None)
                    else:
                        row.append(decode_value(c.xtype, b, c.prec, c.scale))
            yield row
```

- [x] **Paso 4: Correr los tests y ver que pasan**

Run: `cd supabase/tango && python3 -m unittest -v test_bak_reader`
Expected: `Ran 11 tests … OK`, en unos 6 segundos. Con un `.bak` que no sea el del 2026-09-25,
`test_snapshot_2026_09_25` aparece como *skipped*, y eso es correcto.

- [x] **Paso 5: Commit** (después de que Nico lo confirme)

```bash
git add supabase/tango/bak_reader.py supabase/tango/test_bak_reader.py
git commit -m "feat(tango): lector directo del .bak de SQL Server 2005, sin SQL Server ni Docker"
```

### Tarea 2: Exportar a CSV y verificar

**Archivos:**
- Crear: `supabase/tango/03_exportar_bak.py`, `supabase/tango/test_exportar_bak.py`
- Modificar: `supabase/tango/.gitignore` (agregar `sql/`). `supabase/tango/README.md` ya se reescribió
  el 2026-10-06 con el `.bak` directo como única vía; en esta tarea sólo se revisa que coincida.

**Interfaces:**
- Consume: `Bak` de la Tarea 1 y `tablas.txt`.
- Produce: `supabase/tango/csv/<TABLA>.csv` (UTF-8, `|~|` y `@#@\n`), `csv/_filas_origen.csv` (sale de
  `rcrows` y es independiente del decodificador) y `csv/_manifiesto.txt` (sha256, fecha del backup y
  totales). Es exactamente lo que espera `02_verificar_export.py`, que **no se modifica**.

- [x] **Paso 1: Escribir el test** (`supabase/tango/test_exportar_bak.py`)

```python
"""
Tests de 03_exportar_bak.py.   Correr:  python3 -m unittest -v test_exportar_bak
"""
import datetime
import decimal
import importlib.util
import os
import unittest

AQUI = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("exportar", os.path.join(AQUI, "03_exportar_bak.py"))
exportar = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(exportar)


class Canonico(unittest.TestCase):
    def test_null_vacio_fecha_iso_y_decimal_sin_exponente(self):
        self.assertEqual(exportar.canon(None), "")
        self.assertEqual(exportar.canon(datetime.datetime(2026, 9, 24, 13, 5, 7, 123000)), "2026-09-24 13:05:07.123")
        self.assertEqual(exportar.canon(decimal.Decimal("0E-7")), "0.0000000")
        self.assertEqual(exportar.canon(1), "1")

    def test_aborta_si_un_campo_trae_separador_o_terminador(self):
        with self.assertRaises(ValueError):
            exportar.canon("RAZON |~| SOCIAL")
        with self.assertRaises(ValueError):
            exportar.canon("linea@#@")


if __name__ == "__main__":
    unittest.main()
```

- [x] **Paso 2: Correrlo y ver que falla**

Run: `cd supabase/tango && python3 -m unittest -v test_exportar_bak`
Expected: `FileNotFoundError` (todavía no existe `03_exportar_bak.py`)

- [x] **Paso 3: Escribir el exportador** (`supabase/tango/03_exportar_bak.py`)

```python
#!/usr/bin/env python3
"""
03_exportar_bak.py - Exporta las tablas de tablas.txt desde el .bak de Tango a CSV.

Es la unica via de extraccion (no hay red ni SQL Server): lee el .bak con
bak_reader.py y deja en la carpeta de salida el mismo formato que espera
02_verificar_export.py (separador |~|, terminador @#@\\n, UTF-8, NULL = vacio,
bit 0/1, fechas ISO con milisegundos, decimales con punto).

_filas_origen.csv sale de sysrowsets.rcrows (el conteo que mantiene el motor), que
es independiente del decodificador de filas: si ambos coinciden, la lectura esta completa.

Uso:  python3 03_exportar_bak.py RUTA.bak [carpeta_salida]   (por defecto ./csv)
"""
import datetime
import decimal
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bak_reader import Bak  # noqa: E402

FS, RS = "|~|", "@#@\n"
AQUI = os.path.dirname(os.path.abspath(__file__))


def canon(v):
    if v is None:
        return ""
    if isinstance(v, datetime.datetime):
        return v.strftime("%Y-%m-%d %H:%M:%S.") + "%03d" % (v.microsecond // 1000)
    if isinstance(v, decimal.Decimal):
        return format(v, "f")
    s = str(v)
    if FS in s or "@#@" in s:
        raise ValueError("el valor contiene el separador o el terminador: %r" % s[:80])
    return s


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    bak_path = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(AQUI, "csv")
    os.makedirs(out, exist_ok=True)
    tablas = open(os.path.join(AQUI, "tablas.txt")).read().split()

    bak = Bak(bak_path)
    origen, total = [], 0
    for t in tablas:
        n = 0
        with open(os.path.join(out, t + ".csv"), "w", encoding="utf-8", newline="") as f:
            for row in bak.rows(t):
                f.write(FS.join(canon(v) for v in row) + RS)
                n += 1
        meta = bak.meta_rowcount(t)
        origen.append((t, meta))
        total += n
        print("%-28s %8d filas%s" % (t, n, "" if n == meta else "   <-- rcrows=%d" % meta))

    with open(os.path.join(out, "_filas_origen.csv"), "w", encoding="utf-8", newline="") as f:
        for t, meta in origen:
            f.write("%s%s%d%s" % (t, FS, meta, RS))
        f.write("_FIN_%s0%s" % (FS, RS))
    with open(os.path.join(out, "_manifiesto.txt"), "w", encoding="utf-8") as f:
        f.write("archivo=%s\nsha256=%s\nfecha_backup=%s\nversion_base=%d\npaginas=%d\n"
                "tablas=%d\nfilas=%d\nexportado=%s\n" % (
                    os.path.basename(bak_path), sha256(bak_path), bak.backup_date.isoformat(),
                    bak.db_version, bak.npages, len(tablas), total,
                    datetime.datetime.now().isoformat(timespec="seconds")))
    print("\n%d tablas, %d filas -> %s  (backup del %s)" % (len(tablas), total, out, bak.backup_date))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [x] **Paso 4: Correr los tests y el pipeline completo**

```bash
cd supabase/tango
python3 -m unittest test_bak_reader test_exportar_bak     # Ran 13 tests … OK
python3 03_exportar_bak.py ../../MARBLOCK_SA.bak           # 57 tablas, 250678 filas -> csv
python3 02_verificar_export.py                             # [OK] Export integro …
```

Expected (con el `.bak` del 25/09): `57 tablas, 250678 filas`, ninguna tabla marcada `<-- rcrows=`, y
la última línea del verificador es `[OK] Export integro: columnas y conteos coinciden con el origen.`

- [x] **Paso 5: Revisar `README.md` y actualizar `.gitignore`**

`supabase/tango/README.md` ya describe este flujo (se reescribió el 2026-10-06, al borrar la vía por
LAN y la vía Docker). Sólo hay que confirmar que los comandos y los nombres de archivo coincidan con
lo que efectivamente se creó en las Tareas 1 y 2.

Agregar al final de `supabase/tango/.gitignore`:

```
sql/
```

- [x] **Paso 6: Commit** (después de que Nico lo confirme)

```bash
git add supabase/tango/03_exportar_bak.py supabase/tango/test_exportar_bak.py supabase/tango/README.md supabase/tango/.gitignore
git commit -m "feat(tango): export del .bak a CSV verificable; reemplaza la vía Docker"
```

### Fase 2 — Cerrar decisiones

### Tarea 3: Registrar D1–D8 y aplicar las migraciones que salgan de ellas

**Archivos:**
- Modificar: este documento (§3: completar la decisión elegida en cada fila) y `PLAN_MAESTRO.md` §3.2
  (estado: "extracción resuelta vía `.bak` directo, ver `PLAN_MIGRACION_TANGO.md`"; y corregir §3.2.1
  sobre el CAE, según H1).
- Crear, sólo si se eligen las opciones recomendadas:
  `supabase/migrations/<AAAAMMDDHHMMSS>_migracion_tango_ajustes.sql`, con el timestamp del día en que
  se cree, igual que las demás migraciones

**Interfaces:**
- Produce, para la Fase 3: `recibo_facturas.importe`, `pago_proveedor_facturas.importe`, `notas.factura_id`
  nullable y el nuevo `CHECK` de descuento (si se eligen D1a, D2a y D3a).

- [x] **Paso 1:** Nico decide D1–D8 (D9 ya está decidida: (a)); las respuestas se anotan en la tabla de §3.
- [x] **Paso 1b:** D9 = (a): las percepciones de compra se construyen como **desarrollo de Compras con
  sub-plan propio** (`PLAN_MAESTRO.md` §3.9) (schema + RPC + formulario + Libro IVA Compras), **antes de la Tarea 7**. No entran en
  la migración de ajustes de abajo: cambian el comportamiento de la app, no sólo la carga.
- [x] **Paso 2:** Si D1 = (a), D2 = (a) y D3 = (a), la migración es esta. Se aplica **primero en el
  dry-run** (Tarea 10) y nunca se agrega `FORCE RLS`.

  > ✅ **Aplicadas el 2026-10-06** por MCP sobre `kkdbvzixwlyeahgianuc`, en este orden:
  >
  > | Migración | Qué trae | Hallazgos |
  > |---|---|---|
  > | `20261006120000_migracion_tango_ajustes` | `importe` en `recibo_facturas` / `pago_proveedor_facturas` + los dos `recalcular_estado_*`; `notas.factura_id` nullable | D1 (H5), D2 (H6) |
  > | `20261006130000_numeracion_unica_por_letra` | UNIQUE por letra en `facturas` y `notas`; `notas_compra.factura_compra_id` nullable | H17, H18 |
  > | `20261006140000_percepciones_compra_schema` | tabla `percepciones_compra`, `percepciones_monto`, helpers, RLS sin FORCE | D9 (H13) |
  > | `20261006140001_rpc_compras_percepciones` | `p_percepciones` en las 3 RPC, `*_compra_list`, Libro IVA con percepción separada del crédito fiscal | D9, H18 |
  > | `20261006140002_notas_cliente_id_y_contador_por_letra` | `notas.cliente_id` con backfill; cuatro contadores de nota | H22, H16 |
  >
  > | `20261006150000_revoke_trigger_fn_de_anon` | hallazgo del chequeo post-aplicación: `asiento_balanceado_check()` quedó con `EXECUTE` a `PUBLIC` desde `20260801120000` | — |
  >
  > El código de abajo es el de la primera; las otras están completas en `supabase/migrations/`.
  > `05_cargar.sh` chequea las cinco antes de cargar y aborta si falta alguna.
  >
  > **Verificado después de aplicar:** las columnas (`recibo_facturas.importe`,
  > `pago_proveedor_facturas.importe`, `notas.cliente_id`, `percepciones_monto` ×2), las constraints
  > (`facturas_tipo_numero_key`, `notas_tipo_letra_numero_key`, `percepciones_compra_owner_chk`), los
  > dos `factura_id` nullables, y `percepciones_compra` con RLS + policy `staff_all` y **sin** FORCE.
  > §6 de `POST_LOAD_VERIFY` da OK en los cuatro chequeos: 0 tablas sin RLS, **`anon` ejecuta 0
  > funciones**, `anon` lee 0 tablas. Los advisors de seguridad devuelven sólo los dos warns
  > esperados por diseño (`authenticated_security_definer_function_executable` ×46 —las RPC están
  > hechas para que las llame `authenticated`— y `auth_leaked_password_protection`, que se resuelve
  > en el dashboard junto con §3.4 del plan maestro).
  >
  > **Smoke de la RPC con percepciones** (en una transacción revertida, la base quedó intacta):
  > factura de compra de $1.000.000 neto → IVA 21 % $210.000, percepción de IVA al 3 % calculada
  > desde la base $30.000 + percepción de IIBB Bs. As. con monto explícito $15.000 ⇒
  > **total $1.255.000**, con `total = neto + IVA + percepciones` cerrando al centavo. En el Libro
  > IVA Compras el crédito fiscal queda en $210.000 y las percepciones salen en sus propias columnas
  > ($30.000 IVA / $15.000 IIBB): **no inflan el crédito fiscal**, que es el punto 6 del Review Focus
  > y el criterio de verificación de §3.9. `notas_compra_list()` corre con el `LEFT JOIN` nuevo.

```sql
-- Ajustes de schema para cargar la historia de Tango (PLAN_MIGRACION_TANGO.md D1–D3)

-- D1: importe imputado por factura (GVA07.IMPORT_CAN / CPA05.IMPORT_CAN). NULL = recibo creado por la app.
ALTER TABLE recibo_facturas         ADD COLUMN importe DECIMAL(14,2);
ALTER TABLE pago_proveedor_facturas ADD COLUMN importe DECIMAL(14,2);

CREATE OR REPLACE FUNCTION recalcular_estado_factura(p_factura_id INTEGER)
RETURNS VOID AS $$
DECLARE
  v_total    DECIMAL(14,2);
  v_cobrado  DECIMAL(14,2);
  v_nc_total DECIMAL(14,2);
BEGIN
  SELECT total INTO v_total FROM facturas WHERE id = p_factura_id;
  IF NOT FOUND THEN RETURN; END IF;

  -- Con importe imputado (historia de Tango) se usa ese importe; sin él (app) se mantiene
  -- el cálculo anterior: todos los medios del recibo.
  SELECT COALESCE(SUM(COALESCE(rf.importe,
           (SELECT COALESCE(SUM(rm.monto), 0) FROM recibo_medios rm WHERE rm.recibo_id = rf.recibo_id))), 0)
    INTO v_cobrado
  FROM recibo_facturas rf
  WHERE rf.factura_id = p_factura_id;

  SELECT COALESCE(SUM(total), 0) INTO v_nc_total
  FROM notas WHERE factura_id = p_factura_id AND tipo = 'NC';

  v_cobrado := v_cobrado + v_nc_total;

  UPDATE facturas SET
    estado = CASE
      WHEN v_cobrado <= 0              THEN 'pendiente'
      WHEN v_cobrado >= v_total - 0.01 THEN 'cobrada'
      ELSE                                  'parcial'
    END,
    updated_at = NOW()
  WHERE id = p_factura_id AND estado != 'anulada';
END;
$$ LANGUAGE plpgsql;

-- D2: las 30 NC/ND que Tango tiene "a cuenta" o anuladas no cuelgan de ninguna factura.
ALTER TABLE notas ALTER COLUMN factura_id DROP NOT NULL;

-- D3: descuentos reales de Tango (5 / 7 / 18 %).
ALTER TABLE clientes DROP CONSTRAINT clientes_descuento_porcentaje_check;
ALTER TABLE clientes ADD CONSTRAINT clientes_descuento_porcentaje_check
  CHECK (descuento_porcentaje >= 0 AND descuento_porcentaje <= 100);
```

  Antes de aplicarla, hay que confirmar contra la base viva que el nombre del constraint es
  `clientes_descuento_porcentaje_check`
  (`SELECT conname FROM pg_constraint WHERE conrelid = 'clientes'::regclass AND contype = 'c';`) y que la
  firma y los atributos de `recalcular_estado_factura` (`SECURITY`, `search_path`) siguen siendo los del
  schema `0001`. Si algún advisor fix posterior los cambió, hay que conservarlos.

- [x] **Paso 3:** Si D3 = (a), en `frontend/src/views/Clientes/index.jsx` el selector de descuento tiene que
  aceptar los valores existentes (5, 7, 18), por ejemplo con un input numérico en lugar de las 4 opciones.
- [x] **Paso 4: Commit** (después de que Nico lo confirme) de la migración, la UI y los dos documentos.

### Fase 3 — ETL (CSV → `.sql` por módulo)

Cada módulo se convierte en **su propio sub-plan con código**, escrito cuando la Tarea 3 esté cerrada,
porque el código depende de D1–D8. Esta fase fija lo que **no** depende de las decisiones: el orden, las
reglas de mapeo y los controles de aceptación (con números del `.bak` del 25/09). Todo el ETL lee
`csv/`, escribe en `sql/` y se testea con `unittest` sobre CSV de muestra.

**Tablas de apoyo sin destino propio** (las 57 del alcance quedan cubiertas así):

| Uso | Tablas |
|---|---|
| Lookups que el ETL resuelve en memoria | `GVA18` (provincias), `GVA15` (qué es cada `T_COMP`), `GVA151` (rubros), `BANCO`, `CPA57` (provincias de compras → `jurisdiccion` de las percepciones de `CPA18`), `TIPO_CONTABLE`, `TIPO_ASIENTO`, y `CPA14` (alícuotas de compras: **no está entre las 57**, se transcribe abajo) |
| Precios históricos de los renglones (no tocan `productos`) | `STA11`, `STA36`, `GVA10` (`INCLUY_IVA` decide si se divide por 1,21), `GVA17` |
| Vencimientos y estado | `GVA46` (ventas) y `CPA54` (compras): sirven para chequear el estado `pendiente` / `parcial` |
| Desglose de IVA por comprobante de venta (control, no se carga) | `GVA42` + `GVA88`: Σ `IMPORTE` por `COD_ALICUO` = IVA de los ítems de esa alícuota (H11) |
| Clasificación SIAP / CITI (informativa, no se carga) | `GVA63` (ventas) y `CPA63` (compras) (H14) |
| Sin uso | `CPA28` (maestro de retenciones: Marblock no practica retenciones, H15) |
| Matriz de imputación contable (insumo de `PLAN_MAESTRO.md` §3.3, no es una carga) | `CUENTA_SB`, `MODULO_CUENTA`, `ARTICULO_CUENTA`, `CONCEPTO_CP`, más los asientos de la Tarea 9 |
| Trazabilidad de cheques (alimenta D6) | `MOVIMIENTO_CHEQUE_TERCERO`, `SBA23` |
| Informativas, no se cargan | `GVA27` (contactos), `CPA02` (textos de IIBB) |
| Links de numeración | `GVA43` (talonarios; `PROXIMO` está ofuscado, ver H2), `GVA54`, `CPA48` |

**`CPA14` — alícuotas de compras** (10 filas, transcriptas del `.bak` del 25/09). Clasifica tanto los
slots `COD_IVA1..5` de `CPA04` como el `COD_IMPUES` de `CPA18`. Se fija en el ETL como diccionario, y
si aparece un código que no está acá, **el ETL aborta** (un `.bak` nuevo puede traer códigos nuevos):

| Código | `DESC_IVA` | % | Destino en el CRM |
|---|---|---:|---|
| 1 | IVA 21 | 21 | `factura_compra_iva_detalle` |
| 2 | IVA 10.5 | 10,5 | `factura_compra_iva_detalle` |
| 5 | IVA 27 | 27 | `factura_compra_iva_detalle` |
| 3 | PERCEPCION DE IVA | 3 | percepción `iva` (D9) |
| 4 | PERCEPCION 10 % | 10 | percepción `iva` (D9) |
| 51 | PERCEPCION I. B. (Bs. As.) | 1,5 | percepción `iibb`, jurisdicción Buenos Aires (D9) |
| 54 | PERCEPCION IB CAP | 1,5 | percepción `iibb`, jurisdicción CABA (D9) |
| 40 | IMP INT | — | `imp_internos` (D9) |
| 52 | IMP. INTERNO NULO | 0 | `imp_internos` (D9) |
| 53 | IMP. A LAS GANANCIAS | 3 | percepción `ganancias` (D9) |

**Orden de carga** (respeta las FK; con `session_replication_role = replica` las FK no se validan
durante la carga, pero el orden igual se mantiene para que el dry-run sea legible):
maestros → Ventas (facturas → remitos → notas → recibos → medios / imputaciones → cheques) →
Compras (comprobantes → percepciones según D9) → Tesorería → Contabilidad → contadores → secuencias.

### Tarea 4: `etl/comun.py` — lectura y limpieza compartidas

Reglas (cada una con su test):
- Leer `csv/<T>.csv` con los nombres de columna de `esquema_tango.tsv` → `list[dict]`.
- `fecha(v)`: `''` o `1800-01-01 …` → `None`. Una fecha posterior a 2027 → `None` **y** una línea en
  `sql/_anomalias.txt` (cubre el punto 4 de Review Focus; caso real: los 2 cheques de 2031).
- `texto(v)`: hace `strip()`; si queda `''`, devuelve `None` en los campos opcionales.
- `n_comp(v)`: convierte `'A000200002321'` en `('A', 2, 2321, '00002-00002321')` y `' 000100004288'` en
  `(None, 1, 4288, '00001-00004288')`. Es el formato `PPPPP-NNNNNNNN` del CRM: el punto de venta de 4
  dígitos de Tango se completa a 5.
- `escribir_copy(tabla, columnas, filas)`: emite `COPY tabla (cols) FROM stdin;` en formato texto de
  Postgres (escapando `\t`, `\n` y `\\`; `NULL` como `\N`).
- **Aceptación:** tests de cada función, que incluyan los dos ejemplos de `n_comp` y una fecha
  `1800-01-01`.

### Tarea 5: Maestros

| Destino | Fuente | Reglas | Aceptación (`.bak` 25/09) |
|---|---|---|---|
| `clientes` | `GVA14` | `razon_social` = `RAZON_SOCI`; `cuit` = `CUIT` (al único sin CUIT se le carga el valor por defecto de consumidor final); `condicion_iva` = `CAT_IVA` del **último** comprobante del cliente en `GVA12` (`RI` → `Resp. Inscripto`, `CF` → `Consumidor Final`, `EX` → `Exento`), y si el cliente no tiene comprobantes (10 casos) → `Resp. Inscripto` si el CUIT es válido o `Consumidor Final` si no; `direccion` = `DOMICILIO`; `localidad` = `LOCALIDAD`; `provincia` = nombre en `GVA18` por `COD_PROVIN`; `telefono` = `TELEFONO_1`; `email` = `E_MAIL`; `descuento_porcentaje` = `PORC_DESC` (D3); `activo` = `FECHA_INHA` vacía. El ETL guarda el mapa `COD_CLIENT → id`. | 695 filas; el `id = 1` ("Marblock SA") se conserva o se fusiona, según §3.2.8 del plan maestro |
| `proveedores` | `CPA01` | `razon_social` = `NOM_PROVEE`; `cuit` = `N_CUIT`; `condicion_iva` por `COND_IVA`; `activo` = `FECHA_INHA` vacía; mapa `COD_PROVEE → id` | 379 |
| `cuentas_bancarias` | `SBA01` | `descripcion` = `DESCRIPCIO`; `banco` por `ID_BANCO` → `BANCO`; `numero` = `NRO_CTA_BANCARIA`; mapa `COD_CTA → id` | 11 |
| `tipos_comprobante_tesoreria` | `SBA02` | `codigo` = `COD_COMP`; `signo` según `D_H` | 5 |
| `plan_de_cuentas` | `CUENTA` + `RUBRO_CN` | `codigo` = `COD_CUENTA`; `descripcion` = `DESC_CUENTA`; la jerarquía sale de `RUBRO_CN.ID_RUBRO_PADRE` / `NRO_NIVEL`; `tipo_cuenta` (Activo / Pasivo / Patrimonio / Ingreso / Egreso / Orden) sale del rubro raíz y la valida el contador; `activo` = `HABILITADO`; `imputable` = cuenta hoja | 152 cuentas |
| `materiales` | `CPA45` | `codigo` = `COD_CONCEP`; `descripcion` = `DESC_CONCE` | 19 |
| `productos` | — | **No se carga** (ya está decidido): `COD_ARTICU` se cruza con `productos.codigo` para `producto_id`, y si no coincide → `NULL` con la descripción de `STA11` | 25 sembrados intactos |

### Tarea 6: Ventas

| Destino | Fuente | Reglas | Aceptación |
|---|---|---|---|
| `facturas` | `GVA12` con `T_COMP='FAC'` | `numero` / `punto_venta` / `numero_comp` con `n_comp`; `tipo` = letra; `neto_gravado` = `IMPORTE_GR + IMPORTE_EX` (en el CRM el neto incluye los ítems exentos, H12); `iva_monto` = `IMPORTE_IV`; `total` = `IMPORTE`; `descuento_monto` = `IMPORTE_BO`; `percepciones_monto` = 0 (H11); `estado`: `CAN` → `cobrada`, `PEN` → `pendiente` (o `parcial` si tiene imputaciones), `ANU` → `anulada`, `PAG` → `cobrada`; los 2 casos `***` se revisan a mano; `cae` según D4 | 4.596; Σ `total` por año igual a Σ `GVA12.IMPORTE` |
| `factura_items` | `GVA53` + `GVA125` | `precio_unitario` = `PRECIO_NET` (ya viene neto); `descuento_item` = `PORC_DTO`; `alicuota_iva_id`: renglón con `IMPORTE_EXENTO ≠ 0` → `Exento (0%)`, el resto por `PORC_IVA`; `descripcion` = `STA11` + `GVA125` | Σ de los subtotales de cada factura = `neto_gravado + descuento_monto` (las diferencias van al reporte); IVA de los ítems por alícuota = Σ `GVA42.IMPORTE` por `COD_ALICUO` |
| `notas` + `nota_items` | `GVA12` `N/C` / `N/D` + `GVA53` | `tipo` NC/ND; `factura_id` según D2 (a partir de `GVA07` con `T_COMP_CAN` = la nota); importes, exento y alícuotas con las mismas reglas que `facturas` / `factura_items` (las 61 ND A exentas, H12) | 375 notas (310 NC + 65 ND) |
| `recibos` | `GVA12` `REC` | Cabecera; `total` = `IMPORTE` | 3.701 |
| `recibo_facturas` | `GVA07` con `T_COMP_CAN='REC'` | Un vínculo por (recibo, factura); `importe` = `IMPORT_CAN` (D1) | 5.299 imputaciones |
| `recibo_medios` | `SBA04` / `SBA05` del recibo | Efectivo → `efectivo`; cuenta bancaria → `transferencia`; `CHEQUES` → `cheque` con los datos de `SBA14` | Σ medios = `recibos.total` |
| `percepciones` | — | **No se carga nada:** Tango no tiene percepciones de venta (H11). `GVA42` / `GVA88` se usan sólo como control del IVA por alícuota (ver `factura_items`) | 0 filas; los 4.971 comprobantes con `percepciones_monto = 0` |
| `remitos` + `remito_items` | `STA14` / `STA20` con `T_COMP='REM'` | Cliente por `COD_PRO_CL`; `factura_id` desde `GVA54`, que admite N remitos por factura (migración `20260821130000`) | 6.835 remitos |
| `cheques` | `SBA14` | `numero` = `N_CHEQUE`; `tipo` según `TIPO_CHEQU`; `monto` = `IMPORTE_CH`; `fecha_vcto` = `FECHA_CHEQ`; `estado` según D6 | 5.007 |

**Control global de Ventas:** el saldo de cuenta corriente de cada cliente después de la carga tiene que
ser igual a `GVA14.SALDO_CC`. Es el control que mejor detecta errores de imputación.

### Tarea 7: Compras

| Destino | Fuente | Reglas | Aceptación |
|---|---|---|---|
| `facturas_compra` + `factura_compra_iva_detalle` | `CPA04` con `T_COMP='FAC'` | IVA desglosado **sólo** desde los slots `COD_IVA1..5` con código 1 / 2 / 5 de `CPA14` (21 / 10,5 / 27 %); los slots con código 3 / 4 son percepción de IVA y van a percepciones (D9), **nunca** al desglose de IVA; `neto_gravado` = `IMPORTE_NE + IMPORTE_EX`; `percepciones_monto` = slots 3 / 4 + Σ `CPA18` del comprobante (D9); `total` = `IMPORTE_TO`; `proveedor_id` por `COD_PROVEE` | 6.191; `IMPORTE_TO = neto_gravado + IVA + IMPORTE_IN + percepciones` en todos menos 19 comprobantes viejos (entre 2011 y 2024), que van a `_anomalias.txt` para revisarlos a mano |
| `notas_compra` | `CPA04` con `T_COMP` `N/C` / `N/D` | `factura_compra_id` por la imputación en `CPA05` (con el mismo criterio que D2); importes, IVA y percepciones con las mismas reglas que `facturas_compra` | 478 (368 NC + 110 ND) |
| `pagos_proveedor` + `pago_proveedor_medios` | `CPA04` con `T_COMP='O/P'` (órdenes de pago) + `SBA04` / `SBA05` | Cabecera desde `CPA04`; medios desde los renglones de tesorería del mismo comprobante (efectivo / transferencia / `cheque_propio` con `SBA15` / `cheque_tercero` con `SBA14`) | 3.331 |
| `facturas_compra_items` | `CPA47` (y `CPA46`) | `material_id` por `COD_CONCEP` → `materiales` | 6.588 + 144 |
| `pago_proveedor_facturas` | `CPA05` | Orden de pago ↔ factura; `importe` = `IMPORT_CAN` (D1) | 8.319 imputaciones |
| Percepciones de compra (destino según D9) | slots 3 / 4 de `CPA04` + `CPA18` (+ `CPA57`) | Tipo y jurisdicción por el código de `CPA14` (tabla de arriba); `monto` = `IMP_IVAn` o `CPA18.IMPORTE`; `alicuota` = la de `CPA14`; `base_imponible` = `IMPORTE_NE` del comprobante; `CPA18` se engancha con `CPA04` por (`TCOMP_IN_C`, `NCOMP_IN_C`) | 1.272 desde slots (1.263 al 3 % + 9 al 10 %) + 703 desde `CPA18` |
| `retenciones` | — | **No se carga:** `CPA18` son percepciones sufridas, no retenciones (H13), y las retenciones practicadas (`CPA29`) son 4 filas de 2011 en $0 (H15) | 0 |
| `proveedor_alicuotas` | — | **No se carga:** `CPA63` es la clasificación SIAP de cada comprobante, no la configuración de retenciones del proveedor (H14) | 0 |
| `remitos_compra` | `CPA48` | Vínculo con la factura de compra | 143 |

### Tarea 8: Tesorería

| Destino | Fuente | Reglas | Aceptación |
|---|---|---|---|
| `movimientos_tesoreria` | `SBA04` (cabecera) + `SBA05` (renglones) | Un movimiento por renglón con cuenta; `signo` según `D_H`; `conciliado` = `CONCILIADO` | Saldo final de cada cuenta = saldo de Tango a la fecha de corte |
| `cheques_propios` | `SBA15` | `cuenta_bancaria_id` por `CTA_BANCO`; `estado` por `ESTADO` | 88 |

### Tarea 9: Contabilidad

| Destino | Fuente | Reglas | Aceptación |
|---|---|---|---|
| `asientos_contables` | `ASIENTO_COMPROBANTE_GV` / `_CP` / `_SB` | `origen` = `venta` / `compra` / `tesoreria`; `estado` = `confirmado` (o `anulado` si `ASIENTO_ANULACION`); `referencia_tipo` / `referencia_id` = el comprobante migrado | 4.904 + 6.671 + 7.150 cabeceras |
| `asiento_items` | `ASIENTO_GV` / `_CP` / `_SB` | `D` → `debe`, `H` → `haber` (todos positivos, H10); `cuenta_id` por `ID_CUENTA` | 51.379 renglones; **0 asientos descuadrados** (hoy: 0) |

### Fase 4 — Carga, dry-run y cutover

### Tarea 10: `05_cargar.sh` + dry-run

- [x] **Paso 1:** El script hace `psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1` con `BEGIN;
  SET session_replication_role = replica;` → `TRUNCATE` de las tablas destino `RESTART IDENTITY CASCADE`
  (sin tocar `productos`, ni `config_empresa`, ni los contadores sembrados, salvo que §3.2.8 del plan
  maestro decida otra cosa) → `\i sql/*.sql` en el orden de la Fase 3 → `SET session_replication_role =
  origin; COMMIT;` → reset de secuencias (el `DO $$` de §3.2.5 del plan maestro).

  Es `supabase/tango/05_cargar.sh`, y además: chequea antes de empezar que las migraciones del
  2026-10-06 estén aplicadas y que el rol pueda hacer `SET session_replication_role` (si no, aborta
  sin tocar nada); vacía **42 tablas**, verificadas contra `pg_constraint` para que el `CASCADE` no
  arrastre `productos` ni los catálogos del sistema; carga `sql/31_percepciones_compra.sql`
  **después** de `30_compras.sql`, porque reparte el `total` de Tango en `percepciones_monto`; y
  cierra con el UPSERT de los 10 contadores (`python3 -m etl.contadores` los recalcula desde el
  `.bak`) y el reset de secuencias. Tiene `--conteos` y `--vaciar` para los pasos 2 y 5.
- [ ] **Paso 2:** Correr la carga **dos veces seguidas** y comparar los conteos: tienen que ser idénticos
  (punto 5 de Review Focus). `./05_cargar.sh` imprime `sql_conteos.sql` al terminar, que trae el
  esperado del `.bak` al lado de lo cargado.
- [ ] **Paso 3:** `psql "$SUPABASE_DB_URL" -f supabase/POST_LOAD_VERIFY.sql`, más los controles de
  aceptación de las Tareas 5 a 9 (`python3 -m etl.controles_ventas` / `_compras` / `_tesoreria`).
  El script ya cubre los cuatro módulos: §1 cuenta **todas** las tablas de `public`, §3b/§3c son la
  integridad de Compras / Tesorería / Contabilidad y el cuadre de asientos, y §5b las invariantes de
  totales de Compras (incluida `total = neto + IVA + percepciones`, que sólo cierra si corrió el
  `31_`). Ninguna fila debería salir con `⚠`.
- [ ] **Paso 4:** Entrar a la app, abrir 3 clientes (uno con descuento de 18 %, uno con recibos que
  cancelan varias facturas y uno con NC), comparar la cuenta corriente con Tango y emitir un comprobante
  de prueba en un cliente descartable. Sumar una NC "a cuenta" de las 23 de H22: tiene que aparecer en
  la lista y en el saldo del cliente.
- [ ] **Paso 5:** Vaciar (`./05_cargar.sh --vaciar`) hasta el cutover.

> **Lo que falta para poder correr los pasos 2 a 5:** sólo el URI directo de la base en un archivo
> gitignoreado (las migraciones ya están aplicadas, Tarea 3 paso 2) —
> `export SUPABASE_DB_URL="$(cat ../../.db_url)"`. Tiene que ser el connection string **directo**
> (usuario `postgres`), no el pooler: el pooler no deja hacer `SET session_replication_role`.

### Tarea 11: Cutover real (runbook del día D8)

El pipeline completo tarda minutos, así que todo esto entra en una mañana. **Nada de esto toca Tango:**
se lee un `.bak` y se carga Supabase.

**Antes del día D** (se puede hacer con anticipación):

- [x] Las migraciones del 2026-10-06 **aplicadas** en producción (Tarea 3 paso 2).
- [ ] El dry-run de la Tarea 10 cerrado con `POST_LOAD_VERIFY` sin `⚠`.
- [ ] La base **vacía** (`./05_cargar.sh --vaciar`): el `TRUNCATE` está dentro de la transacción de
      carga, así que esto es por prolijidad, no por necesidad.
- [ ] Usuarios de staff creados y *"Allow new users to sign up"* deshabilitado (`PLAN_MAESTRO.md` §3.4).
- [ ] D6 cerrada (los tres códigos de estado de cheque) y D8 con fecha.

**El día D:**

1. [ ] Avisar que desde ese momento **no se carga nada más en Tango**. Anotar la hora.
2. [ ] En la máquina vieja, con clics: Tango → *Copias de seguridad* (o SSMS → *Back Up…*, tipo
   **Full**, **sin comprimir**) → pendrive. Copiar el `.bak` nuevo a la raíz del repo como
   `MARBLOCK_SA.bak` (está gitignoreado).
3. [ ] En esta Mac, desde `supabase/tango/`:

   ```bash
   python3 -m unittest discover -s . -p 'test_*.py' -t .   # 64 tests; falla si el .bak cambió de esquema
   python3 03_exportar_bak.py                              # .bak → csv/
   python3 02_verificar_export.py                          # tiene que terminar en [OK]
   python3 -m etl                                          # csv/ → sql/ + sql/_anomalias.txt
   ```

4. [ ] **Revisar `sql/_anomalias.txt`.** Contra el `.bak` del 25/09 son 610 líneas, todas de tipos ya
   conocidos (remitos vinculados a varias facturas, NC/ND imputadas a varias, netos ajustados contra la
   alícuota mayor, cheques revertidos, fechas centinela). **Un tipo de anomalía que no esté en esa lista
   frena el cutover** hasta entenderlo.
5. [ ] **Contadores (D5).** `python3 -m etl.contadores` imprime el bloque con el último número de cada
   serie **por fecha** (no el máximo: H4) y, aparte, las series que quedan sin contador (H21).
   Reconfirmar antes de pegarlo en `05_cargar.sh`:
   - facturas y notas → ARCA (`FECompUltimoAutorizado` o *Mis Comprobantes*);
   - remitos → el **talonario físico** AGEE, que es la fuente real (Supabase quedó en 10324, H3);
   - recibos y O/P → Tango.

   Son `INSERT … ON CONFLICT (tipo) DO UPDATE`, **no `UPDATE`**: de los 10 tipos sólo existen hoy
   `asiento`, `pago_proveedor` y `remito` (`PLAN_MAESTRO.md` §3.2.8), así que un `UPDATE` no haría nada
   y `crear_factura` seguiría fallando con *"Contador no encontrado"*.
6. [ ] Cargar y verificar:

   ```bash
   export SUPABASE_DB_URL="$(cat ../../.db_url)"      # connection string DIRECTO, no el pooler
   ./05_cargar.sh
   psql "$SUPABASE_DB_URL" -f ../POST_LOAD_VERIFY.sql
   python3 -m etl.controles_ventas ; python3 -m etl.controles_compras ; python3 -m etl.controles_tesoreria
   ```

   Criterio de corte: **ninguna fila con `⚠`** en `POST_LOAD_VERIFY`, los conteos iguales a los que
   imprimió el ETL, y los controles de aceptación con las mismas diferencias conocidas que en el
   dry-run (5 proveedores con redondeos de centavos contra `CPA01.SALDO_CC`, 0 órdenes de pago
   descuadradas).
7. [ ] Smoke en la app, con la data real: 3 clientes (uno con descuento de 18 %, uno con varios recibos,
   uno con NC), una NC "a cuenta" de las de H22, un comprobante de prueba en un cliente descartable
   (que tome el número siguiente del contador) y un PDF.
8. [ ] Salir en vivo.

**Rollback:** Tango queda intacto y congelado — nada de este plan lo modifica — así que volver atrás es
seguir usándolo, y el `.bak` del día queda guardado como respaldo. Para rehacer la carga desde cero:
`./05_cargar.sh --vaciar` y volver al paso 6; el `TRUNCATE` dentro de la transacción la hace idempotente.

---

## Apéndice A — Conteos por tabla (`.bak` del 2026-09-25 vs. relevamiento del 2026-08-21)

"Último dato" es la fecha más reciente entre las columnas de fecha de movimiento de la tabla (no incluye
vencimientos).

| Tabla | Módulo | Destino | Filas 21/08 | Filas `.bak` 25/09 | Δ | Último dato |
|---|---|---|---:|---:|---:|---|
| `GVA14` | Ventas | clientes | 690 | 695 | +5 | 2026-09-17 |
| `GVA27` | Ventas | - | 205 | 205 | 0 | — |
| `GVA18` | Ventas | (lookup) | 24 | 24 | 0 | — |
| `STA11` | Ventas | productos | 39 | 39 | 0 | 2025-12-02 |
| `STA36` | Ventas | productos.precio_sin_iva | 39 | 39 | 0 | — |
| `GVA10` | Ventas | (lookup) | 4 | 4 | 0 | — |
| `GVA17` | Ventas | productos.precio_sin_iva | 70 | 70 | 0 | 2026-09-16 |
| `GVA12` | Ventas | facturas / notas / recibos | 8.620 | 8.672 | +52 | 2026-09-24 |
| `GVA53` | Ventas | factura_items / nota_items | 11.390 | 11.456 | +66 | 2026-09-23 |
| `GVA125` | Ventas | *_items.descripcion | 7.339 | 7.339 | 0 | — |
| `GVA15` | Ventas | (lookup) | 5 | 5 | 0 | — |
| `GVA46` | Ventas | facturas.estado | 4.506 | 4.534 | +28 | — |
| `GVA07` | Ventas | recibo_facturas | 5.672 | 5.711 | +39 | 2026-09-23 |
| `GVA42` | Ventas | (control de IVA por alícuota, H11) | 4.846 | 4.874 | +28 | — |
| `GVA63` | Ventas | - (clasificación SIAP, H14) | 7.191 | 7.238 | +47 | — |
| `GVA43` | Ventas | contadores | 9 | 9 | 0 | — |
| `STA14` | Ventas | remitos | 7.259 | 7.300 | +41 | 2026-09-23 |
| `STA20` | Ventas | remito_items | 15.318 | 15.406 | +88 | 2026-09-23 |
| `GVA54` | Ventas | remitos.factura_id | 15.290 | 15.376 | +86 | — |
| `GVA88` | Ventas | (control de IVA por alícuota, H11) | 61 | 61 | 0 | — |
| `GVA151` | Ventas | (lookup) | 85 | 85 | 0 | — |
| `CPA01` | Compras | proveedores | 375 | 379 | +4 | 2026-09-21 |
| `CPA02` | Compras | - | 375 | 379 | +4 | — |
| `CPA04` | Compras | facturas_compra + factura_compra_iva_detalle + percepciones de compra (D9) | 9.960 | 10.000 | +40 | 2026-09-25 |
| `CPA05` | Compras | pago_proveedor_facturas | 8.289 | 8.319 | +30 | 2026-09-25 |
| `CPA18` | Compras | percepciones de compra (D9, H13) | 703 | 703 | 0 | 2025-12-31 |
| `CPA46` | Compras | facturas_compra_items | 144 | 144 | 0 | 2026-08-12 |
| `CPA47` | Compras | facturas_compra_items | 6.566 | 6.588 | +22 | 2026-09-21 |
| `CPA48` | Compras | remitos_compra.factura_compra_id | 143 | 143 | 0 | — |
| `CPA45` | Compras | materiales | 19 | 19 | 0 | — |
| `CPA28` | Compras | - (sin uso, H15) | 18 | 18 | 0 | — |
| `CPA57` | Compras | (lookup) | 25 | 25 | 0 | — |
| `CPA54` | Compras | facturas_compra.estado | 6.170 | 6.191 | +21 | — |
| `CPA63` | Compras | - (clasificación SIAP, H14) | 8.355 | 8.379 | +24 | — |
| `SBA01` | Tesoreria | cuentas_bancarias | 11 | 11 | 0 | — |
| `SBA02` | Tesoreria | tipos_comprobante_tesoreria | 5 | 5 | 0 | — |
| `SBA04` | Tesoreria | movimientos_tesoreria | 7.108 | 7.150 | +42 | 2026-09-25 |
| `SBA05` | Tesoreria | movimientos_tesoreria + recibo_medios + pago_proveedor_medios | 16.270 | 16.366 | +96 | 2026-09-25 |
| `SBA14` | Tesoreria | cheques | 4.994 | 5.007 | +13 | 2031-05-18 ⚠ H8 |
| `SBA15` | Tesoreria | cheques_propios | 88 | 88 | 0 | 2012-06-01 |
| `SBA23` | Tesoreria | - | 9.932 | 9.962 | +30 | 2026-09-24 |
| `MOVIMIENTO_CHEQUE_TERCERO` | Tesoreria | cheques.estado | 9.970 | 10.000 | +30 | — |
| `BANCO` | Tesoreria | (lookup) | 190 | 190 | 0 | — |
| `CUENTA` | Contabilidad | plan_de_cuentas | 152 | 152 | 0 | — |
| `RUBRO_CN` | Contabilidad | plan_de_cuentas.cuenta_padre_id / nivel | 43 | 43 | 0 | — |
| `CUENTA_SB` | Contabilidad | (matriz) | 11 | 11 | 0 | — |
| `TIPO_CONTABLE` | Contabilidad | (lookup) | 44 | 44 | 0 | — |
| `TIPO_ASIENTO` | Contabilidad | (lookup) | 11 | 11 | 0 | — |
| `MODULO_CUENTA` | Contabilidad | (matriz) | 1.064 | 1.064 | 0 | — |
| `ARTICULO_CUENTA` | Contabilidad | (matriz) | 22 | 22 | 0 | — |
| `ASIENTO_GV` | Contabilidad | asiento_items | 13.550 | 13.631 | +81 | — |
| `ASIENTO_CP` | Contabilidad | asiento_items | 22.010 | 22.075 | +65 | — |
| `ASIENTO_SB` | Contabilidad | asiento_items | 15.585 | 15.673 | +88 | — |
| `ASIENTO_COMPROBANTE_GV` | Contabilidad | asientos_contables | 4.876 | 4.904 | +28 | 2026-09-23 |
| `ASIENTO_COMPROBANTE_CP` | Contabilidad | asientos_contables | 6.649 | 6.671 | +22 | 2026-09-24 |
| `ASIENTO_COMPROBANTE_SB` | Contabilidad | asientos_contables | 7.108 | 7.150 | +42 | 2026-09-25 |
| `CONCEPTO_CP` | Contabilidad | (matriz) | 19 | 19 | 0 | — |

