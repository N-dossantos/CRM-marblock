// supabase/functions/arca/wsfe.ts
// Sobres SOAP de WSFEv1 y lectura de sus respuestas: FEDummy (health check, sin autenticación),
// FECompUltimoAutorizado, FECAESolicitar y FECompConsultar. Nombres y orden de los elementos según
// el WSDL de wswhomo.afip.gov.ar/wsfev1/service.asmx (consultado el 15/10/2026).
import { ErrorTransporte, desescapar, escapar, extraer, extraerTodos, postSoap, sinBloques } from './soap.ts'

const NS = 'http://ar.gov.afip.dif.FEV1/'

export interface Auth {
  token: string
  sign: string
  cuit: string
}

// Errors / Observaciones / Events de WSFEv1, tal cual vienen.
export interface MensajeArca {
  Code: number
  Msg: string
}

// ARCA procesó el pedido y lo rechazó con su bloque Errors (p. ej. 600, token inválido). Se usa
// en los métodos de consulta; en FECAESolicitar los errores se leen como parte de la respuesta.
export class ErrorArca extends Error {
  constructor(public errores: MensajeArca[]) {
    super(errores.map((e) => `${e.Code}: ${e.Msg}`).join(' · '))
  }
}

function sobre(metodo: string, interior = '') {
  return '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" ' +
    `xmlns:ar="${NS}"><soap:Body><ar:${metodo}>${interior}</ar:${metodo}></soap:Body></soap:Envelope>`
}

function auth(a: Auth) {
  return `<ar:Auth><ar:Token>${escapar(a.token)}</ar:Token><ar:Sign>${escapar(a.sign)}</ar:Sign>` +
    `<ar:Cuit>${escapar(a.cuit)}</ar:Cuit></ar:Auth>`
}

function texto(xml: string, tag: string) {
  const v = extraer(xml, tag)
  return v === null ? null : desescapar(v).trim()
}

function entero(xml: string, tag: string) {
  const v = texto(xml, tag)
  return v !== null && /^-?\d+$/.test(v) ? Number(v) : null
}

// <bloque><item><Code/><Msg/></item>…</bloque> → [{Code, Msg}]
function mensajes(xml: string, bloque: string, item: string): MensajeArca[] {
  const b = extraer(xml, bloque)
  if (b === null) return []
  return extraerTodos(b, item).map((m) => ({ Code: entero(m, 'Code') ?? 0, Msg: texto(m, 'Msg') ?? '' }))
}

// "20261015" → "2026-10-15"
export function fechaISO(aaaammdd: string | null) {
  return aaaammdd && /^\d{8}$/.test(aaaammdd)
    ? `${aaaammdd.slice(0, 4)}-${aaaammdd.slice(4, 6)}-${aaaammdd.slice(6, 8)}`
    : null
}

export async function feDummy(urlWsfe: string) {
  const r = await postSoap(urlWsfe, `${NS}FEDummy`, sobre('FEDummy'), 10_000)
  return {
    app_server: extraer(r, 'AppServer'),
    db_server: extraer(r, 'DbServer'),
    auth_server: extraer(r, 'AuthServer'),
  }
}

// Último número autorizado de la serie (PV, tipo): la fuente de la numeración fiscal.
export async function feCompUltimoAutorizado(urlWsfe: string, a: Auth, puntoVenta: number, cbteTipo: number) {
  const r = await postSoap(urlWsfe, `${NS}FECompUltimoAutorizado`, sobre('FECompUltimoAutorizado',
    auth(a) + `<ar:PtoVta>${puntoVenta}</ar:PtoVta><ar:CbteTipo>${cbteTipo}</ar:CbteTipo>`), 15_000)
  const res = extraer(r, 'FECompUltimoAutorizadoResult')
  if (res === null) throw new ErrorTransporte('WSFEv1: respuesta sin FECompUltimoAutorizadoResult')
  const errores = mensajes(res, 'Errors', 'Err')
  if (errores.length) throw new ErrorArca(errores)
  const nro = entero(res, 'CbteNro')
  if (nro === null) throw new ErrorTransporte('WSFEv1: último autorizado sin número')
  return nro
}

// Devuelve la respuesta cruda. Una falla de acá en adelante (timeout, HTTP, fault, respuesta que no
// se puede leer) deja el resultado incierto: ARCA pudo haber autorizado (PLAN_ARCA §4).
export async function feCAESolicitar(urlWsfe: string, a: Auth, feCAEReq: string) {
  return await postSoap(urlWsfe, `${NS}FECAESolicitar`,
    sobre('FECAESolicitar', auth(a) + `<ar:FeCAEReq>${feCAEReq}</ar:FeCAEReq>`), 60_000)
}

