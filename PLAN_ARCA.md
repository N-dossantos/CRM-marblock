# PLAN_ARCA.md — Facturación electrónica ARCA (ex AFIP) en el CRM

> **Objetivo único:** que la factura de venta se emita **una sola vez, desde el sistema**, y que el
> CAE lo pida el CRM contra los web services de ARCA. Hoy la factura se carga dos veces —primero en
> la web de ARCA, después en el CRM para mantener numeración y relación— y esa doble carga es
> exactamente lo que este plan elimina.
>
> Diseño revisado el **2026-10-13** con el estado actual del CRM, los datos de Tango y las decisiones
> confirmadas para el flujo de borradores, la recuperación ante timeout, las percepciones y la
> separación de ambientes. Documento vivo: al cerrar cada fase, marcar su estado en §9.

---

## 1. Decisiones tomadas

| Decisión | Valor | Por qué |
|---|---|---|
| **Comprobantes en alcance** | Factura A, Factura B, Nota de Crédito A/B, Nota de Débito A/B | Es todo lo que hoy se emite a mano en la web de ARCA. Las NC/ND llevan **CAE propio**, no heredan el de la factura. |
| **Enfoque de integración** | Edge Function propia en Deno, directo contra **WSAA + WSFEv1** | Un solo backend (mismo modelo que `functions/pdf`), costo cero, sin terceros viendo CUIT/importes, sin dependencia externa para una función legalmente crítica. |
| **Punto de venta** | **PV nuevo**, dedicado a web services, numeración desde 1 | ARCA no permite usar por WS un PV dado de alta como *Comprobantes en línea*. El `00002` actual queda como histórico, intacto. |
| **Flujo de emisión** | Un botón, con borrador de rescate y resultado incierto recuperable | Un rechazo explícito queda rechazado y permite corregir/reintentar. Ante timeout o error de transporte, queda pendiente de reconciliación: al reintentar se consulta primero ARCA y se recupera el CAE si ya autorizó. No se pierde la carga ni se duplica el comprobante. |
| **Autoridad de la numeración** | **ARCA**, vía `FECompUltimoAutorizado` | Los comprobantes fiscales **dejan de usar `contadores`**. Elimina la deriva por diseño. `contadores` sigue sirviendo a presupuesto, remito y recibo, que no son fiscales. |
| **Tributos** | Sólo IVA en la primera entrega | El histórico de Tango no contiene percepciones, pero el CRM actual ya permite cargarlas. Si `percepciones_monto ≠ 0`, la emisión se bloquea antes de llamar a ARCA y la UI deriva al procedimiento fiscal vigente; no ofrece quitar la percepción sólo para habilitar la emisión. Mapear percepciones a `Tributos` queda fuera de esta entrega. |
| **Operaciones exentas** | Van a `ImpOpEx`, no al array `Iva` | En Tango hay comprobantes con importe exento: el renglón `Exento (0%)` de `alicuotas_iva` es **exento**, no "gravado al 0 %" (ver §3.1). |
| **Factura B** | Receptores identificados con CUIT o DNI | No hay venta de mostrador anónima; no hace falta el flujo `DocTipo 99 / DocNro 0`. |

### Lo que muestra Tango (`MARBLOCK_SA.bak`, 25/09/2026)

- **No hay percepciones.** En las 4.971 facturas, NC y ND de `GVA12` (2011 → 24/09/2026), `IMPORTE`
  es exactamente `IMPORTE_GR + IMPORTE_IV + IMPORTE_EX`: no queda nada que pueda ser una percepción.
  `GVA41` define la alícuota 51 *"PERCEP. INGR. BRUTOS"*, pero **ningún comprobante la usa nunca**.
- **`GVA42` no es una tabla de percepciones**, aunque así se la interpretó en el relevamiento del 21/08
  (y de ahí salió la migración `20260821140000_ventas_percepciones.sql`). Es el **desglose de IVA por
  alícuota** de cada comprobante: sus 4.874 filas usan sólo `COD_ALICUO` 1 (21 %) y 2 (10,5 %),
  `PERCEP = 0` en todas, y la suma de `IMPORTE` coincide con `GVA12.IMPORTE_IV` en el 100 % de los
  comprobantes. `GVA88` (61 filas) es lo mismo.
- **Sí hay operaciones exentas:** 64 comprobantes con `IMPORTE_EX ≠ 0`, casi todos **Notas de Débito
  A** (61; la última del 26/02/2026). En 28 de ellos todo el importe es exento. Hay además 1 NC A
  (2020) y 2 Facturas B (2022 y 2024).
- La tabla `percepciones` y `facturas/notas.percepciones_monto` ya existen y las RPCs/API actuales
  aceptan percepciones. La emisión las trata como una restricción operativa explícita: si un
  comprobante trae `percepciones_monto ≠ 0`, se rechaza en el CRM antes de llamar a ARCA (§3.3).

### Fuera de alcance (anotado, no olvidado)

- Percepciones IIBB / percepción IVA: Tango no registra ninguna (§1). Si algún día se empiezan a
  aplicar, el modelo de datos ya está (tabla `percepciones`, migración `20260821140000`): faltaría
  mapear `tipo_percepcion` al `Id` de tributo de ARCA (verificar contra `FEParamGetTiposTributos`),
  armar el array `Tributos` con `BaseImp` / `Alic` / `Importe` y mandar `ImpTrib`.
- Consumidor final sin identificar (`DocTipo 99`).
- Factura de Crédito Electrónica MiPyME (FCE), comprobantes de exportación, moneda extranjera.
- Presupuestos y remitos: **no son comprobantes fiscales**, no tocan ARCA. El remito sigue con su
  talonario preimpreso y su CAI (ver `PLAN_MAESTRO.md` §3.7 — vence 25/11/2026).
- Consulta de padrón A5 para autocompletar datos de cliente (extensión futura, servicio aparte).

---

## 2. Arquitectura

```
frontend ──POST /functions/v1/arca/emitir {tipo:'factura', id:123}──▶ Edge Function `arca`
                                                                          │
                                                    ┌─────────────────────┴──────────────────────┐
                                                    │ 1. token WSAA (cache 12 h en arca_tokens)  │
                                                    │ 2. arca_reclamar_serie(PV, tipo)           │
                                                    │ 3. FECompUltimoAutorizado(PV, tipo)        │
                                                    │ 4. arca_reservar_numero(id, último+1)      │
                                                    │ 5. FECAESolicitar                          │
                                                    └─────────────────────┬──────────────────────┘
                                                                          ▼
                                                     RPC arca_registrar_cae / arca_registrar_rechazo
                                                     → número + CAE + vto + fila de auditoría
```

### Estructura de archivos

```
supabase/functions/arca/
  index.ts     router: POST /arca/emitir, POST /arca/reconciliar,
               GET /arca/estado (FEDummy + ambiente), GET /arca/ultimo,
               GET /arca/solicitud (estado/errores seguros por comprobante)
  wsaa.ts      TRA + firma CMS/PKCS#7 + cache de token
  wsfe.ts      sobres SOAP y parseo de FECAESolicitar / FECompUltimoAutorizado / FECompConsultar
  mapeo.ts     CRM → ARCA (tipos de comprobante, Ids de IVA, doc tipo, condición IVA receptor)
  soap.ts      helpers de XML (armado y extracción, sin cliente SOAP genérico)
```

