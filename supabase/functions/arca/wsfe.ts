// supabase/functions/arca/wsfe.ts
// Sobres SOAP de WSFEv1 y lectura de sus respuestas. Fase 1: sólo FEDummy (health check, sin
// autenticación). FECAESolicitar, FECompUltimoAutorizado y FECompConsultar llegan en la Fase 3.
import { extraer, postSoap } from './soap.ts'

const NS = 'http://ar.gov.afip.dif.FEV1/'

function sobre(metodo: string, interior = '') {
  return '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" ' +
    `xmlns:ar="${NS}"><soap:Body><ar:${metodo}>${interior}</ar:${metodo}></soap:Body></soap:Envelope>`
}

export async function feDummy(urlWsfe: string) {
  const r = await postSoap(urlWsfe, `${NS}FEDummy`, sobre('FEDummy'), 10_000)
  return {
    app_server: extraer(r, 'AppServer'),
    db_server: extraer(r, 'DbServer'),
    auth_server: extraer(r, 'AuthServer'),
  }
}
