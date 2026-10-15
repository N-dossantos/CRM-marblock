// supabase/functions/arca/wsaa.ts
// Autenticación contra WSAA: arma el TRA (loginTicketRequest), lo firma en CMS/PKCS#7 con el
// certificado y la clave del ambiente, y lo canjea por un TA (token + sign) con loginCms.
//
// El TA vale 12 h y WSAA rechaza pedir otro mientras el anterior siga vigente
// (`coe.alreadyAuthenticated`), así que el cache no es opcional (PLAN_ARCA §2). Vive en
// `arca_tokens`, compartido entre isolates: en la Fase 1 una segunda llamada cayó en otro isolate
// sin el TA en memoria y el proyecto se quedó sin token hasta que venció. arca_token_get además da
// el turno de renovarlo a un solo llamador, para que dos isolates no pidan dos TA a la vez.
//
// Token, sign y la clave son credenciales para facturar a nombre de la empresa: nunca se loguean ni
// se devuelven al browser.
// deno-lint-ignore-file no-explicit-any
import forge from 'npm:node-forge@1.4.0'
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { ErrorSoap, ErrorTransporte, desescapar, extraer, postSoap } from './soap.ts'

export interface TA {
  token: string
  sign: string
  expiraEn: Date
}

// Lo que devuelve el cache: un TA con más vida que el margen pedido, el turno para pedir uno nuevo
// a WSAA, o que espere porque otro llamador lo está pidiendo.
export type LecturaTA = { ta: TA } | { renovar: true } | { esperar: true }

export interface CacheTA {
  leer(servicio: string, margenSegundos: number): Promise<LecturaTA>
  guardar(servicio: string, ta: TA): Promise<void>
}

// Cliente con service-role: arca_token_get / arca_token_set sólo los puede ejecutar service_role.
export class CacheEnBase implements CacheTA {
  constructor(private db: SupabaseClient) {}

  async leer(servicio: string, margenSegundos: number): Promise<LecturaTA> {
    const { data, error } = await this.db.rpc('arca_token_get', {
      p_servicio: servicio, p_margen_segundos: margenSegundos,
    })
    if (error) throw new Error(`arca_token_get: ${error.message}`)
    if (data?.token) return { ta: { token: data.token, sign: data.sign, expiraEn: new Date(data.expira_en) } }
    if (data?.renovar) return { renovar: true }
    return { esperar: true }
  }

  async guardar(servicio: string, ta: TA) {
    const { error } = await this.db.rpc('arca_token_set', {
      p_servicio: servicio, p_token: ta.token, p_sign: ta.sign, p_expira_en: ta.expiraEn.toISOString(),
    })
    if (error) throw new Error(`arca_token_set: ${error.message}`)
  }
}

// WSAA ya entregó un TA vigente para este certificado y servicio, y no lo tenemos en cache.
export class ErrorTAVigente extends Error {
  constructor() {
    super('WSAA ya entregó un ticket vigente para este certificado y no da otro hasta que venza ' +
      '(12 h desde que se pidió).')
  }
}

// Otro llamador está renovando el TA y no terminó dentro de la espera.
export class ErrorTAEnRenovacion extends Error {
  constructor() {
    super('Otra operación está renovando el acceso a ARCA: reintentá en un minuto.')
  }
}

// Un TA al que le queda menos de un minuto no se usa: una emisión tiene que terminar con él. El
// margen es chico a propósito: WSAA no da otro TA mientras el anterior siga vigente, así que
// descartarlo antes de tiempo deja sin emitir hasta que venza.
const MARGEN_SEGUNDOS = 60

// Mientras otro llamador renueva: hasta ~16 s de espera, consultando cada 2 s.
const ESPERA_MS = 2_000
const INTENTOS = 8

// Hora de Argentina (UTC-3 fijo, sin horario de verano) en ISO 8601 con offset, como pide WSAA.
function horaAR(ms: number) {
  return new Date(ms - 3 * 3_600_000).toISOString().replace(/\.\d{3}Z$/, '-03:00')
}