### WSAA — autenticación

Arma el `loginTicketRequest` (XML con `uniqueId`, `generationTime`, `expirationTime`, `service=wsfe`),
lo firma en **CMS/PKCS#7** con el certificado y la clave privada, y lo manda en base64 por SOAP al
método `loginCms`. Devuelve `token` + `sign`.

> ⚠️ **El cache no es una optimización, es obligatorio.** El ticket vale 12 h y ARCA **rechaza pedir
> uno nuevo mientras el anterior siga vigente** (`El CEE ya posee un TA valido para el acceso al WSN
> solicitado`). Sin cache, el segundo pedido del día falla.

Tabla `arca_tokens` (`servicio`, `token`, `sign`, `expira_en`), con **RLS deny-all**: ni siquiera
`authenticated` puede leerla. `token` + `sign` son una credencial que habilita facturar a nombre de
la empresa. Sólo la Edge Function, con service-role, la lee y escribe.

Firma CMS en Deno: **`npm:node-forge`** (`forge.pkcs7.createSignedData`). Es el punto técnico a
despejar primero — ver Fase 1.

### WSFEv1 — emisión

SOAP plano por `fetch`, sin cliente SOAP genérico (el WSDL de ARCA es grande y el subconjunto que se
usa es chico). Métodos:

| Método | Uso |
|---|---|
| `FEDummy` | Health check. No requiere autenticación. Sirve para el indicador de estado en la UI. |
| `FECompUltimoAutorizado` | Último número autorizado para (PV, tipo). Fuente de la numeración. |
| `FECAESolicitar` | Solicitud del CAE. El corazón de la integración. |
| `FECompConsultar` | Recuperación idempotente tras timeout (ver §4). |
| `FEParamGetPtosVenta` | Verificación del alta del PV en Fase 0. |

### Seguridad

La función valida el JWT del llamador (`auth.getUser()`) y confirma que el usuario tenga acceso de
staff antes de usar la service-role key para el cache de tokens y el registro del CAE. La
service-role key nunca sale al browser. La tabla de auditoría tampoco se lee directamente desde el
frontend; la UI recibe sólo errores y estados necesarios para operar.

Cada ambiente usa un **proyecto Supabase distinto**, con su propia base, Edge Function y secrets. La
aplicación de homologación usa datos de prueba; producción usa los datos reales. No se cambia el
ambiente desde `config_empresa` ni desde la UI. El banner consulta el ambiente del despliegue activo.

Secrets de cada proyecto Supabase (`supabase secrets set`), nunca en el repo:

| Secret | Contenido |
|---|---|
| `ARCA_CERT` | Certificado `.crt` en base64 |
| `ARCA_KEY` | Clave privada `.key` en base64 |
| `ARCA_CUIT` | CUIT del emisor (Marblock S.A.). En homologación es el **CUIT representado**, no el CUIT personal que figura en el certificado del WSASS |
| `ARCA_AMBIENTE` | `homologacion` \| `produccion` |
| `ARCA_PUNTO_VENTA` | Punto de venta WS de ese ambiente |

`ARCA_AMBIENTE`, CUIT, PV, certificado y clave son la fuente de verdad de la Edge Function para ese
proyecto. No duplicar `arca_ambiente`, `arca_punto_venta` ni `arca_cuit` en `config_empresa`. La UI
obtiene ambiente y PV desde `GET /arca/estado`, que no devuelve secretos ni material criptográfico.

Agregar `*.key`, `*.crt`, `*.csr`, `*.pem` a `.gitignore`.

---

## 3. Modelo de datos

### Migraciones (versiones posteriores a la última migración aplicada)

Al implementar, asignar versiones mayores que la última migración del repo y de cada proyecto. El
plan no reserva timestamps antiguos: hoy la última del repo es `20261013120000_libros_iva.sql`.

| Tabla | Cambio |
|---|---|
| `facturas`, `notas` | `numero`, `punto_venta`, `numero_comp` pasan a **NULLABLE** (el borrador todavía no tiene número fiscal; Postgres admite varios `NULL`). `estado_fiscal VARCHAR(24) NOT NULL DEFAULT 'historico'` distingue `historico`, `borrador`, `en_proceso`, `resultado_incierto`, `rechazado` y `autorizado`. `arca_nro_tentativo` guarda el número consultado/enviado durante un intento. Los campos `cae`, `cae_vencimiento` y `afip_*` ya existen desde la migración `20260728120000_fiscal_afip_columns.sql`; no volver a crearlos. |
| `arca_solicitudes` (nueva) | Auditoría: `id`, `tabla`, `comprobante_id`, `request` jsonb, `response` jsonb, `resultado`, `errores` jsonb, `observaciones` jsonb, `created_at`. Un renglón por intento. Guardar sólo el payload de negocio necesario; nunca persistir `Token`, `Sign`, clave privada ni certificado. RLS deny-all para acceso directo; exponer a la UI sólo una proyección autorizada por RPC/Edge Function. |
| `arca_tokens` (nueva) | `servicio` PK, `token` text, `sign` text, `expira_en` timestamptz. **RLS deny-all.** |
| `arca_series_en_curso` (nueva) | Una fila por (PV, tipo ARCA) con el comprobante y número tentativo del único envío activo. Evita dos solicitudes concurrentes en una serie. RLS deny-all; sólo service-role/RPCs internas. Se libera tras aceptación, rechazo explícito o confirmación de no autorización; un resultado incierto conserva la serie bloqueada hasta reconciliar. |
| `clientes` | `doc_tipo SMALLINT NOT NULL` (80 CUIT / 96 DNI), `doc_nro VARCHAR(20) NOT NULL`, `condicion_iva_afip_id SMALLINT NOT NULL REFERENCES condiciones_iva_afip(id)`. `doc_tipo/doc_nro` son el documento canónico y reemplazan `cuit`; `condicion_iva_afip_id` reemplaza el texto libre `condicion_iva`. **Backfill:** `doc_nro = replace(cuit,'-','')`, `doc_tipo = 80`, y `condicion_iva_afip_id` según §3.2. Revisar a mano CUIT placeholder, documentos inválidos y condiciones IVA sin mapeo antes de exigir `NOT NULL`. Actualizar el normalizador `cli` de `frontend/src/api/index.js` y todo consumidor de `clientes.cuit` y `clientes.condicion_iva` en formularios, búsquedas, detalles, RPCs, informes y PDF (lista en §3.2); después quitar las columnas `cuit` y `condicion_iva` para mantener una sola fuente de verdad. |
| `condiciones_iva_afip` (nueva) | Catálogo RG 5616 **con la clase de comprobante** que ARCA admite para cada condición (ver §3.2). |

> **Backfill fiscal:** dejar en `autorizado` las filas históricas con CAE; las filas históricas sin
> CAE quedan en `historico`, nunca como borradores nuevos. Antes de aplicar, contar y revisar esos
> registros. Las RPCs nuevas crean explícitamente `borrador`.

