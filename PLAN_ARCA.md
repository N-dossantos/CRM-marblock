# PLAN_ARCA.md — Facturación electrónica ARCA (ex AFIP) en el CRM

> **Objetivo único:** que la factura de venta se emita **una sola vez, desde el sistema**, y que el
> CAE lo pida el CRM contra los web services de ARCA. Hoy la factura se carga dos veces —primero en
> la web de ARCA, después en el CRM para mantener numeración y relación— y esa doble carga es
> exactamente lo que este plan elimina.
>
> Fecha del diseño: **2026-08-21**. Ajustado el **2026-10-06** con los datos reales de Tango
> (`MARBLOCK_SA.bak` del 25/09): percepciones y operaciones exentas (§1, §3.1, §3.3). Documento vivo:
> al cerrar cada fase, marcar su estado en §9.

---

## 1. Decisiones tomadas

| Decisión | Valor | Por qué |
|---|---|---|
| **Comprobantes en alcance** | Factura A, Factura B, Nota de Crédito A/B, Nota de Débito A/B | Es todo lo que hoy se emite a mano en la web de ARCA. Las NC/ND llevan **CAE propio**, no heredan el de la factura. |
| **Enfoque de integración** | Edge Function propia en Deno, directo contra **WSAA + WSFEv1** | Un solo backend (mismo modelo que `functions/pdf`), costo cero, sin terceros viendo CUIT/importes, sin dependencia externa para una función legalmente crítica. |
| **Punto de venta** | **PV nuevo**, dedicado a web services, numeración desde 1 | ARCA no permite usar por WS un PV dado de alta como *Comprobantes en línea*. El `00002` actual queda como histórico, intacto. |
| **Flujo de emisión** | Un botón, con **borrador de rescate** | Camino feliz: un clic → factura con CAE. Si ARCA falla o rechaza, queda borrador sin número fiscal, con el error visible y botón Reintentar. No se pierde la carga ni se quema un número. |
| **Autoridad de la numeración** | **ARCA**, vía `FECompUltimoAutorizado` | Los comprobantes fiscales **dejan de usar `contadores`**. Elimina la deriva por diseño. `contadores` sigue sirviendo a presupuesto, remito y recibo, que no son fiscales. |
| **Tributos** | Sólo IVA | No se aplican percepciones. El array `Tributos` de la solicitud va vacío y el modelo actual (subtotal → descuento → neto → IVA → total) sirve tal cual. **Confirmado con el `.bak`** (ver abajo). |
| **Operaciones exentas** | Van a `ImpOpEx`, no al array `Iva` | En Tango hay comprobantes con importe exento: el renglón `Exento (0%)` de `alicuotas_iva` es **exento**, no "gravado al 0 %" (ver §3.1). |

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
- La tabla `percepciones` y `facturas/notas.percepciones_monto` **ya existen** en la base (migración
  `20260821140000`), pero el frontend no las carga y quedan en 0. La emisión las trata como un caso
  que no debería ocurrir: si un comprobante trae `percepciones_monto ≠ 0`, se rechaza **en el CRM**,
  antes de llamar a ARCA (§3.3).
| **Receptores de Factura B** | Clientes con CUIT + consumidor final **con DNI** | No hay venta de mostrador anónima ⇒ no hace falta el flujo `DocTipo 99 / DocNro 0`. |

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
                                                    │ 2. FECompUltimoAutorizado(PV, tipo)        │
                                                    │ 3. arca_reservar_numero(id, último+1)      │
                                                    │ 4. FECAESolicitar                          │
                                                    └─────────────────────┬──────────────────────┘
                                                                          ▼
                                                     RPC arca_registrar_cae / arca_registrar_rechazo
                                                     → número + CAE + vto + fila de auditoría
```

### Estructura de archivos

```
supabase/functions/arca/
  index.ts     router: POST /arca/emitir, GET /arca/estado (FEDummy), GET /arca/ultimo
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

La función valida el JWT del llamador con el cliente anon (`auth.getUser()`) — mismo patrón que
`functions/pdf` — y **recién entonces** usa la service-role key para el cache de tokens y el
registro del CAE. La service-role key nunca sale al browser.

Secrets de Supabase (`supabase secrets set`), nunca en el repo:

