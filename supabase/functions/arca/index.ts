// supabase/functions/arca/index.ts
// Edge Function de facturación electrónica contra ARCA (PLAN_ARCA.md). Cada ambiente es un proyecto
// Supabase distinto con sus propios secrets ARCA_* (§2): el ambiente lo dice el despliegue, nunca la
// UI ni config_empresa.
//
//   GET  /arca/estado               FEDummy + TA de WSAA + ambiente y PV del despliegue
//   GET  /arca/ultimo?tipo=N        FECompUltimoAutorizado del PV del despliegue
//   POST /arca/emitir      {tabla, id}   pide el CAE de un borrador o rechazado
//   POST /arca/reconciliar {tabla, id}   resuelve un resultado incierto contra FECompConsultar
//
// El estado de cada comprobante vive en la base y lo cambian sólo las RPCs arca_* (20261015120002,
// 20261015130000), con UPDATE condicionados: esta función decide qué pasó con ARCA y lo registra.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import { createClient } from 'npm:@supabase/supabase-js@2'
import { ErrorMapeo, completarDetalle, feCAEReqXml, validarImportes, type Det } from './mapeo.ts'
import { ErrorSoap, ErrorTransporte } from './soap.ts'
import { CacheEnBase, ErrorTAEnRenovacion, ErrorTAVigente, obtenerTA } from './wsaa.ts'
import {
  type Auth, ErrorArca, feCAESolicitar, feCompConsultar, feCompUltimoAutorizado, fechaISO,
  feDummy, leerRespuestaCAE,
} from './wsfe.ts'

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}

// Endpoints publicados en la documentación oficial vigente (§7): no se reemplaza afip.gov.ar por
// arca.gob.ar a mano.
const ENDPOINTS = {
  homologacion: {
    wsaa: 'https://wsaahomo.afip.gov.ar/ws/services/LoginCms',
    wsfe: 'https://wswhomo.afip.gov.ar/wsfev1/service.asmx',
  },
  produccion: {
    wsaa: 'https://wsaa.afip.gov.ar/ws/services/LoginCms',
    wsfe: 'https://servicios1.afip.gov.ar/wsfev1/service.asmx',
  },
} as const

type Ambiente = keyof typeof ENDPOINTS
type Tabla = 'facturas' | 'notas'

// Tipos de comprobante de esta entrega (§3.1).
const TIPOS = new Set([1, 2, 3, 6, 7, 8])

class ErrorConfig extends Error {}

// Error de una RPC. P0001 es un RAISE EXCEPTION de la base: una regla de negocio con un mensaje
// pensado para el usuario.
class ErrorRpc extends Error {
  constructor(public funcion: string, public codigo: string | undefined, mensaje: string) {
    super(mensaje)
  }
  get deNegocio() {
    return this.codigo === 'P0001'
  }
}

// Los secrets ARCA_CERT / ARCA_KEY son el PEM en base64 (una línea, `base64 -i archivo`).
function pem(nombre: string, tipo: string) {
  let texto: string
  try {
    texto = atob(Deno.env.get(nombre)!.replace(/\s+/g, ''))
  } catch {
    throw new ErrorConfig(`${nombre} no es base64 válido`)
  }
  if (!texto.includes(`-----BEGIN ${tipo}`)) throw new ErrorConfig(`${nombre} no contiene un ${tipo} PEM`)
  return texto
}