### 3.1 Mapeos CRM → ARCA (`mapeo.ts`)

**Tipos de comprobante:**

| Comprobante CRM | Código ARCA |
|---|---|
| Factura A | 1 |
| Factura B | 6 |
| Nota de Débito A | 2 |
| Nota de Débito B | 7 |
| Nota de Crédito A | 3 |
| Nota de Crédito B | 8 |

**Alícuotas de IVA** — se mapean desde la tabla `alicuotas_iva` que ya existe (migración `0400`):

| `alicuotas_iva` | Destino en ARCA |
|---|---|
| `Exento (0%)` (porcentaje 0) | **`ImpOpEx`** — no entra en el array `Iva` |
| 10.5 | `Iva.Id` 4 |
| 21 | `Iva.Id` 5 |
| 27 | `Iva.Id` 6 |

> ⚠️ **El 0 % del catálogo es exento, no "IVA 0 %".** En ARCA son dos cosas distintas: `Iva.Id 3`
> declara una operación **gravada a tasa 0**, y lo exento va en `ImpOpEx`. El renglón se llama
> `Exento (0%)` y en Tango lo exento se registra en `IMPORTE_EX` (las ND exentas de §1); la tasa 0
> de Tango (`COD_ALICUO 3`, *"IVA Tasa 0"*) no la usó nunca ningún comprobante. Mandar el exento
> como `Iva.Id 3` sería declararlo mal.

El array `Iva` se arma **agrupando `factura_items` por alícuota**, sumando `BaseImp` e `Importe` por
grupo y **dejando afuera los ítems exentos**, cuya base va sumada a `ImpOpEx`. El multi-alícuota por
ítem de la migración `0400` encaja sin cambios. Ítems con `alicuota_iva_id IS NULL` liquidan 21%,
igual criterio que `crm_calc_totales_multi_alicuota`. Si el comprobante es todo exento, el array
`Iva` no se manda e `ImpIVA = 0`.

> **Cada uno de los seis códigos es una serie independiente en ARCA.** Hoy `contadores` tiene un solo
> renglón por `nota_credito` y otro por `nota_debito`, sin distinguir letra — con lo cual NC A y NC B
> compartirían numeración, que es incorrecto. Al pasar la autoridad a ARCA el problema desaparece
> solo: se pide `FECompUltimoAutorizado(PV, 3)` y `FECompUltimoAutorizado(PV, 8)` por separado. **No
> hay que agregar renglones a `contadores`**; los comprobantes fiscales dejan de leerla.

### 3.2 Condición IVA del receptor (RG 5616)

**Es obligatorio informar `CondicionIVAReceptorId`.** Hoy `clientes.condicion_iva` es texto libre
(`VARCHAR(50) DEFAULT 'Resp. Inscripto'`) y no sirve para ARCA. Catálogo **tal como lo devolvió
`FEParamGetCondicionIvaReceptor` en homologación el 15/10/2026** (clases A y B; la C y la M no aplican
a un emisor Responsable Inscripto):

| Id | Descripción (ARCA) | Clase |
|---|---|---|
| 1 | IVA Responsable Inscripto | **A** |
| 6 | Responsable Monotributo | **A** |
| 13 | Monotributista Social | **A** |
| 16 | Monotributo Trabajador Independiente Promovido | **A** |
| 4 | IVA Sujeto Exento | B |
| 5 | Consumidor Final | B |
| 7 | Sujeto No Categorizado | B |
| 8 | Proveedor del Exterior | B |
| 9 | Cliente del Exterior | B |
| 10 | IVA Liberado – Ley N° 19.640 | B |
| 15 | IVA No Alcanzado | B |

> El catálogo se siembra en la migración con estos valores (Id, descripción y `clase`) y se vuelve a
> verificar contra producción en la Fase 7. Si ARCA agregó o cambió algún Id o su clase, gana ARCA.

**La letra la decide la clase, no una regla propia.** Factura A ⇔ condición de clase A (Responsable
Inscripto **y los tres monotributos**); Factura B ⇔ clase B. A un monotributista le corresponde
Factura A, y la B no lo admite. Las NC/ND heredan la letra de la factura asociada (§3.3). Hoy la letra
se sugiere en `tipoFacturaPara` de `frontend/src/components/Forms/ComprobanteForm.jsx` (A para
`Resp. Inscripto` y `Monotributista`, B para el resto: coincide con ARCA para las cuatro opciones de
texto actuales), pero es sólo un aviso que el usuario puede ignorar. Pasa a ser una regla:

- **Servidor:** `crear_factura`, `actualizar_factura` y `arca_comprobante_para_emitir` rechazan una
  letra distinta de la clase de la condición del cliente. Es la defensa real: ARCA rechaza la
  combinación, y conviene que no llegue.
- **Frontend:** la letra se toma de `clase` (no de un texto) y deja de poder elegirse en contra.

**Mapeo del texto actual al catálogo** (backfill de Fase 2):

| `condicion_iva` hoy | Id | Revisión manual |
|---|---|---|
| `Resp. Inscripto` | 1 | — |
| `Monotributista` | 6 | confirmar si es 13 o 16 |
| `Exento` | 4 | — |
| `Consumidor Final` | 5 | ver abajo |

Tango sólo maneja `CAT_IVA` `RI` / `CF` / `EX` (`supabase/tango/etl/maestros.py`): **no tiene categoría
de monotributo**, así que ningún cliente migrado llega como monotributista aunque lo sea. En `GVA12`
hay facturas y NC **A** emitidas con `CAT_IVA = CF` (4 FAC + 10 NC) y comprobantes **B** con
`CAT_IVA = RI` (3 FAC + 1 NC). Antes de exigir `NOT NULL`, revisar a mano los clientes `Consumidor
Final` con CUIT válido cuyo último comprobante fue A (candidatos a monotributo, Id 6) y los
`Resp. Inscripto` cuyo último comprobante fue B. El ETL de Tango no cambia: carga el texto el día del
cutover y el backfill de Fase 2 lo convierte.

**Consumidores de `clientes.condicion_iva` a adaptar** (además de la letra): `api/index.js`
(normalizador `cli`), `views/Clientes` (el `<select>` de cuatro textos pasa a ser el catálogo),
`views/CtaCte`, `views/ConsultaCliente`, `views/Informes` (`index.jsx` y `exportar.js`),
`utils/excel.js`, y en el PDF `base.ts`, `templates.ts`, `reportes.ts` y `preimpreso.ts`. Las RPCs de
lectura que hoy devuelven `c.condicion_iva` (la última versión de cada una) pasan a devolver la
descripción del catálogo **con la misma clave `condicion_iva`**, más `condicion_iva_afip_id` y `clase`,
para que la pantalla no tenga que cambiar donde sólo muestra el texto.

**Fuera de alcance:** `proveedores.condicion_iva` (Compras) sigue como texto: no interviene en la
emisión ante ARCA.

### 3.3 Reglas de validación de ARCA que el sistema debe respetar