| Secret | Contenido |
|---|---|
| `ARCA_CERT` | Certificado `.crt` en base64 |
| `ARCA_KEY` | Clave privada `.key` en base64 |
| `ARCA_CUIT` | CUIT del emisor |
| `ARCA_AMBIENTE` | `homologacion` \| `produccion` |

Agregar `*.key`, `*.crt`, `*.csr`, `*.pem` a `.gitignore`.

---

## 3. Modelo de datos

### Migración `20260821120000_arca_schema.sql`

| Tabla | Cambio |
|---|---|
| `facturas`, `notas` | `numero`, `punto_venta`, `numero_comp` pasan a **NULLABLE** (el borrador todavía no tiene número fiscal; el `UNIQUE` sigue valiendo — Postgres admite varios NULL). Nueva `estado_fiscal VARCHAR(12) NOT NULL DEFAULT 'borrador'` CHECK `('borrador','autorizado','rechazado')`. Nueva `arca_nro_tentativo INTEGER`. Se estrenan `cae`, `cae_vencimiento`, `afip_tipo_comprobante`, `afip_doc_tipo`, `afip_doc_nro`, que ya existen desde la migración `0013` (import de Tango). |
| `arca_solicitudes` (nueva) | Auditoría: `id`, `tabla`, `comprobante_id`, `request` jsonb, `response` jsonb, `resultado` CHAR(1), `errores` jsonb, `observaciones` jsonb, `created_at`. Un renglón por intento. Mantiene la factura limpia y da diagnóstico cuando ARCA rechaza. |
| `arca_tokens` (nueva) | `servicio` PK, `token` text, `sign` text, `expira_en` timestamptz. **RLS deny-all.** |
| `clientes` | `doc_tipo SMALLINT NOT NULL DEFAULT 80` (80 CUIT / 96 DNI), `doc_nro VARCHAR(20)`, `condicion_iva_afip_id SMALLINT REFERENCES condiciones_iva_afip(id)`. `cuit` deja de ser `NOT NULL` (los clientes con DNI no tienen). **Backfill:** `doc_nro = replace(cuit,'-','')`, `doc_tipo = 80`, y `condicion_iva_afip_id` derivado del texto libre de `condicion_iva`. |
| `condiciones_iva_afip` (nueva) | Catálogo RG 5616 (ver §3.2). |
| `config_empresa` | Claves nuevas: `arca_ambiente`, `arca_punto_venta`, `arca_cuit`. |

> **Nota sobre `estado_fiscal` y las facturas históricas de Tango**: las importadas ya traen CAE. El
> backfill debe dejarlas en `estado_fiscal='autorizado'` (`UPDATE ... WHERE cae IS NOT NULL`) para que
> no aparezcan como borradores en la bandeja.

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
(`VARCHAR(50) DEFAULT 'Resp. Inscripto'`) y no sirve para ARCA. Catálogo:

| Id | Descripción |
|---|---|
| 1 | IVA Responsable Inscripto |
| 4 | IVA Sujeto Exento |
| 5 | Consumidor Final |
| 6 | Responsable Monotributo |
| 7 | Sujeto No Categorizado |
| 9 | Cliente del Exterior |
| 10 | IVA Liberado – Ley 19.640 |
| 13 | Monotributista Social |
| 15 | IVA No Alcanzado |
| 16 | Monotributo Trabajador Independiente Promovido |

> El catálogo se siembra en la migración con estos valores y se **verifica contra
> `FEParamGetCondicionIvaReceptor`** en la Fase 3. Si ARCA agregó o cambió algún Id, gana ARCA.

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
- **`percepciones_monto ≠ 0` ⇒ no se emite.** Si llegara a haber percepciones cargadas, `ImpTotal`
  no cerraría sin `Tributos`. `arca_comprobante_para_emitir` lo rechaza con un mensaje claro, antes
  de llamar a ARCA.
- **`CbteFch` (yyyymmdd) para Concepto 1 (productos): dentro de ±5 días corridos de hoy.** No se
  puede backdatear una factura de la semana pasada. La UI debe avisarlo antes de emitir.
- **`CbteDesde = CbteHasta = FECompUltimoAutorizado + 1`.** Sin huecos: ARCA no autoriza saltos.
- **`Concepto = 1`** (productos) para todo lo de esta empresa.
- **`MonId = 'PES'`, `MonCotiz = 1`.**
- **Factura A exige `DocTipo = 80`** y CUIT válido del receptor.
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
factura `autorizado` + `pendiente` de cobro.