export function armarTRA(servicio: string, ahora = Date.now()) {
  return '<?xml version="1.0" encoding="UTF-8"?>' +
    '<loginTicketRequest version="1.0"><header>' +
    `<uniqueId>${Math.floor(ahora / 1000)}</uniqueId>` +
    `<generationTime>${horaAR(ahora - 10 * 60_000)}</generationTime>` +
    `<expirationTime>${horaAR(ahora + 10 * 60_000)}</expirationTime>` +
    `</header><service>${servicio}</service></loginTicketRequest>`
}

// CMS SignedData con el contenido adentro (no detached), SHA-256 y atributos firmados: lo mismo que
// `openssl cms -sign -nodetach -binary`, que es lo que se probó contra WSAA el 15/10/2026.
export function firmarCMS(tra: string, certPem: string, keyPem: string): string {
  const certificado = forge.pki.certificateFromPem(certPem)
  const p7 = forge.pkcs7.createSignedData()
  p7.content = forge.util.createBuffer(tra, 'utf8')
  p7.addCertificate(certificado)
  p7.addSigner({
    key: forge.pki.privateKeyFromPem(keyPem),
    certificate: certificado,
    digestAlgorithm: forge.pki.oids.sha256,
    authenticatedAttributes: [
      { type: forge.pki.oids.contentType, value: forge.pki.oids.data },
      { type: forge.pki.oids.messageDigest },
      { type: forge.pki.oids.signingTime, value: new Date() as any },
    ],
  })
  p7.sign()
  return forge.util.encode64(forge.asn1.toDer(p7.toAsn1()).getBytes())
}

export interface ConfigWSAA {
  urlWsaa: string
  certPem: string
  keyPem: string
}

export async function obtenerTA(
  cfg: ConfigWSAA,
  cache: CacheTA,
  servicio = 'wsfe',
): Promise<{ ta: TA; origen: 'cache' | 'nuevo' }> {
  for (let intento = 0; intento < INTENTOS; intento++) {
    const lectura = await cache.leer(servicio, MARGEN_SEGUNDOS)
    if ('ta' in lectura) return { ta: lectura.ta, origen: 'cache' }
    if ('renovar' in lectura) return { ta: await pedirTA(cfg, cache, servicio), origen: 'nuevo' }
    await new Promise((listo) => setTimeout(listo, ESPERA_MS))
  }
  throw new ErrorTAEnRenovacion()
}

// Sólo con el turno de arca_token_get. Si WSAA falla, el turno vence solo al minuto y otro reintenta.
async function pedirTA(cfg: ConfigWSAA, cache: CacheTA, servicio: string): Promise<TA> {
  const cms = firmarCMS(armarTRA(servicio), cfg.certPem, cfg.keyPem)
  const sobre = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" ' +
    'xmlns:wsaa="http://wsaa.view.sua.dvadac.desein.afip.gov"><soapenv:Header/><soapenv:Body>' +
    `<wsaa:loginCms><wsaa:in0>${cms}</wsaa:in0></wsaa:loginCms></soapenv:Body></soapenv:Envelope>`

  let respuesta: string
  try {
    respuesta = await postSoap(cfg.urlWsaa, '""', sobre)
  } catch (e) {
    if (e instanceof ErrorSoap && e.codigo.endsWith('coe.alreadyAuthenticated')) throw new ErrorTAVigente()
    throw e
  }

  // loginCmsReturn trae el loginTicketResponse como texto XML escapado.
  const retorno = extraer(respuesta, 'loginCmsReturn')
  const ticket = retorno === null ? '' : desescapar(retorno)
  const token = extraer(ticket, 'token')?.trim()
  const sign = extraer(ticket, 'sign')?.trim()
  const expira = extraer(ticket, 'expirationTime')?.trim()
  if (!token || !sign || !expira) throw new ErrorTransporte('WSAA: respuesta sin TA completo')

  // Un TA que no se guarda se pierde por 12 h (WSAA no da otro): se reintenta una vez.
  const ta = { token, sign, expiraEn: new Date(expira) }
  try {
    await cache.guardar(servicio, ta)
  } catch (e) {
    console.error('arca: no se pudo guardar el TA, se reintenta:', e instanceof Error ? e.message : e)
    await new Promise((listo) => setTimeout(listo, 1_000))
    await cache.guardar(servicio, ta)
  }
  return ta
}