Estas son las que rebotan en producción si no se contemplan:

- **`ImpTotal = ImpTotConc + ImpNeto + ImpOpEx + ImpTrib + ImpIVA`**, con 2 decimales. Si redondea
  distinto que `crm_calc_totales`, ARCA rechaza. Los importes se toman de la factura ya calculada en
  el servidor; la Edge Function **no recalcula**, sólo mapea:
  - `ImpNeto` = base de los ítems gravados (`neto_gravado` **menos** la base exenta, porque
    `neto_gravado` del CRM suma todos los ítems, exentos incluidos);
  - `ImpOpEx` = base de los ítems `Exento (0%)`;
  - `ImpIVA` = `iva_monto`; `ImpTotConc = 0`; `ImpTrib = 0` (sin `Tributos`, §1).
  `arca_comprobante_para_emitir` entrega esas bases ya separadas, para que la función no tenga que
  replicar el redondeo de `crm_calc_totales_multi_alicuota`.
- **`percepciones_monto ≠ 0` ⇒ no se emite en esta fase.** `arca_comprobante_para_emitir` lo
  rechaza antes de llamar a ARCA y la UI muestra el motivo y el paso operativo para resolverlo. El
  sistema ya permite cargar percepciones; no asumir que siguen en cero porque el histórico de Tango
  no tenía ninguna. El mapeo a `Tributos` requiere una fase futura.
- **`CbteFch` para Concepto 1 (productos): dentro de la ventana admitida por WSFEv1.** Calcular
  la fecha actual en `America/Argentina/Buenos_Aires` para no cruzar el día por usar UTC. La regla
  vigente permite hasta 5 días anteriores o posteriores y la fecha no puede exceder el mes de
  presentación. Validar en servidor y avisar en la UI antes de emitir.
- **`CbteDesde = CbteHasta = FECompUltimoAutorizado + 1`.** Sin huecos: ARCA no autoriza saltos.
- **`Concepto = 1`** (productos) para todo lo de esta empresa.
- **`MonId = 'PES'`, `MonCotiz = 1`.**
- **Factura A exige `DocTipo = 80`** y CUIT válido del receptor.
- **`CondicionIVAReceptorId` tiene que pertenecer a la clase del comprobante** (§3.2): A con 1, 6,
  13 o 16; B con 4, 5, 7, 8, 9, 10 o 15. Se valida en el CRM antes de llamar a ARCA.
- **NC/ND exigen `CbtesAsoc`**: tipo, punto de venta, número, CUIT del emisor y fecha del comprobante
  asociado. Se derivan de `notas.factura_id`. **La letra de la nota debe coincidir con la de la
  factura** (NC A sobre Factura A).
- ARCA aplica **rate limiting**. Con el cache de token y el volumen de esta empresa no es un
  problema, pero no se debe reintentar en bucle cerrado.

---

## 4. Estados y RPCs

### Dos ejes ortogonales

`estado` sigue siendo el de **cobranza** (`pendiente`/`parcial`/`cobrada`/`anulada`), manejado por
`recalcular_estado_factura`. `estado_fiscal` es el de **ARCA**. No se mezclan: lo normal es una
factura `autorizado` + `pendiente` de cobro. Los comprobantes nuevos en `borrador`, `en_proceso`,
`resultado_incierto` o `rechazado` no afectan saldos ni informes. Los registros `historico` y
`autorizado` siguen incluidos en saldos e informes comerciales; los `historico` nunca se vuelven a
emitir desde el CRM. Los informes que muestren exclusivamente comprobantes autorizados deben filtrar
por `estado_fiscal='autorizado'` explícitamente.

```
  [carga] → borrador → en_proceso → autorizado
                              ├── rechazo explícito → rechazado → corregir + reintentar
                              └── timeout/transporte → resultado_incierto
                                                        └→ consultar ARCA → recuperar CAE o reintentar
```

### El caso difícil: timeout después de autorizar

ARCA otorga el CAE y la respuesta se pierde en el camino. Reintentar a ciegas **emite la factura dos
veces** y eso no se puede deshacer.

Protocolo de idempotencia:

1. `arca_reclamar_serie` reclama atómicamente el comprobante (`borrador` o `rechazado` →
   `en_proceso`) y la serie (PV + tipo ARCA). Sólo entonces la función consulta
   `FECompUltimoAutorizado`, guarda `último+1` con `arca_reservar_numero` y llama a
   `FECAESolicitar`. Una segunda llamada al mismo comprobante o a la misma serie no inicia otro
   envío. Si falla la consulta del último número antes de enviar, se libera la serie con seguridad.
2. Una falla al obtener token o último número ocurre antes del envío: se registra el error, se libera
   la serie y el borrador queda reintentable. Sólo un rechazo funcional explícito (`Resultado = R`)
   pasa a `rechazado`. Timeout, desconexión, error HTTP o respuesta SOAP incompleta una vez iniciado
   `FECAESolicitar` pasa a `resultado_incierto`; nunca se trata como rechazo.
3. En todo reintento de un `resultado_incierto`, consultar primero `FECompConsultar(tipo, PV,
   arca_nro_tentativo)`. Si existe y coincide en tipo, fecha, importe y documento receptor, recuperar
   y registrar el CAE. Si responde que no existe y `FECompUltimoAutorizado` sigue por debajo del
   tentativo, `arca_confirmar_no_autorizado` libera la serie y habilita un nuevo intento a pedido del usuario. Si no coincide el
   comprobante encontrado o la respuesta es inconclusa, conservar `resultado_incierto` y el bloqueo;
   nunca asociar un CAE dudoso.
4. Las RPCs de autorización/rechazo usan actualizaciones condicionales por estado. Una respuesta
   tardía no puede cambiar `autorizado` a `rechazado` ni registrar dos veces el comprobante.

### Emisiones simultáneas

`arca_series_en_curso` serializa por punto de venta y tipo ARCA, no sólo por ID de factura. Una
segunda emisión de esa serie espera hasta que la anterior se autorice o rechace. Si el resultado es
incierto, primero reconcilia ese comprobante; no inicia otro envío de la serie ni libera el bloqueo
por vencimiento de tiempo. La numeración fiscal se confirma con `FECompUltimoAutorizado`; el índice
`UNIQUE` por tipo/letra y número es una última defensa, no el mecanismo de idempotencia.

### RPCs nuevas (migración versionada después de la última aplicada)

Todas `SECURITY DEFINER SET search_path = public, pg_temp`, siguiendo el patrón de
`20260727120003_rpc_presupuestos.sql` y las reglas de `AGENTS.md`. **Sin `FORCE ROW LEVEL SECURITY`**.