```
  [carga]  ──crear_factura──▶  borrador  ──FECAESolicitar──▶  autorizado ✓
                              (sin número)      │
                                    ▲           └── Resultado R ──▶ rechazado
                                    │                                   │
                                    └────────── corregir + reintentar ───┘
```

### El caso difícil: timeout después de autorizar

ARCA otorga el CAE y la respuesta se pierde en el camino. Reintentar a ciegas **emite la factura dos
veces** y eso no se puede deshacer.

Protocolo de idempotencia:

1. Antes de `FECAESolicitar`, el borrador guarda el número tentativo vía `arca_reservar_numero`.
2. En un reintento, la función hace primero `FECompConsultar(tipo, PV, arca_nro_tentativo)`.
3. Si ARCA responde que **ese comprobante existe** y coincide en `ImpTotal` y documento del receptor
   → **recupera el CAE** en lugar de re-emitir.
4. Si no existe → recién ahí vuelve a solicitar (recalculando `último + 1`, que puede haber cambiado).

### Carrera entre dos emisiones simultáneas

Se resuelve sola: ambas piden el mismo número, ARCA autoriza una y **rechaza la otra**; la rechazada
queda en borrador y el reintento toma el número correcto. No hace falta lock distribuido. El `UNIQUE`
sobre `numero` es la red de seguridad final.

### RPCs nuevas (`20260821120001_rpc_arca.sql`)

Todas `SECURITY DEFINER SET search_path = public, pg_temp`, siguiendo el patrón de
`20260727120003_rpc_presupuestos.sql`. **Sin `FORCE ROW LEVEL SECURITY`** (ver `CLAUDE.md`).

| RPC | Qué hace |
|---|---|
| `arca_reservar_numero(p_tabla, p_id, p_nro)` | Deja constancia del número tentativo antes de llamar a ARCA. |
| `arca_registrar_cae(p_tabla, p_id, p_numero, p_cae, p_vto, p_afip_tipo, p_doc_tipo, p_doc_nro, p_request, p_response)` | **Atómica**: escribe número + CAE + vencimiento + campos `afip_*`, pasa `estado_fiscal='autorizado'` e inserta la fila en `arca_solicitudes`. |
| `arca_registrar_rechazo(p_tabla, p_id, p_errores, p_observaciones, p_request, p_response)` | Guarda errores/observaciones, pasa a `rechazado`, inserta auditoría. |
| `arca_comprobante_para_emitir(p_tabla, p_id)` | Devuelve el comprobante + cliente + ítems agrupados por alícuota, con la base exenta separada (`ImpNeto` / `ImpOpEx`, §3.3), en la forma que necesita la Edge Function. Un solo viaje. Rechaza si `percepciones_monto ≠ 0`. |
| `arca_token_get()` / `arca_token_set(...)` | Cache del ticket WSAA. Alcanzables **sólo con service-role**. |

### Cambios en RPCs existentes

- **`crear_factura` / `crear_nota`**: dejan de llamar a `siguiente_numero`. Insertan como borrador,
  sin número, `estado_fiscal='borrador'`.
- **`actualizar_factura`**: hoy permite editar mientras `estado='pendiente'`. Pasa a exigir
  `estado_fiscal='borrador'`. **Una factura con CAE es inmutable.**
- **`factura_anular`**: rechaza con mensaje claro si `cae IS NOT NULL` y remite a emitir una Nota de
  Crédito. **ARCA no permite anular un comprobante autorizado.** Los borradores sí se borran.

---

## 5. Frontend