function leerConfig() {
  const faltan = ['ARCA_CERT', 'ARCA_KEY', 'ARCA_CUIT', 'ARCA_AMBIENTE', 'ARCA_PUNTO_VENTA']
    .filter((n) => !Deno.env.get(n))
  if (faltan.length) throw new ErrorConfig(`Faltan secrets: ${faltan.join(', ')}`)

  const ambiente = Deno.env.get('ARCA_AMBIENTE')!
  if (!(ambiente in ENDPOINTS)) throw new ErrorConfig('ARCA_AMBIENTE debe ser homologacion o produccion')
  const cuit = Deno.env.get('ARCA_CUIT')!.replace(/\D/g, '')
  if (cuit.length !== 11) throw new ErrorConfig('ARCA_CUIT debe tener 11 dígitos')
  const puntoVenta = Number(Deno.env.get('ARCA_PUNTO_VENTA'))
  if (!Number.isInteger(puntoVenta) || puntoVenta < 1) throw new ErrorConfig('ARCA_PUNTO_VENTA inválido')

  const urls = ENDPOINTS[ambiente as Ambiente]
  return {
    ambiente: ambiente as Ambiente,
    cuit,
    puntoVenta,
    urlWsaa: urls.wsaa,
    urlWsfe: urls.wsfe,
    certPem: pem('ARCA_CERT', 'CERTIFICATE'),
    keyPem: pem('ARCA_KEY', 'PRIVATE KEY'),
  }
}

type Config = ReturnType<typeof leerConfig>

// Service-role: las RPCs arca_* y el cache del TA no están al alcance de `authenticated`. Se usa
// recién después de validar la sesión del llamador.
const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false, autoRefreshToken: false },
})
const cacheTA = new CacheEnBase(db)

async function rpc<T>(funcion: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(funcion, args)
  if (error) throw new ErrorRpc(funcion, error.code, error.message)
  return data as T
}

function json(cuerpo: unknown, status = 200) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })
}

// Mensaje seguro para la UI: errores de ARCA, de transporte y reglas de negocio tal cual; cualquier
// otra cosa se loguea y se devuelve genérica (podría arrastrar material que no debe salir).
function describir(e: unknown) {
  if (e instanceof ErrorTAVigente || e instanceof ErrorTAEnRenovacion || e instanceof ErrorTransporte ||
      e instanceof ErrorArca || e instanceof ErrorMapeo) return e.message
  if (e instanceof ErrorSoap) return `${e.codigo}: ${e.message}`
  if (e instanceof ErrorRpc && e.deNegocio) return e.message
  console.error('arca:', e instanceof Error ? e.message : e)
  return 'Error interno'
}

async function auth(cfg: Config): Promise<Auth> {
  const { ta } = await obtenerTA(cfg, cacheTA)
  return { token: ta.token, sign: ta.sign, cuit: cfg.cuit }
}

// ── estado / ultimo ──────────────────────────────────────────────

async function estado(cfg: Config) {
  const [fedummy, wsaa] = await Promise.all([
    feDummy(cfg.urlWsfe).then(
      (r) => ({ ok: true, ...r }),
      (e) => ({ ok: false, error: describir(e) }),
    ),
    obtenerTA(cfg, cacheTA).then(
      ({ ta, origen }) => ({ ok: true, origen, expira_en: ta.expiraEn.toISOString() }),
      (e) => ({ ok: false, error: describir(e) }),
    ),
  ])
  return { ambiente: cfg.ambiente, cuit: cfg.cuit, punto_venta: cfg.puntoVenta, fedummy, wsaa }
}

async function ultimo(cfg: Config, tipo: number) {
  if (!TIPOS.has(tipo)) return json({ error: 'Tipo de comprobante inválido' }, 400)
  try {
    const nro = await feCompUltimoAutorizado(cfg.urlWsfe, await auth(cfg), cfg.puntoVenta, tipo)
    return json({ punto_venta: cfg.puntoVenta, cbte_tipo: tipo, ultimo: nro })
  } catch (e) {
    return json({ error: describir(e) }, 503)
  }
}

// ── emitir ───────────────────────────────────────────────────────
// reclamar la serie → token → último autorizado → reservar último+1 → FECAESolicitar → registrar.
// Todo lo que falla antes de enviar vuelve a borrador. Después de enviar, sólo una respuesta
// completa decide: A con CAE → autorizado; R o errores sin CAE → rechazado; cualquier otra cosa
// (timeout, HTTP, fault, respuesta ilegible) → resultado incierto, que se reconcilia (§4).

