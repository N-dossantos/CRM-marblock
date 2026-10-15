// supabase/functions/arca/index.ts
// Edge Function de facturación electrónica contra ARCA (PLAN_ARCA.md). Cada ambiente es un proyecto
// Supabase distinto con sus propios secrets ARCA_* (§2): el ambiente lo dice el despliegue, nunca la
// UI ni config_empresa.
//
// Fase 1 (spike): sólo GET /arca/estado, que consulta FEDummy y prueba la firma CMS + WSAA.
// emitir / reconciliar / ultimo / solicitud llegan en la Fase 3.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import { createClient } from 'npm:@supabase/supabase-js@2'
import { ErrorSoap, ErrorTransporte } from './soap.ts'
import { CacheEnMemoria, ErrorTAVigente, obtenerTA } from './wsaa.ts'
import { feDummy } from './wsfe.ts'

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

class ErrorConfig extends Error {}

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

// Fase 2: pasa a arca_tokens. Mientras tanto, un cold start pierde el TA y WSAA no da otro por 12 h.
const cacheTA = new CacheEnMemoria()

function json(cuerpo: unknown, status = 200) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })
}

// Mensaje seguro para la UI: errores de ARCA y de transporte tal cual; cualquier otra cosa se
// loguea y se devuelve genérica (podría arrastrar material que no debe salir).
function describir(e: unknown) {
  if (e instanceof ErrorTAVigente || e instanceof ErrorTransporte) return e.message
  if (e instanceof ErrorSoap) return `${e.codigo}: ${e.message}`
  console.error('arca:', e instanceof Error ? e.message : e)
  return 'Error interno'
}

async function estado(cfg: ReturnType<typeof leerConfig>) {
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
  const parts = new URL(req.url).pathname.split('/').filter(Boolean)
  const idx = parts.indexOf('arca')
  const ruta = (idx >= 0 ? parts.slice(idx + 1) : parts).join('/')

  try {
    const cfg = leerConfig()
    if (req.method === 'GET' && ruta === 'estado') return json(await estado(cfg))
    return json({ error: 'Ruta no encontrada' }, 404)
  } catch (e) {
    if (e instanceof ErrorConfig) return json({ error: e.message }, 500)
    return json({ error: describir(e) }, 500)
  }
})
