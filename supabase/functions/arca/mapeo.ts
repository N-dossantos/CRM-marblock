// supabase/functions/arca/mapeo.ts
// El `det` de arca_comprobante_para_emitir (ya con códigos ARCA, Iva agrupado por alícuota, exento
// en ImpOpEx y CbtesAsoc para NC/ND) → XML de FeCAEReq. La base calcula; acá sólo se completa el
// número que dio ARCA y el CUIT emisor del comprobante asociado, se controla que los importes
// cuadren y se arma el XML.
//
// El orden de los elementos es el del WSDL: el servicio es ASMX y puede ignorar en silencio un
// elemento fuera de secuencia.
import { escapar } from './soap.ts'

// Falla antes de enviar: el comprobante vuelve a borrador (arca_registrar_error_previo).
export class ErrorMapeo extends Error {}

// FEDetRequest + FECAEDetRequest, en orden. Tributos, Opcionales, Compradores, PeriodoAsoc y
// Actividades no se usan en esta entrega (PLAN_ARCA §1): si la base los mandara, se frena.
const ORDEN = [
  'Concepto', 'DocTipo', 'DocNro', 'CbteDesde', 'CbteHasta', 'CbteFch',
  'ImpTotal', 'ImpTotConc', 'ImpNeto', 'ImpOpEx', 'ImpTrib', 'ImpIVA',
  'FchServDesde', 'FchServHasta', 'FchVtoPago', 'MonId', 'MonCotiz', 'CanMisMonExt',
  'CondicionIVAReceptorId', 'CbtesAsoc', 'Iva',
] as const
const IMPORTES = new Set(['ImpTotal', 'ImpTotConc', 'ImpNeto', 'ImpOpEx', 'ImpTrib', 'ImpIVA'])

export type Det = Record<string, unknown>
interface AlicIva { Id: number; BaseImp: number; Importe: number }
interface CbteAsoc { Tipo: number; PtoVta: number; Nro: number; Cuit?: string; CbteFch?: string }

// El detalle tal cual se envía (y se audita): número de ARCA y CUIT emisor en cada asociado.
export function completarDetalle(det: Det, nro: number, cuitEmisor: string): Det {
  const desconocidos = Object.keys(det).filter((k) => !(ORDEN as readonly string[]).includes(k))
  if (desconocidos.length) throw new ErrorMapeo(`Campos que la emisión no sabe informar: ${desconocidos.join(', ')}`)
  const asoc = det.CbtesAsoc as CbteAsoc[] | undefined
  return {
    ...det,
    CbteDesde: nro,
    CbteHasta: nro,
    ...(asoc ? { CbtesAsoc: asoc.map((a) => ({ ...a, Cuit: cuitEmisor })) } : {}),
  }
}

const centavos = (v: unknown) => Math.round(Number(v) * 100)

// Las reglas de importes de §3.3, en centavos: ARCA rechaza una diferencia de un centavo.
export function validarImportes(det: Det) {
  const [total, totConc, neto, opEx, trib, iva] =
    ['ImpTotal', 'ImpTotConc', 'ImpNeto', 'ImpOpEx', 'ImpTrib', 'ImpIVA'].map((k) => centavos(det[k]))
  if ([total, totConc, neto, opEx, trib, iva].some(Number.isNaN)) throw new ErrorMapeo('Importes incompletos')
  if (total !== totConc + neto + opEx + trib + iva) {
    throw new ErrorMapeo('ImpTotal no es la suma de ImpTotConc + ImpNeto + ImpOpEx + ImpTrib + ImpIVA')
  }
  const alicuotas = (det.Iva as AlicIva[] | undefined) ?? []
  if (alicuotas.reduce((s, a) => s + centavos(a.BaseImp), 0) !== neto) {
    throw new ErrorMapeo('ImpNeto no es la suma de las bases del array Iva')
  }
  if (alicuotas.reduce((s, a) => s + centavos(a.Importe), 0) !== iva) {
    throw new ErrorMapeo('ImpIVA no es la suma de los importes del array Iva')
  }
  if (det.MonId !== 'PES' || Number(det.MonCotiz) !== 1) throw new ErrorMapeo('Sólo se emite en pesos')
}

function valor(campo: string, v: unknown) {
  return IMPORTES.has(campo) ? Number(v).toFixed(2) : escapar(String(v))
}

function elemento(campo: string, v: unknown): string {
  if (campo === 'Iva') {
    return '<ar:Iva>' + (v as AlicIva[]).map((a) =>
      `<ar:AlicIva><ar:Id>${a.Id}</ar:Id><ar:BaseImp>${Number(a.BaseImp).toFixed(2)}</ar:BaseImp>` +
      `<ar:Importe>${Number(a.Importe).toFixed(2)}</ar:Importe></ar:AlicIva>`).join('') + '</ar:Iva>'
  }
  if (campo === 'CbtesAsoc') {
    return '<ar:CbtesAsoc>' + (v as CbteAsoc[]).map((a) =>
      `<ar:CbteAsoc><ar:Tipo>${a.Tipo}</ar:Tipo><ar:PtoVta>${a.PtoVta}</ar:PtoVta><ar:Nro>${a.Nro}</ar:Nro>` +
      (a.Cuit ? `<ar:Cuit>${escapar(a.Cuit)}</ar:Cuit>` : '') +
      (a.CbteFch ? `<ar:CbteFch>${escapar(a.CbteFch)}</ar:CbteFch>` : '') +
      '</ar:CbteAsoc>').join('') + '</ar:CbtesAsoc>'
  }
  return `<ar:${campo}>${valor(campo, v)}</ar:${campo}>`
}

// Interior de <ar:FeCAEReq>: cabecera (un comprobante) + detalle.
export function feCAEReqXml(puntoVenta: number, cbteTipo: number, det: Det) {
  const cuerpo = ORDEN.filter((c) => det[c] !== undefined && det[c] !== null)
    .map((c) => elemento(c, det[c])).join('')
  return `<ar:FeCabReq><ar:CantReg>1</ar:CantReg><ar:PtoVta>${puntoVenta}</ar:PtoVta>` +
    `<ar:CbteTipo>${cbteTipo}</ar:CbteTipo></ar:FeCabReq>` +
    `<ar:FeDetReq><ar:FECAEDetRequest>${cuerpo}</ar:FECAEDetRequest></ar:FeDetReq>`
}