interface Reclamo {
  cbte_tipo: number
  punto_venta: number
  det: Det
}

interface Registro {
  registrado: boolean
  estado_fiscal: string
  numero: string | null
  motivo: string | null
}

async function errorPrevio(tabla: Tabla, id: number, error: string, request: unknown = null) {
  return await rpc<string>('arca_registrar_error_previo', {
    p_tabla: tabla, p_id: id, p_error: error, p_request: request,
  })
}

// Si tampoco se puede registrar el incierto, el comprobante queda en_proceso con su número
// tentativo y /reconciliar lo toma como interrumpido a los 3 minutos: no se pierde.
async function incierto(tabla: Tabla, id: number, request: unknown, response: unknown, error: string) {
  try {
    await rpc('arca_registrar_incierto', {
      p_tabla: tabla, p_id: id, p_request: request, p_response: response, p_error: error,
    })
  } catch (e) {
    console.error('arca: no se pudo registrar el resultado incierto:', describir(e))
  }
  return json({
    estado_fiscal: 'resultado_incierto',
    error: `No se sabe si ARCA autorizó el comprobante (${error}). Consultá el estado antes de reintentar.`,
  })
}

// Un CAE no se puede perder: se reintenta una vez. Si la base sigue sin responder, el comprobante
// queda en_proceso con el número tentativo y la reconciliación lo recupera de ARCA.
async function registrarCAE(args: Record<string, unknown>): Promise<Registro> {
  try {
    return await rpc<Registro>('arca_registrar_cae', args)
  } catch (e) {
    console.error('arca: arca_registrar_cae falló, se reintenta:', describir(e))
    await new Promise((listo) => setTimeout(listo, 1_000))
    return await rpc<Registro>('arca_registrar_cae', args)
  }
}

