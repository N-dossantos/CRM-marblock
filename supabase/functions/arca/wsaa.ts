// supabase/functions/arca/wsaa.ts
// Autenticación contra WSAA: arma el TRA (loginTicketRequest), lo firma en CMS/PKCS#7 con el
// certificado y la clave del ambiente, y lo canjea por un TA (token + sign) con loginCms.
//
// El TA vale 12 h y WSAA rechaza pedir otro mientras el anterior siga vigente
// (`coe.alreadyAuthenticated`), así que el cache no es opcional (PLAN_ARCA §2). En la Fase 1 el
// cache es la memoria del isolate; en la Fase 2 pasa a `arca_tokens` (arca_token_get/set), que
// además tiene que serializar dos pedidos simultáneos.
//
// Token, sign y la clave son credenciales para facturar a nombre de la empresa: nunca se loguean ni
// se devuelven al browser.
// deno-lint-ignore-file no-explicit-any
import forge from 'npm:node-forge@1.4.0'
import { ErrorSoap, ErrorTransporte, desescapar, extraer, postSoap } from './soap.ts'

export interface TA {
  token: string
  sign: string
  expiraEn: Date
}

export interface CacheTA {
  leer(servicio: string): Promise<TA | null>
  guardar(servicio: string, ta: TA): Promise<void>
}

export class CacheEnMemoria implements CacheTA {
  #tas = new Map<string, TA>()
  leer(servicio: string) {
    return Promise.resolve(this.#tas.get(servicio) ?? null)
  }
  guardar(servicio: string, ta: TA) {
    this.#tas.set(servicio, ta)
    return Promise.resolve()
  }
}

// WSAA ya entregó un TA vigente para este certificado y servicio, y no lo tenemos en cache.
export class ErrorTAVigente extends Error {
  constructor() {
    super('WSAA ya entregó un ticket vigente para este certificado y no da otro hasta que venza ' +
      '(12 h desde que se pidió).')
  }
}

// No usar un TA al que le queden menos de 10 minutos: una emisión en curso no debe quedarse sin él.
const MARGEN_MS = 10 * 60_000

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
  const previo = await cache.leer(servicio)
  if (previo && previo.expiraEn.getTime() - Date.now() > MARGEN_MS) return { ta: previo, origen: 'cache' }

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

  const ta = { token, sign, expiraEn: new Date(expira) }
  await cache.guardar(servicio, ta)
  return { ta, origen: 'nuevo' }
}