| Cambio | Detalle |
|---|---|
| **Botón "Emitir en ARCA"** | En `components/Forms/ComprobanteForm.jsx`. Estado de carga real: el viaje tarda 3–15 s y el usuario tiene que ver que algo está pasando. Deshabilitado mientras corre, para no disparar dos veces. |
| **Badge fiscal** | En `views/Facturas/` y `views/Notas/`: `Borrador` (gris), `CAE 7512…` (verde), `Rechazado` (rojo). Componente `UI/Badge` ya existente. |
| **Panel de rechazo** | Muestra códigos y mensajes de ARCA **tal cual vienen**. Son crípticos pero son la única pista para corregir; traducirlos a "hubo un error" sería inutilizarlos. Al lado, botón **Reintentar**. |
| **Bandeja de borradores** | Filtro `estado_fiscal='borrador'` en la lista + contador en el Dashboard. Es lo que evita que una venta quede sin facturar porque ARCA estaba caída un martes. |
| **Banner de ambiente** | Franja visible mientras `arca_ambiente='homologacion'`. Confundir una prueba con una factura real es el error caro de esta integración. |
| **Formulario de clientes** | `views/Clientes/`: tipo y número de documento + selector de condición IVA de ARCA (obligatorio). |
| **Validación previa** | Antes de emitir, en el cliente: cliente sin condición IVA cargada; Factura A a un receptor que no es Responsable Inscripto; fecha fuera de la ventana de ±5 días. Se avisa **antes** de gastar el viaje a ARCA. |
| **`api/index.js`** | Nuevo bloque `arca`: `emitir(tabla, id)`, `estado()`, `ultimoAutorizado(tipo)`. Invoca la Edge Function con el Bearer de la sesión, igual que `PDFModal`. |

---

## 6. PDF

En `supabase/functions/pdf/templates.ts`, `generarFactura` (y el template de notas) suman al pie:

- **CAE** y **Fecha de vencimiento del CAE**.
- Leyenda **"Comprobante Autorizado"**.
- **Código QR** de la RG 4892/2020: `https://www.afip.gob.ar/fe/qr/?p=<base64 del JSON>`, con
  `ver`, `fecha`, `cuit` (emisor), `ptoVta`, `tipoCmp`, `nroCmp`, `importe`, `moneda:'PES'`, `ctz:1`,
  `tipoDocRec`, `nroDocRec`, `tipoCodAut:'E'`, `codAut` (el CAE). Se genera con `npm:qrcode` a PNG y
  entra por `doc.image()` — `pdfkit` ya está en uso.

Y algo que no es cosmético: **un borrador sin CAE sale con marca de agua "SIN VALIDEZ FISCAL"**
cruzada sobre la hoja. Un PDF de borrador que se vea igual que una factura autorizada es un problema
esperando a pasar.

---

## 7. Fase 0 — Trámite en ARCA (fuera del código)

Nada de esto se programa: son trámites con clave fiscal. **Bloquean todas las demás fases** y
conviene arrancarlos ya, porque el alta del punto de venta puede tardar.

> Requiere **clave fiscal nivel 3** del CUIT de la empresa.

### 7.1 Homologación (testing) — habilita las fases 1 a 6

1. Generar clave privada y CSR **localmente** (nunca subir la `.key` a ningún lado):
   ```bash
   openssl genrsa -out arca_homo.key 2048
   openssl req -new -key arca_homo.key \
     -subj "/C=AR/O=<razon social>/CN=crm-marblock-homo/serialNumber=CUIT <cuit sin guiones>" \
     -out arca_homo.csr
   ```
2. Entrar al **WSASS** (autogestión de certificados de homologación) con clave fiscal, crear un
   certificado pegando el CSR, y descargar el `.crt`.
3. En el mismo WSASS, **autorizar el certificado al servicio `wsfe`**.
4. Homologación trae puntos de venta ficticios ya creados (típicamente 1 y 2). Confirmar cuál usar
   con `FEParamGetPtosVenta`.

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
   **"RECE para aplicativo y web services"**. **Anotar el número** (p. ej. `00003`) — es el que va en
   `config_empresa.arca_punto_venta`.
5. Verificar con `FEDummy` y `FEParamGetPtosVenta` que el PV aparece y está habilitado.

> ⚠️ **Verificar los endpoints al implementar.** ARCA viene migrando dominios de `afip.gov.ar` a
> `arca.gob.ar`. Los históricos son `wsaahomo.afip.gov.ar/ws/services/LoginCms` y
> `wswhomo.afip.gov.ar/wsfev1/service.asmx` (homologación),
> `wsaa.afip.gov.ar/ws/services/LoginCms` y `servicios1.afip.gov.ar/wsfev1/service.asmx`
> (producción). Confirmar los vigentes contra la documentación oficial antes de codear `wsfe.ts`.

**Entregable de la fase:** cuatro archivos fuera del repo (`arca_homo.key/.crt`,
`arca_prod.key/.crt`) y el número de PV de producción anotado.

---

## 8. Fases de implementación

### Fase 1 — Spike: firma CMS en Deno *(bloqueante, sin ella el enfoque A no va)*