async function emitir(cfg: Config, tabla: Tabla, id: number) {
  // Primero la base: valida el comprobante y toma la serie. Lo que no se puede emitir se rechaza
  // acá, aunque ARCA esté caído.
  let reclamo: Reclamo
  try {
    reclamo = await rpc<Reclamo>('arca_reclamar_serie', {
      p_tabla: tabla, p_id: id, p_punto_venta: cfg.puntoVenta,
    })
  } catch (e) {
    if (e instanceof ErrorRpc && e.deNegocio) return json({ error: e.message }, 422)
    throw e
  }
  const pv = reclamo.punto_venta
  const tipo = reclamo.cbte_tipo

  // Antes de enviar (token, último autorizado, armado): cualquier falla libera la serie y vuelve
  // a borrador.
  let a: Auth
  let det: Det
  let request: { FeCabReq: unknown; FECAEDetRequest: Det } | null = null
  try {
    a = await auth(cfg)
    const nro = (await feCompUltimoAutorizado(cfg.urlWsfe, a, pv, tipo)) + 1
    det = completarDetalle(reclamo.det, nro, cfg.cuit)
    request = { FeCabReq: { CantReg: 1, PtoVta: pv, CbteTipo: tipo }, FECAEDetRequest: det }
    validarImportes(det)
    await rpc('arca_reservar_numero', { p_tabla: tabla, p_id: id, p_nro: nro })
  } catch (e) {
    const msg = describir(e)
    const estadoFiscal = await errorPrevio(tabla, id, msg, request)
      .catch((x) => (console.error('arca:', describir(x)), 'en_proceso'))
    return json({ estado_fiscal: estadoFiscal, error: msg }, 503)
  }

  // Enviado: de acá en adelante nada es un rechazo salvo que ARCA lo diga.
  let xml: string
  try {
    xml = await feCAESolicitar(cfg.urlWsfe, a, feCAEReqXml(pv, tipo, det))
  } catch (e) {
    return await incierto(tabla, id, request, null, `FECAESolicitar: ${describir(e)}`)
  }
  let r: ReturnType<typeof leerRespuestaCAE>
  try {
    r = leerRespuestaCAE(xml)
  } catch (e) {
    return await incierto(tabla, id, request, { crudo: xml.slice(0, 4000) }, describir(e))
  }

  const d = r.det
  if (d?.Resultado === 'A' && d.CAE && d.CAEFchVto && d.CbteDesde) {
    let reg: Registro
    try {
      reg = await registrarCAE({
        p_tabla: tabla, p_id: id, p_numero: d.CbteDesde, p_cae: d.CAE, p_vto: fechaISO(d.CAEFchVto),
        p_afip_tipo: tipo, p_doc_tipo: det.DocTipo, p_doc_nro: String(det.DocNro),
        p_request: request, p_response: r, p_observaciones: r.observaciones.length ? r.observaciones : null,
      })
    } catch (e) {
      console.error(`arca: CAE ${d.CAE} (${tabla} ${id}, N° ${d.CbteDesde}) sin registrar:`, describir(e))
      return json({
        estado_fiscal: 'en_proceso', cae: d.CAE,
        error: `ARCA autorizó el comprobante (CAE ${d.CAE}) pero el CRM no pudo registrarlo. En unos ` +
          'minutos usá "Consultar estado" para recuperarlo.',
      }, 500)
    }
    if (!reg.registrado) {
      return json({
        estado_fiscal: reg.estado_fiscal, cae: d.CAE,
        error: `ARCA autorizó el CAE ${d.CAE} (N° ${d.CbteDesde}) pero el CRM no pudo registrarlo: ` +
          `${reg.motivo}. Quedó auditado y la serie bloqueada: hay que resolverlo a mano.`,
      }, 500)
    }
    return json({
      estado_fiscal: 'autorizado', numero: reg.numero, cae: d.CAE, cae_vencimiento: fechaISO(d.CAEFchVto),
      observaciones: r.observaciones,
    })
  }

  if (r.cab?.Resultado === 'R' || d?.Resultado === 'R' || (r.errores.length && !d?.CAE)) {
    const estadoFiscal = await rpc<string>('arca_registrar_rechazo', {
      p_tabla: tabla, p_id: id, p_errores: r.errores.length ? r.errores : null,
      p_observaciones: r.observaciones.length ? r.observaciones : null, p_request: request, p_response: r,
    }).catch((e) => (console.error('arca: no se pudo registrar el rechazo:', describir(e)), 'en_proceso'))
    return json({ estado_fiscal: estadoFiscal, errores: r.errores, observaciones: r.observaciones })
  }

  return await incierto(tabla, id, request, r, 'ARCA respondió sin resultado ni CAE')
}

// ── reconciliar ──────────────────────────────────────────────────
// Un resultado incierto se resuelve sólo con una respuesta concluyente de ARCA: el comprobante
// existe y coincide (se registra su CAE) o no existe y el último autorizado sigue por debajo del
// número tentativo (vuelve a borrador). Cualquier otra cosa lo deja incierto y la serie bloqueada.

interface ParaReconciliar {
  estado_fiscal: string
  nro_tentativo: number | null
  punto_venta: number | null
  cbte_tipo: number | null
  colgado: boolean
  CbteFch: string
  ImpTotal: number
  DocTipo: number
  DocNro: string
}