| RPC | Qué hace |
|---|---|
| `arca_reclamar_serie(p_tabla, p_id)` | Reclama condicionalmente el comprobante y el único espacio de envío activo para (PV, tipo ARCA). |
| `arca_reservar_numero(p_tabla, p_id, p_nro)` | Deja constancia del número tentativo mientras el comprobante mantiene la reclamación de la serie. |
| `arca_registrar_cae(p_tabla, p_id, p_numero, p_cae, p_vto, p_afip_tipo, p_doc_tipo, p_doc_nro, p_request, p_response)` | **Atómica**: escribe número + CAE + vencimiento + campos `afip_*`, pasa `estado_fiscal='autorizado'` e inserta la fila en `arca_solicitudes`. |
| `arca_registrar_error_previo(p_tabla, p_id, p_error, p_request)` | Para errores antes de enviar `FECAESolicitar`: audita el error, vuelve a `borrador` y libera la serie. |
| `arca_registrar_rechazo(p_tabla, p_id, p_errores, p_observaciones, p_request, p_response)` | Sólo para rechazo funcional explícito. Guarda errores/observaciones y pasa a `rechazado` si sigue `en_proceso`. |
| `arca_registrar_incierto(p_tabla, p_id, p_request, p_response, p_error)` | Registra un resultado de transporte incierto sin afirmar que ARCA rechazó. Conserva el número tentativo y la serie reclamada para reconciliar. |
| `arca_confirmar_no_autorizado(p_tabla, p_id, p_request, p_response)` | Sólo tras consulta concluyente sin comprobante y con último autorizado menor al tentativo. Limpia el intento, vuelve a `borrador` y libera la serie. |
| `arca_comprobante_para_emitir(p_tabla, p_id)` | Devuelve el comprobante + cliente + ítems agrupados por alícuota, con la base exenta separada (`ImpNeto` / `ImpOpEx`, §3.3), en la forma que necesita la Edge Function. Un solo viaje. Rechaza si `percepciones_monto ≠ 0`. |
| `arca_token_get()` / `arca_token_set(...)` | Cache del ticket WSAA. Alcanzables **sólo con service-role**. |
| `arca_solicitud_ultimo(p_tabla, p_id)` | Proyección autorizada para la UI: último resultado, errores, observaciones y estado. No devuelve request/response completos ni credenciales. |

### Cambios en RPCs existentes

- **`crear_factura` / `crear_nota`**: dejan de llamar a `siguiente_numero`. Insertan como borrador,
  sin número fiscal. Las notas nuevas sólo se pueden asociar a facturas `autorizado`. Para una
  factura `historico` sin CAE local, permitir emisión sólo tras verificar por `FECompConsultar` que
  ARCA reconoce el comprobante asociado y están todos los datos de `CbtesAsoc`.
- **Efectos comerciales sólo al autorizar**: crear un borrador no lo incluye en cuenta corriente,
  saldo, informes ni métricas de facturación; tampoco marca remitos facturados ni presupuestos
  convertidos. `arca_registrar_cae` aplica esos cambios atómicamente. Para evitar dos borradores
  basados en el mismo presupuesto/remito, comprobar si ya hay otro borrador activo asociado.
- **Notas sólo ajustan saldo tras CAE**: `crear_nota` no llama a `recalcular_estado_factura`; la
  autorización de la nota bloquea la fila de factura asociada, registra CAE y recalcula el saldo en
  la misma transacción para evitar perder actualizaciones entre notas concurrentes. Para asociar
  una nota a una factura histórica sin CAE local, verificar primero que ARCA la reconoce y que hay
  datos suficientes para armar `CbtesAsoc`.
- **`actualizar_factura`**: hoy permite editar mientras `estado='pendiente'`. Pasa a permitir sólo
  `estado_fiscal IN ('borrador','rechazado')`; recalcula importes server-side y limpia el último
  rechazo y `arca_nro_tentativo` al guardar. **Una factura con CAE o en estado incierto es inmutable.**
- **`actualizar_nota`**: agregar RPC para corregir notas en `borrador` o `rechazado`; no permite
  cambios en `en_proceso`, `resultado_incierto` ni `autorizado`.
- **Descarte de borradores**: agregar `factura_borrador_descartar` y `nota_borrador_descartar`, sólo
  para `borrador` o `rechazado`. No se descartan registros `en_proceso` o `resultado_incierto`; al
  descartar se eliminan los ítems/percepciones dependientes y quedan libres presupuesto/remito.
- **`factura_anular`**: rechaza con mensaje claro si `cae IS NOT NULL` y remite a emitir una Nota de
  Crédito. **ARCA no permite anular un comprobante autorizado.**

---

## 5. Frontend

| Cambio | Detalle |
|---|---|
| **Botón "Emitir en ARCA"** | En `components/Forms/ComprobanteForm.jsx`. Estado de carga real: el viaje tarda 3–15 s y el usuario tiene que ver que algo está pasando. Deshabilitado mientras corre, para no disparar dos veces. |
| **Badge fiscal** | En `views/Facturas/` y `views/Notas/`: `Borrador` (gris), `En emisión` (azul), `Resultado incierto` (ámbar), `CAE 7512…` (verde), `Rechazado` (rojo). Componente `UI/Badge` ya existente. |
| **Panel de rechazo/resultado incierto** | Muestra códigos y mensajes de ARCA tal cual vienen. Un rechazo funcional ofrece corregir y reintentar. Un resultado incierto ofrece **Consultar estado** vía `POST /arca/reconciliar`; sólo después de confirmar que no se autorizó se habilita un nuevo envío. |
| **Bandeja fiscal** | Filtros para borradores, resultado incierto y rechazados en las listas + contadores en el Dashboard. Los inciertos se destacan porque requieren reconciliación antes de cualquier nuevo envío. |
| **Banner de ambiente** | Franja visible en la aplicación conectada al proyecto de homologación. El ambiente lo informa la función desplegada, no una preferencia editable. |
| **Formulario de clientes** | `views/Clientes/`: tipo y número de documento + selector de condición IVA con el catálogo de ARCA (§3.2, obligatorio), en lugar de los cuatro textos actuales. |
| **Letra de la factura** | `ComprobanteForm.jsx`: la letra sale de la `clase` de la condición IVA del cliente (§3.2) y no se puede elegir en contra; reemplaza a `tipoFacturaPara` y al aviso `letraDesvio`. |
| **Validación previa** | Antes de emitir: condición IVA y documento del cliente; letra igual a la clase de la condición IVA (A: Responsable Inscripto y monotributos; B: el resto, §3.2); fecha fuera de ventana; percepciones distintas de cero. Se avisa antes de llamar a ARCA. Si hay percepción, se deriva al procedimiento fiscal vigente y no se sugiere eliminarla para emitir. La Edge Function/RPC repite las validaciones críticas. |
| **`api/index.js`** | Nuevo bloque `arca`: `emitir(tabla, id)`, `reconciliar(tabla,id)`, `estado()`, `ultimoAutorizado(tipo)`, `solicitud(tabla,id)`. Invoca la Edge Function con el Bearer de la sesión. |

---

## 6. PDF

En `supabase/functions/pdf/templates.ts`, `generarFactura` (y el template de notas) suman al pie:

- **CAE** y **Fecha de vencimiento del CAE**.
- Leyenda **"Comprobante Autorizado"**.
- **Código QR obligatorio** de la RG 4892/2020: `https://www.arca.gob.ar/fe/qr/?p=<base64 del JSON>`, con
  `ver`, `fecha` (RFC3339), `cuit` (emisor), `ptoVta`, `tipoCmp`, `nroCmp`, `importe`, `moneda:'PES'`, `ctz:1`,
  `tipoDocRec`, `nroDocRec`, `tipoCodAut:'E'`, `codAut` (el CAE). Se genera con `npm:qrcode` a PNG y
  entra por `doc.image()` — `pdfkit` ya está en uso.
- En el bloque del cliente, la **descripción del catálogo** de ARCA (§3.2) en lugar del texto libre.
- **Factura A a un monotributista** (Id 6, 13 o 16): la leyenda que exige la normativa para el crédito
  fiscal del receptor monotributista (RG 5003/2021, Ley 27.618). Confirmar el texto exacto con el
  contador antes de la Fase 6; el comentario de `tipoFacturaPara` cita una versión que hay que validar.

Un borrador o comprobante rechazado sale con marca de agua **"SIN VALIDEZ FISCAL"**, sin número
fiscal ni QR. Un registro histórico sin CAE local se identifica como **"REGISTRO HISTÓRICO — SIN
CAE REGISTRADO EN EL CRM"** para no afirmar su validez fiscal ni presentarlo como una factura nueva.
El nombre del PDF usa el identificador interno mientras no exista número fiscal.

---

## 7. Fase 0 — Trámite en ARCA (fuera del código)

Nada de esto se programa: son trámites con clave fiscal. El alta de homologación bloquea las fases
1 a 6 y conviene arrancarla ya, porque la autorización del certificado y el PV pueden tardar. Los
trámites de producción habilitan sólo la Fase 7 y pueden esperar.

> Requiere **clave fiscal nivel 3** de la persona física administradora/representante y la
> representación de la CUIT de la empresa donde corresponda. En particular, WSASS se adhiere con
> clave fiscal de persona física.

### 7.1 Homologación (testing) — habilita las fases 1 a 6

> **Estado al 15/10/2026:** pasos 0 a 4 hechos. Certificado `crmmarblockhomo2` (válido hasta
> 14/10/2028) autorizado a `wsfe` con Marblock S.A. como CUIT representado; PV de homologación = **1**.
> Probado de punta a punta desde la máquina local (WSAA + WSFEv1 de sólo lectura). Proyecto Supabase
> de homologación: **Marblock Homologacion** (`jgfxmravtlckmeuzqxjg`, us-west-2), con los cinco
> secrets `ARCA_*` y un usuario de prueba (credenciales fuera del repo).

0. **Adherir el WSASS.** Es **no delegable**: en el *Administrador de Relaciones de Clave Fiscal*
   hay que entrar eligiendo la **persona física**, no Marblock S.A.; si no, el servicio no aparece.
   *Adherir servicio* → ARCA → *Servicios interactivos* → **"WSASS - Autogestión Certificados
   Homologación"**. Salir y volver a entrar para verlo.
1. Generar clave privada y CSR **localmente** (nunca subir la `.key` a ningún lado):
   ```bash
   openssl genrsa -out arca_homologacion.key 2048
   openssl req -new -key arca_homologacion.key \
     -subj "/C=AR/O=<razon social>/CN=<alias>/serialNumber=CUIT <CUIT personal sin guiones>" \
     -out arca_homologacion.csr
   ```
   - El `serialNumber` lleva el **CUIT personal** de quien está logueado en el WSASS, **no** el de
     la empresa: el formulario lo completa solo (no es editable) y tiene que coincidir con el del
     CSR. El CUIT de Marblock entra recién en el paso 3.
   - El alias **no admite guiones**. Usar el mismo valor en el `CN` (el WSASS igual arma el DN final
     como `SERIALNUMBER=CUIT <n>, CN=<alias>`).
2. WSASS → **Nuevo Certificado**: alias nuevo + pegar el CSR → *Crear DN y obtener certificado*.
   Guardar el PEM devuelto como `arca_homologacion.crt` y verificar que corresponde a la clave
   (los dos hashes tienen que ser iguales):
   ```bash
   openssl x509 -in arca_homologacion.crt -pubkey -noout | openssl sha256
   openssl rsa -in arca_homologacion.key -pubout | openssl sha256
   ```
   Los certificados creados **no se pueden borrar**. Si devuelve `Error creando computador`, mirar
   si el alias quedó creado en el desplegable de *Agregar Certificado a Alias* (ese formulario
   ignora el DN del CSR); si no, reintentar con un alias nuevo. Soporte de homologación:
   `webservices-desa@afip.gob.ar` (el que figura en el manual del WSASS).
3. WSASS → **Crear Autorización a Servicio**: el alias del paso 2, **CUIT representado = CUIT de
   Marblock S.A.**, servicio **`wsfe`**. Confirmar que aparece en *Autorizaciones*.
4. ✅ **Punto de venta: 1.** En homologación `FEParamGetPtosVenta` responde `602 — Sin Resultados`
   (no hay PV dados de alta y es normal); el PV 1 se usa igual: `FECompUltimoAutorizado(PV 1)` con
   `Auth.Cuit` = Marblock devolvió 0 para Factura A y B el 15/10/2026, lo que confirma además que la
   representación del paso 3 funciona. `ARCA_PUNTO_VENTA = 1` en el proyecto de homologación. El
   proyecto Supabase de homologación y su base son separados del proyecto de producción.
   - **El TA (token + sign) dura 12 h y WSAA no da otro mientras esté vigente**, también para las
     pruebas locales: el de la prueba del 15/10 quedó en `~/.arca/marblock/ta_wsfe_homologacion.xml`
     (`600`) y venció a las 19:53 de ese día.

### 7.2 Producción — habilita la Fase 7

1. Generar **otra** clave privada y CSR, distintos de los de homologación:
   ```bash
   openssl genrsa -out arca_prod.key 2048
   openssl req -new -key arca_prod.key \
     -subj "/C=AR/O=<razon social>/CN=crm-marblock/serialNumber=CUIT <cuit sin guiones>" \
     -out arca_prod.csr
   ```
2. Con clave fiscal → **Administración de Certificados Digitales**: crear un alias (Computador
   Fiscal), subir el CSR, descargar el certificado.
3. → **Administrador de Relaciones de Clave Fiscal** → *Nueva Relación* → servicio
   **Facturación Electrónica / `wsfe`** (Webservices) → representante: el certificado del paso 2.
   Sin este paso el certificado autentica pero no puede facturar.
4. → **Administración de Puntos de Venta y Domicilios** → *Alta de punto de venta* → Sistema:
   **"RECE para aplicativo y web services"**. **Anotar el número** (p. ej. `00003`) — va en el
   secret `ARCA_PUNTO_VENTA` del proyecto de producción.
5. Verificar con `FEDummy` y `FEParamGetPtosVenta` que el PV aparece y está habilitado.

> **Endpoints:** usar los publicados en la documentación oficial vigente, sin sustituir
> automáticamente dominios `afip.gov.ar` por `arca.gob.ar`. A la fecha de esta revisión el manual
> WSFEv1 v4.8 publica `wswhomo.afip.gov.ar/wsfev1/service.asmx` y
> `servicios1.afip.gov.ar/wsfev1/service.asmx`; WSAA publica `wsaahomo.afip.gov.ar/ws/services/LoginCms`
> y `wsaa.afip.gov.ar/ws/services/LoginCms`.