export interface RespuestaCAE {
  cab: { Resultado: string | null; Reproceso: string | null; FchProceso: string | null } | null
  det: {
    Resultado: string | null
    CbteDesde: number | null
    CbteFch: string | null
    DocTipo: number | null
    DocNro: number | null
    CAE: string | null
    CAEFchVto: string | null
  } | null
  observaciones: MensajeArca[]
  errores: MensajeArca[]
  eventos: MensajeArca[]
}

export function leerRespuestaCAE(xml: string): RespuestaCAE {
  const res = extraer(xml, 'FECAESolicitarResult')
  if (res === null) throw new ErrorTransporte('WSFEv1: respuesta sin FECAESolicitarResult')

  const cab = extraer(res, 'FeCabResp')
  // Se manda un solo comprobante por pedido: un solo FECAEDetResponse.
  const det = extraer(res, 'FECAEDetResponse')
  const detEscalar = det === null ? null : sinBloques(det, ['Observaciones'])
  return {
    cab: cab === null ? null : {
      Resultado: texto(cab, 'Resultado'),
      Reproceso: texto(cab, 'Reproceso'),
      FchProceso: texto(cab, 'FchProceso'),
    },
    det: detEscalar === null ? null : {
      Resultado: texto(detEscalar, 'Resultado'),
      CbteDesde: entero(detEscalar, 'CbteDesde'),
      CbteFch: texto(detEscalar, 'CbteFch'),
      DocTipo: entero(detEscalar, 'DocTipo'),
      DocNro: entero(detEscalar, 'DocNro'),
      CAE: texto(detEscalar, 'CAE') || null,
      CAEFchVto: texto(detEscalar, 'CAEFchVto') || null,
    },
    observaciones: det === null ? [] : mensajes(det, 'Observaciones', 'Obs'),
    errores: mensajes(sinBloques(res, ['FeDetResp']), 'Errors', 'Err'),
    eventos: mensajes(res, 'Events', 'Evt'),
  }
}

export interface ComprobanteArca {
  CbteTipo: number | null
  PtoVta: number | null
  CbteDesde: number | null
  CbteFch: string | null
  ImpTotal: number | null
  DocTipo: number | null
  DocNro: number | null
  Resultado: string | null
  CodAutorizacion: string | null
  EmisionTipo: string | null
  FchVto: string | null
  FchProceso: string | null
}

// Código con que FECompConsultar contesta que no tiene ese comprobante.
const SIN_RESULTADOS = 602

// encontrado: false sólo cuando ARCA contesta concluyentemente que el número no existe (602).
// Cualquier otro error es inconcluso y se lanza.
export async function feCompConsultar(
  urlWsfe: string, a: Auth, cbteTipo: number, puntoVenta: number, nro: number,
): Promise<{ encontrado: true; comprobante: ComprobanteArca; observaciones: MensajeArca[] } |
           { encontrado: false; errores: MensajeArca[] }> {
  const r = await postSoap(urlWsfe, `${NS}FECompConsultar`, sobre('FECompConsultar', auth(a) +
    `<ar:FeCompConsReq><ar:CbteTipo>${cbteTipo}</ar:CbteTipo><ar:CbteNro>${nro}</ar:CbteNro>` +
    `<ar:PtoVta>${puntoVenta}</ar:PtoVta></ar:FeCompConsReq>`), 20_000)
  const res = extraer(r, 'FECompConsultarResult')
  if (res === null) throw new ErrorTransporte('WSFEv1: respuesta sin FECompConsultarResult')

  const errores = mensajes(sinBloques(res, ['ResultGet']), 'Errors', 'Err')
  if (errores.length) {
    if (errores.every((e) => e.Code === SIN_RESULTADOS)) return { encontrado: false, errores }
    throw new ErrorArca(errores)
  }
  const get = extraer(res, 'ResultGet')
  if (get === null) throw new ErrorTransporte('WSFEv1: consulta sin ResultGet ni errores')

  const g = sinBloques(get, ['CbtesAsoc', 'Tributos', 'Iva', 'Opcionales', 'Compradores', 'PeriodoAsoc',
    'Actividades', 'Observaciones'])
  const importe = texto(g, 'ImpTotal')
  return {
    encontrado: true,
    comprobante: {
      CbteTipo: entero(g, 'CbteTipo'),
      PtoVta: entero(g, 'PtoVta'),
      CbteDesde: entero(g, 'CbteDesde'),
      CbteFch: texto(g, 'CbteFch'),
      ImpTotal: importe === null || importe === '' ? null : Number(importe),
      DocTipo: entero(g, 'DocTipo'),
      DocNro: entero(g, 'DocNro'),
      Resultado: texto(g, 'Resultado'),
      CodAutorizacion: texto(g, 'CodAutorizacion') || null,
      EmisionTipo: texto(g, 'EmisionTipo'),
      FchVto: texto(g, 'FchVto'),
      FchProceso: texto(g, 'FchProceso'),
    },
    observaciones: mensajes(get, 'Observaciones', 'Obs'),
  }
}