async function reconciliar(cfg: Config, tabla: Tabla, id: number) {
  const leer = () => rpc<ParaReconciliar>('arca_para_reconciliar', { p_tabla: tabla, p_id: id })
  let c = await leer()

  // Un en_proceso viejo es una emisión que murió a mitad de camino (la función se cortó o la base
  // no respondió). Sin número tentativo no se llegó a enviar nada.
  if (c.estado_fiscal === 'en_proceso') {
    if (!c.colgado) {
      return json({ estado_fiscal: c.estado_fiscal, error: 'El comprobante se está emitiendo: esperá unos minutos.' }, 409)
    }
    if (c.nro_tentativo === null) {
      const estadoFiscal = await errorPrevio(tabla, id, 'La emisión se interrumpió antes de enviarse a ARCA.')
      return json({ estado_fiscal: estadoFiscal })
    }
    await rpc('arca_registrar_incierto', {
      p_tabla: tabla, p_id: id, p_request: null, p_response: null,
      p_error: 'La emisión se interrumpió sin registrar la respuesta de ARCA.',
    })
    c = await leer()
  }
  if (c.estado_fiscal !== 'resultado_incierto') {
    return json({ estado_fiscal: c.estado_fiscal, error: 'El comprobante no tiene un resultado incierto.' }, 409)
  }
  if (c.punto_venta === null || c.cbte_tipo === null || c.nro_tentativo === null) {
    console.error(`arca: ${tabla} ${id} incierto sin serie o sin número tentativo`)
    return json({ estado_fiscal: c.estado_fiscal, error: 'Error interno' }, 500)
  }
  const { punto_venta: pv, cbte_tipo: tipo, nro_tentativo: nro } = c
  const request = { FeCompConsReq: { CbteTipo: tipo, CbteNro: nro, PtoVta: pv } }

  // Sin respuesta concluyente: se audita y sigue incierto.
  const sigueIncierto = async (motivo: string, response: unknown = null, status = 503) => {
    await rpc('arca_registrar_incierto', {
      p_tabla: tabla, p_id: id, p_request: request, p_response: response, p_error: motivo,
    }).catch((e) => console.error('arca:', describir(e)))
    return json({ estado_fiscal: 'resultado_incierto', error: motivo }, status)
  }

  let a: Auth
  let consulta: Awaited<ReturnType<typeof feCompConsultar>>
  try {
    a = await auth(cfg)
    consulta = await feCompConsultar(cfg.urlWsfe, a, tipo, pv, nro)
  } catch (e) {
    return await sigueIncierto(`No se pudo consultar ARCA: ${describir(e)}`)
  }

  if (consulta.encontrado) {
    const k = consulta.comprobante
    const diferencias = [
      k.CodAutorizacion ? null : 'sin CAE',
      k.Resultado === 'A' ? null : `resultado ${k.Resultado}`,
      k.CbteFch === c.CbteFch ? null : `fecha ${k.CbteFch} ≠ ${c.CbteFch}`,
      k.ImpTotal !== null && Math.abs(k.ImpTotal - Number(c.ImpTotal)) < 0.005 ? null
        : `total ${k.ImpTotal} ≠ ${c.ImpTotal}`,
      k.DocTipo === Number(c.DocTipo) && k.DocNro === Number(c.DocNro) ? null
        : `documento ${k.DocTipo} ${k.DocNro} ≠ ${c.DocTipo} ${c.DocNro}`,
    ].filter(Boolean)
    if (diferencias.length) {
      return await sigueIncierto(
        `ARCA tiene un comprobante con el N° ${nro} que no coincide con este (${diferencias.join('; ')}). ` +
        'Hay que revisarlo a mano.', consulta, 409)
    }
    const reg = await registrarCAE({
      p_tabla: tabla, p_id: id, p_numero: nro, p_cae: k.CodAutorizacion, p_vto: fechaISO(k.FchVto),
      p_afip_tipo: tipo, p_doc_tipo: k.DocTipo, p_doc_nro: String(k.DocNro),
      p_request: request, p_response: consulta,
      p_observaciones: consulta.observaciones.length ? consulta.observaciones : null,
    })
    if (!reg.registrado) {
      return json({
        estado_fiscal: reg.estado_fiscal, cae: k.CodAutorizacion,
        error: `ARCA tiene el CAE ${k.CodAutorizacion} pero el CRM no pudo registrarlo: ${reg.motivo}.`,
      }, 500)
    }
    return json({
      estado_fiscal: 'autorizado', numero: reg.numero, cae: k.CodAutorizacion,
      cae_vencimiento: fechaISO(k.FchVto), recuperado: true,
    })
  }

  // ARCA no tiene ese número. Sólo se libera si además el último autorizado sigue por debajo: si
  // ya lo alcanzó, ese número pudo usarse.
  let ultimoAutorizado: number
  try {
    ultimoAutorizado = await feCompUltimoAutorizado(cfg.urlWsfe, a, pv, tipo)
  } catch (e) {
    return await sigueIncierto(`No se pudo consultar el último autorizado: ${describir(e)}`, consulta)
  }
  if (ultimoAutorizado >= nro) {
    return await sigueIncierto(
      `ARCA no encuentra el N° ${nro} pero ya autorizó hasta el N° ${ultimoAutorizado}. Hay que revisarlo a mano.`,
      { consulta, ultimo_autorizado: ultimoAutorizado }, 409)
  }
  try {
    await rpc('arca_confirmar_no_autorizado', {
      p_tabla: tabla, p_id: id, p_ultimo_autorizado: ultimoAutorizado, p_request: request,
      p_response: { consulta, ultimo_autorizado: ultimoAutorizado },
    })
  } catch (e) {
    if (e instanceof ErrorRpc && e.deNegocio) return json({ estado_fiscal: 'resultado_incierto', error: e.message }, 409)
    throw e
  }
  return json({
    estado_fiscal: 'borrador',
    mensaje: `ARCA no autorizó el comprobante (último autorizado: N° ${ultimoAutorizado}): se puede volver a emitir.`,
  })
}

