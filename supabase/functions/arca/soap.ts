// supabase/functions/arca/soap.ts
// Helpers mínimos de XML/SOAP para WSAA y WSFEv1. De cada servicio se usa un subconjunto chico y
// estable, así que el sobre se arma a mano y la respuesta se lee por nombre de elemento, sin cliente
// SOAP genérico ni parser DOM (Deno no trae DOMParser para XML).

// Falla de red, timeout, HTTP sin fault o respuesta incompleta. Después de enviar FECAESolicitar
// esto NO es un rechazo: el resultado queda incierto y se reconcilia (PLAN_ARCA §4).
export class ErrorTransporte extends Error {}

// Fault SOAP explícito del servicio (p. ej. `ns1:coe.alreadyAuthenticated` de WSAA).
export class ErrorSoap extends Error {
  constructor(public codigo: string, mensaje: string) {
    super(mensaje)
  }
}

const ENTIDADES: Record<string, string> = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" }
const ESCAPES: Record<string, string> = { '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }

// Texto para meter dentro de un elemento del sobre.
export function escapar(s: string | number) {
  return String(s).replace(/[<>&"']/g, (c) => ESCAPES[c])
}

// Una sola pasada: `&amp;lt;` queda como `&lt;`, no como `<`.
export function desescapar(s: string) {
  return s.replace(/&(lt|gt|amp|quot|apos|#\d+|#x[0-9a-f]+);/gi, (_, e: string) =>
    e[0] !== '#' ? ENTIDADES[e.toLowerCase()]
      : String.fromCodePoint(e[1].toLowerCase() === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)))
}

// Elemento por nombre local, con o sin prefijo de namespace y con o sin atributos.
const patron = (tag: string) =>
  new RegExp(`<(?:[\\w.-]+:)?${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[\\w.-]+:)?${tag}>`, 'g')

export function extraer(xml: string, tag: string): string | null {
  const m = patron(tag).exec(xml)
  return m ? m[1] : null
}

export function extraerTodos(xml: string, tag: string): string[] {
  return [...xml.matchAll(patron(tag))].map((m) => m[1])
}

// Saca los bloques anidados (y sus formas vacías `<Tag/>`) para leer los campos escalares de un
// elemento sin agarrar uno homónimo de adentro: p. ej. el PtoVta de un CbteAsoc.
export function sinBloques(xml: string, tags: string[]) {
  return tags.reduce((x, tag) => x.replace(patron(tag), '')
    .replace(new RegExp(`<(?:[\\w.-]+:)?${tag}(?:\\s[^>]*)?/>`, 'g'), ''), xml)
}

export async function postSoap(url: string, accion: string, sobre: string, timeoutMs = 20_000) {
  const host = new URL(url).host
  let res: Response
  let texto: string
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'text/xml; charset=utf-8', SOAPAction: accion },
      body: sobre,
      signal: AbortSignal.timeout(timeoutMs),
    })
    texto = await res.text()
  } catch (e) {
    throw new ErrorTransporte(`${host}: ${e instanceof Error ? e.message : String(e)}`)
  }
  // Los faults llegan con HTTP 500: se miran antes que el status.
  const codigo = extraer(texto, 'faultcode')
  if (codigo !== null) {
    throw new ErrorSoap(desescapar(codigo).trim(), desescapar(extraer(texto, 'faultstring') ?? '').trim())
  }
  if (!res.ok) throw new ErrorTransporte(`${host}: HTTP ${res.status}`)
  return texto
}