**Entregable de la fase:** archivos de clave/certificado fuera del repo, creados por ambiente
(`~/.arca/marblock/arca_homologacion.key/.crt`, carpeta con permisos `700`; los de producción,
`arca_prod.key/.crt`), y los PV de homologación y producción anotados.

---

## 8. Fases de implementación

### Fase 1 — Spike: firma CMS en Deno *(bloqueante para elegir el backend)*

**Objetivo:** despejar el riesgo técnico inicial. Firmar el TRA en CMS/PKCS#7 desde una Edge
Function y obtener un token de WSAA homologación.

**Entregable:** `wsaa.ts` funcional (el spike se conserva si sale bien) + una ruta temporal
`GET /arca/estado` que devuelva el `FEDummy`.

**Verificación:** desplegar la función y obtener `token`/`sign` reales de homologación. `FEDummy`
respondiendo `AppServer/DbServer/AuthServer = OK`.

**Si falla:** detener las fases siguientes y evaluar un backend Node para WSAA/WSFE. Mantener el
contrato de emisión que consume el frontend; ajustar el despliegue, secretos y endpoint del servidor
antes de continuar.

**Resultado (15/10/2026): ✅ sale en Deno, se sigue con Edge Functions.** Función `arca` desplegada
en el proyecto de homologación con `soap.ts`, `wsaa.ts`, `wsfe.ts` e `index.ts`:

- `GET /arca/estado` → `FEDummy` OK y TA nuevo de WSAA en 3 s, firmado con `npm:node-forge@1.4.0`
  (antes, la misma firma se verificó en local con `openssl cms -verify`).
- La función se despliega con `verify_jwt: false` porque valida la sesión ella misma con
  `auth.getUser()`: sin sesión, con un token inventado o con la anon key como sesión → **401**.
- **El cache en memoria no alcanza.** Una segunda llamada cayó en otro isolate, sin el TA, y WSAA
  respondió `coe.alreadyAuthenticated`: hasta que venció, ese proyecto no pudo autenticarse. El cache en
  `arca_tokens` (Fase 2) va antes que cualquier emisión. WSAA no siempre rechaza el segundo pedido
  (esa mañana entregó dos TA seguidos a pedidos locales), así que no hay que contar con ninguno de los
  dos comportamientos.
- TLS: los cuatro hosts de ARCA aceptan TLS 1.2 con ECDHE y certificados Sectigo, que es lo que usa
  Deno. `servicios1.afip.gov.ar` (WSFE de producción) además ofrece DHE con una clave chica, y OpenSSL
  3 por defecto corta con `dh key too small`: si algún día se usa el plan B en Node, hay que forzar
  cifrados ECDHE.

---

### Fase 2 — Schema y catálogos

**Entregables:** migración de esquema (§3) + migración de RPCs (§4), con versiones mayores que la
última migración aplicada en ambos proyectos; RLS en las tablas nuevas y `arca_tokens` en deny-all.

**Verificación:** aplicar las migraciones al proyecto de homologación y preparar allí datos sintéticos
(no clonar clientes ni comprobantes reales); aplicar los mismos cambios al proyecto de producción
antes del go-live. Los borradores se pueden insertar sin número; `SELECT` directo a `arca_tokens`,
`arca_solicitudes` y `arca_series_en_curso` como `authenticated` **debe fallar**.

**Riesgo:** el backfill de `clientes.condicion_iva_afip_id` desde texto libre. Revisar a mano los que
queden en NULL antes de seguir — sin condición IVA no se puede emitir. Y como Tango no tiene
categoría de monotributo, revisar los candidatos que marca §3.2 (`Consumidor Final` con CUIT y
último comprobante A): si quedan como Id 5, el sistema les va a exigir Factura B y ARCA la rechaza.

---

### Fase 3 — Emisión de Factura A/B en homologación *(el corazón)*

**Entregables:** `wsfe.ts`, `mapeo.ts`, `index.ts` con `POST /arca/emitir`; `crear_factura`
convertido a borrador.

**Verificación (en homologación, contra el PV de testing):**
- Factura A a un CUIT válido, un solo ítem al 21% → CAE + vencimiento.
- Factura B a un receptor con DNI (`DocTipo 96`).
- **Factura A a un monotributista** (`CondicionIVAReceptorId` 6) → CAE. **Factura B a un
  monotributista** o **Factura A a un consumidor final** → bloqueada en el CRM, sin llamar a ARCA.
- Factura con **dos alícuotas** (21% y 10.5%) → array `Iva` con dos entradas, `ImpIVA` cuadrando.
- Factura con descuento general → `ImpNeto` coincidiendo con `neto_gravado` de la BD.
- Factura con un ítem `Exento (0%)` y otro al 21 % → el exento va a `ImpOpEx`, `ImpNeto` es sólo la
  base gravada y el array `Iva` tiene **una** entrada (Id 5), no dos.
- Comprobante con `percepciones_monto ≠ 0` (forzado en la base) → **rechazado en el CRM**, sin
  llamar a ARCA.
- Los números salen **consecutivos** y coinciden con `FECompUltimoAutorizado`.
- **Validación local de fecha fuera de ventana** → bloqueada antes de llamar a ARCA. Además,
  provocar un rechazo funcional controlado en homologación → queda `rechazado` con el error legible
  de ARCA en `arca_solicitudes`.
- **Recuperación por timeout**: simular en homologación una respuesta perdida tras autorizar;
  `POST /arca/reconciliar` debe recuperar el CAE por `FECompConsultar` y no volver a emitir.
  Simular también una solicitud no autorizada y verificar que la serie se libera sólo cuando ARCA
  confirma que el número no fue autorizado.
- Crear factura/notas en borrador no altera saldo, cuenta corriente, informes, remito ni presupuesto;
  al autorizar, cada efecto se aplica una sola vez. Dos emisiones concurrentes de una misma serie
  quedan serializadas y el resultado incierto bloquea nuevos envíos hasta reconciliar.
- El catálogo sembrado coincide con `FEParamGetCondicionIvaReceptor` (ya consultado en
  homologación el 15/10/2026, §3.2; repetir si pasó tiempo).

---

### Fase 4 — Notas de Crédito y Débito

**Entregables:** `crear_nota` convertida a borrador sólo sobre una factura autorizada; `CbtesAsoc`
armado desde `notas.factura_id`; validación de coincidencia de letra. El saldo no cambia hasta el
CAE de la nota.

**Verificación:** NC A sobre una Factura A emitida en Fase 3 → CAE propio; el saldo no cambia al
crear el borrador y se recalcula al autorizar por `recalcular_estado_factura`. Intentar NC B sobre Factura A → debe
rechazarse **en el CRM**, antes de llegar a ARCA. **ND A totalmente exenta** (el caso real más común
de exento en Tango, §1) → `ImpOpEx` = total, `ImpNeto = 0`, sin array `Iva`, y CAE otorgado.