**Objetivo:** despejar el único riesgo técnico real. Firmar el TRA en CMS/PKCS#7 desde una Edge
Function y obtener un token de WSAA homologación.

**Entregable:** `wsaa.ts` funcional (el spike se conserva si sale bien) + una ruta temporal
`GET /arca/estado` que devuelva el `FEDummy`.

**Verificación:** desplegar la función y obtener `token`/`sign` reales de homologación. `FEDummy`
respondiendo `AppServer/DbServer/AuthServer = OK`.

**Si falla:** el plan B es la opción C del brainstorm — mover **sólo** `wsaa.ts` + `wsfe.ts` a una
función Node en Vercel con `node-forge`/`afip.ts`. La interfaz HTTP de `/arca/emitir` no cambia, así
que ninguna otra fase se rehace.

---

### Fase 2 — Schema y catálogos

**Entregables:** `20260821120000_arca_schema.sql` (§3) + `20260821120001_rpc_arca.sql` (§4), con RLS
para las tablas nuevas y `arca_tokens` en deny-all.

**Verificación:** aplicar por MCP; `mcp__supabase__get_advisors` sin hallazgos nuevos; los borradores
se pueden insertar sin número; `SELECT` a `arca_tokens` como `authenticated` **debe fallar**.

**Riesgo:** el backfill de `clientes.condicion_iva_afip_id` desde texto libre. Revisar a mano los que
queden en NULL antes de seguir — sin condición IVA no se puede emitir.

---

### Fase 3 — Emisión de Factura A/B en homologación *(el corazón)*

**Entregables:** `wsfe.ts`, `mapeo.ts`, `index.ts` con `POST /arca/emitir`; `crear_factura`
convertido a borrador.

**Verificación (en homologación, contra el PV de testing):**
- Factura A a un CUIT válido, un solo ítem al 21% → CAE + vencimiento.
- Factura B a un receptor con DNI (`DocTipo 96`).
- Factura con **dos alícuotas** (21% y 10.5%) → array `Iva` con dos entradas, `ImpIVA` cuadrando.
- Factura con descuento general → `ImpNeto` coincidiendo con `neto_gravado` de la BD.
- Factura con un ítem `Exento (0%)` y otro al 21 % → el exento va a `ImpOpEx`, `ImpNeto` es sólo la
  base gravada y el array `Iva` tiene **una** entrada (Id 5), no dos.
- Comprobante con `percepciones_monto ≠ 0` (forzado en la base) → **rechazado en el CRM**, sin
  llamar a ARCA.
- Los números salen **consecutivos** y coinciden con `FECompUltimoAutorizado`.
- **Rechazo forzado a propósito** (fecha fuera de ±5 días) → queda `rechazado` con el error de ARCA
  legible en `arca_solicitudes`.
- **Recuperación por timeout**: cortar la respuesta a mano tras autorizar, reintentar, y confirmar
  que **recupera el CAE por `FECompConsultar` en vez de emitir de nuevo**. Es la prueba más
  importante de todas.
- Verificar el catálogo sembrado contra `FEParamGetCondicionIvaReceptor`.

---

### Fase 4 — Notas de Crédito y Débito

**Entregables:** `crear_nota` convertida a borrador; `CbtesAsoc` armado desde `notas.factura_id`;
validación de coincidencia de letra.

**Verificación:** NC A sobre una Factura A emitida en Fase 3 → CAE propio, y el saldo de la factura
recalculado por `recalcular_estado_factura` como hasta ahora. Intentar NC B sobre Factura A → debe
rechazarse **en el CRM**, antes de llegar a ARCA. **ND A totalmente exenta** (el caso real más común
de exento en Tango, §1) → `ImpOpEx` = total, `ImpNeto = 0`, sin array `Iva`, y CAE otorgado.

---

### Fase 5 — UI y ciclo de reintento

**Entregables:** todo lo de §5.

**Verificación:** emitir, ver el badge en verde con el CAE; forzar un rechazo y ver el panel de error
con el mensaje de ARCA; corregir y reintentar hasta autorizar; confirmar que una factura autorizada
**no se puede editar ni anular** desde la UI; ver el banner de homologación.

---

### Fase 6 — PDF fiscal

**Entregables:** bloque CAE + QR en `templates.ts`; marca de agua en borradores.