// ── router ───────────────────────────────────────────────────────

async function leerCuerpo(req: Request): Promise<{ tabla: Tabla; id: number } | null> {
  try {
    const { tabla, id } = await req.json()
    if ((tabla === 'facturas' || tabla === 'notas') && Number.isInteger(id) && id > 0) return { tabla, id }
  } catch { /* cuerpo inválido */ }
  return null
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  // Sólo staff: cualquier usuario autenticado (modelo "shared staff", 20260727120002_rls.sql). Se
  // valida acá y no sólo en el gateway, porque después se usa la service-role (§2, Seguridad).
  const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  if (!jwt) return json({ error: 'Falta la sesión' }, 401)
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!)
  const { data, error } = await supabase.auth.getUser(jwt)
  if (error || !data.user) return json({ error: 'Sesión inválida' }, 401)

  // pathname llega como /functions/v1/arca/<ruta>: se toma lo que sigue al segmento 'arca'.
  const url = new URL(req.url)
  const parts = url.pathname.split('/').filter(Boolean)
  const idx = parts.indexOf('arca')
  const ruta = (idx >= 0 ? parts.slice(idx + 1) : parts).join('/')

  try {
    const cfg = leerConfig()
    if (req.method === 'GET' && ruta === 'estado') return json(await estado(cfg))
    if (req.method === 'GET' && ruta === 'ultimo') return await ultimo(cfg, Number(url.searchParams.get('tipo')))
    if (req.method === 'POST' && (ruta === 'emitir' || ruta === 'reconciliar')) {
      const cuerpo = await leerCuerpo(req)
      if (!cuerpo) return json({ error: 'Se espera {tabla: "facturas"|"notas", id}' }, 400)
      return ruta === 'emitir'
        ? await emitir(cfg, cuerpo.tabla, cuerpo.id)
        : await reconciliar(cfg, cuerpo.tabla, cuerpo.id)
    }
    return json({ error: 'Ruta no encontrada' }, 404)
  } catch (e) {
    if (e instanceof ErrorConfig) return json({ error: e.message }, 500)
    return json({ error: describir(e) }, 500)
  }
})