---

### Fase 5 — UI y ciclo de reintento

**Entregables:** todo lo de §5.

**Verificación:** emitir, ver el badge en verde con el CAE; forzar un rechazo y ver el panel de error
con el mensaje de ARCA; simular resultado incierto y reconciliar antes de reenviar; corregir y
reintentar hasta autorizar; confirmar que una factura autorizada **no se puede editar ni anular**
desde la UI; ver el banner de homologación y el bloqueo visible por percepciones.

---

### Fase 6 — PDF fiscal

**Entregables:** bloque CAE + QR en `templates.ts`; marca de agua en borradores.

**Verificación:** **escanear el QR del PDF con el celular** y confirmar que la página de ARCA muestra
el comprobante correcto. Es la única verificación que vale — un QR que se genera sin error pero
codifica mal los datos se ve idéntico.

---

### Fase 7 — Producción y go-live

1. Cargar los secrets de producción (`ARCA_CERT`, `ARCA_KEY`, `ARCA_CUIT`, `ARCA_AMBIENTE` y
   `ARCA_PUNTO_VENTA`, §7.2) en el proyecto Supabase de producción.
2. Confirmar que frontend de producción apunta al proyecto/base y Edge Function de producción.
3. Confirmar `FEDummy` y `FEParamGetPtosVenta` contra producción.
4. **Emitir una primera factura real, chica, a un cliente conocido.** Verificar en *Mis Comprobantes*
   de ARCA que figura, y contrastar importes.
5. Recién con eso OK: **dejar de cargar facturas en la web de ARCA**. Fin de la doble carga.
6. Vigilar las bandejas de borradores y resultados inciertos la primera semana.

**Contingencia:** detener nuevas solicitudes del CRM y volver temporalmente a emitir por la web de
ARCA en el PV `00002`. Registrar en el CRM los datos exactos (número, PV, tipo, CAE y vencimiento)
como comprobantes autorizados mediante un procedimiento administrativo controlado; no volver a
asignarles números usando `contadores`. Los comprobantes ya autorizados por el PV nuevo permanecen
vigentes y nunca se borran ni se retroceden.

---

## 9. Estado de las fases

| Fase | Estado |
|---|---|
| 0 — Trámite ARCA (homologación) | ✅ 15/10/2026 — certificado, autorización `wsfe`, PV 1 y proyecto Supabase de homologación |
| 0 — Trámite ARCA (producción) | ⬜ pendiente |
| 1 — Spike firma CMS | ✅ 15/10/2026 — `GET /arca/estado` desplegado en homologación: FEDummy OK y TA real de WSAA |
| 2 — Schema y catálogos | ⬜ pendiente |
| 3 — Emisión Factura A/B | ⬜ pendiente |
| 4 — NC/ND | ⬜ pendiente |
| 5 — UI y reintento | ⬜ pendiente |
| 6 — PDF fiscal | ⬜ pendiente |
| 7 — Producción y go-live | ⬜ pendiente |

---

## 10. Riesgos

| Riesgo | Mitigación |
|---|---|
| **La firma CMS no sale en Deno** | ✅ Descartado en la Fase 1 (15/10/2026): firma con `node-forge` aceptada por WSAA desde la Edge Function. |
| **Doble emisión por timeout** | Protocolo de idempotencia con `arca_nro_tentativo` + `FECompConsultar` (§4). Se prueba explícitamente en Fase 3. |
| **Emitir en producción creyendo que es homologación** | Proyecto Supabase, datos y certificados separados; banner de solo lectura que informa el ambiente desplegado. |
| **Cliente sin condición IVA cargada** | Validación previa en el cliente + revisión del backfill en Fase 2. |
| **Letra que no corresponde a la condición del receptor** (p. ej. Factura B a un monotributista) | La letra sale de la `clase` del catálogo de ARCA (§3.2) y las RPCs la validan en el servidor. Revisión manual de los monotributistas que Tango no distingue (Fase 2). |
| **Exento declarado como IVA 0 %** | El renglón `Exento (0%)` va a `ImpOpEx`, nunca a `Iva.Id 3` (§3.1). Se prueba con la ND exenta de la Fase 4. |
| **Percepciones cargadas en un comprobante** | El CRM actual permite cargarlas; la UI y `arca_comprobante_para_emitir` explican y bloquean la emisión cuando `percepciones_monto ≠ 0` hasta implementar su mapeo. |
| **Certificado vencido** (duran ~2 años) | Anotar la fecha de vencimiento en `PLAN_MAESTRO.md` §3.7, junto al CAI del talonario de remitos. Sin certificado no se factura. |
| **El proyecto Supabase se pausa por inactividad** | Riesgo ya conocido (`PLAN_MAESTRO.md` §3.7). Con facturación fiscal encima, deja de ser tolerable: **resolver plan pago o ping programado antes de la Fase 7.** |
| **ARCA caído o timeout** | Borrador recuperable; la bandeja de resultados inciertos reconcilia primero y conserva bloqueada la serie hasta conocer el resultado. |
| **No hay tooling de tests en el repo** | La verificación es manual y contra homologación, fase por fase, con los checks listados. Homologación es el entorno de test: no hace falta inventar mocks. |

---

## 11. Referencias

- `AGENTS.md` — reglas de implementación del repo; las RPCs de referencia documentan el patrón
  `SECURITY DEFINER`, RLS y cálculo server-side.
- `PLAN_MAESTRO.md` §3.7 — riesgos operativos con fecha (agregar acá el vencimiento del certificado).
- `supabase/migrations/20260727120003_rpc_presupuestos.sql` — patrón de referencia para las RPCs.
- `supabase/migrations/20260728120000_fiscal_afip_columns.sql` — columnas fiscales ya existentes.
- `supabase/migrations/20260802120000_ventas_multialicuota_schema.sql` — catálogo `alicuotas_iva`
  (el renglón de 0 % es `Exento (0%)`).
- `supabase/migrations/20260821140000_ventas_percepciones.sql` — tabla `percepciones` y
  `percepciones_monto`: existen pero Tango no tiene datos para ellas (§1).
- `PLAN_MIGRACION_TANGO.md` §1 — cómo se lee el `.bak` del que salen los datos de §1.
- `supabase/functions/pdf/index.ts` — patrón de Edge Function con JWT del usuario.
- [Manual oficial WSFEv1 v4.8, incluidas adecuaciones RG 5616](https://www.arca.gob.ar/fe/ayuda/documentos/wsfev1-RG-4291.pdf) — campos, validaciones y endpoints (§3, §7).
- [Documentación oficial WSAA](https://arca.gob.ar/ws/documentacion/wsaa.asp) — certificados, asociación al servicio y endpoints (§7).
- [Especificación oficial QR](https://arca.gob.ar/fe/qr/documentos/QRespecificaciones.pdf) — URL y campos del QR (§6).
- [Habilitación de puntos de venta ARCA](https://www.arca.gob.ar/derechos-de-exportacion-de-servicios/comprobantes-y-facturacion/puntos-de-venta.asp) — PV diferentes para Comprobantes en línea y Web Services (§1, §7).