**Verificación:** **escanear el QR del PDF con el celular** y confirmar que la página de ARCA muestra
el comprobante correcto. Es la única verificación que vale — un QR que se genera sin error pero
codifica mal los datos se ve idéntico.

---

### Fase 7 — Producción y go-live

1. Cargar los secrets de producción (`ARCA_CERT`, `ARCA_KEY` de §7.2) y poner
   `arca_ambiente='produccion'`, `arca_punto_venta=<PV nuevo>`.
2. Confirmar `FEDummy` y `FEParamGetPtosVenta` contra producción.
3. **Emitir una primera factura real, chica, a un cliente conocido.** Verificar en *Mis Comprobantes*
   de ARCA que figura, y contrastar importes.
4. Recién con eso OK: **dejar de cargar facturas en la web de ARCA**. Fin de la doble carga.
5. Vigilar la bandeja de borradores la primera semana.

**Rollback:** volver a emitir por la web de ARCA en el PV `00002` y cargar en el CRM como hasta hoy.
El PV nuevo queda con las que ya se emitieron; no hay que deshacer nada, porque la numeración de los
dos PV es independiente.

---

## 9. Estado de las fases

| Fase | Estado |
|---|---|
| 0 — Trámite ARCA (homologación) | ⬜ pendiente |
| 0 — Trámite ARCA (producción) | ⬜ pendiente |
| 1 — Spike firma CMS | ⬜ pendiente |
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
| **La firma CMS no sale en Deno** | Fase 1 es un spike bloqueante y barato. Plan B (Node en Vercel) sólo mueve dos archivos. |
| **Doble emisión por timeout** | Protocolo de idempotencia con `arca_nro_tentativo` + `FECompConsultar` (§4). Se prueba explícitamente en Fase 3. |
| **Emitir en producción creyendo que es homologación** | Banner permanente en la UI + secrets separados por ambiente. |
| **Cliente sin condición IVA cargada** | Validación previa en el cliente + revisión del backfill en Fase 2. |
| **Exento declarado como IVA 0 %** | El renglón `Exento (0%)` va a `ImpOpEx`, nunca a `Iva.Id 3` (§3.1). Se prueba con la ND exenta de la Fase 4. |
| **Percepciones cargadas en un comprobante** | Tango no tiene ninguna (§1), pero la tabla existe: `arca_comprobante_para_emitir` rechaza si `percepciones_monto ≠ 0`. |
| **Certificado vencido** (duran ~2 años) | Anotar la fecha de vencimiento en `PLAN_MAESTRO.md` §3.7, junto al CAI del talonario de remitos. Sin certificado no se factura. |
| **El proyecto Supabase se pausa por inactividad** | Riesgo ya conocido (`PLAN_MAESTRO.md` §3.7). Con facturación fiscal encima, deja de ser tolerable: **resolver plan pago o ping programado antes de la Fase 7.** |
| **ARCA caído** | El borrador de rescate ya lo cubre. La bandeja de borradores es el mecanismo de control. |
| **No hay tooling de tests en el repo** | La verificación es manual y contra homologación, fase por fase, con los checks listados. Homologación es el entorno de test: no hace falta inventar mocks. |

---

## 11. Referencias

- `CLAUDE.md` — reglas transversales: RPCs atómicas `SECURITY DEFINER`, RLS, totales server-side,
  prohibición de `FORCE ROW LEVEL SECURITY`.
- `PLAN_MAESTRO.md` §3.7 — riesgos operativos con fecha (agregar acá el vencimiento del certificado).
- `supabase/migrations/20260727120003_rpc_presupuestos.sql` — patrón de referencia para las RPCs.
- `supabase/migrations/20260728120000_fiscal_afip_columns.sql` — columnas fiscales ya existentes.
- `supabase/migrations/20260802120000_ventas_multialicuota_schema.sql` — catálogo `alicuotas_iva`
  (el renglón de 0 % es `Exento (0%)`).
- `supabase/migrations/20260821140000_ventas_percepciones.sql` — tabla `percepciones` y
  `percepciones_monto`: existen pero Tango no tiene datos para ellas (§1).
- `PLAN_MIGRACION_TANGO.md` §1 — cómo se lee el `.bak` del que salen los datos de §1.
- `supabase/functions/pdf/index.ts` — patrón de Edge Function con JWT del usuario.
- Documentación oficial WSFEv1 y WSAA de ARCA (verificar dominios vigentes, §7.2).
