// src/components/Arca/index.jsx
// Facturación electrónica en la UI (PLAN_ARCA.md §5): badge del estado fiscal, panel de emisión con
// el ciclo de reintento, franja de la bandeja fiscal, y banner / indicador del ambiente.
//
// El estado fiscal vive en la base (facturas/notas.estado_fiscal) y lo cambian sólo las RPCs arca_*
// que llama la Edge Function `arca`. La UI no lo deduce de la respuesta: después de cada acción
// vuelve a leer arca_solicitud_ultimo y el comprobante.
import { useEffect, useState } from 'react'
import toast from 'react-hot-toast'
import { ArcaAPI } from '../../api'
import { $ar, fFecha, fDocNro, cuitValido } from '../../utils'

// historico = cargado antes del CRM fiscal (Tango / web de ARCA); autorizado = con CAE. Sólo esos
// cuentan para saldos, cobros, informes y NC/ND.
export const FISCALES = ['historico', 'autorizado']
export const EDITABLES = ['borrador', 'rechazado']
export const SIN_CAE = ['borrador', 'rechazado', 'resultado_incierto', 'en_proceso']
export const esFiscal = (doc) => FISCALES.includes(doc?.estado_fiscal)
export const esEditable = (doc) => EDITABLES.includes(doc?.estado_fiscal)

// Filtro "ARCA" de las listas. `estados` va tal cual a facturas_list(p_estado_fiscal).
export const FILTROS_ARCA = [
  { value: '',                   label: 'ARCA: todos' },
  { value: 'sin_cae',            label: 'Sin CAE (bandeja)',  estados: SIN_CAE },
  { value: 'borrador',           label: 'Borradores',         estados: ['borrador'] },
  { value: 'rechazado',          label: 'Rechazados',         estados: ['rechazado'] },
  { value: 'resultado_incierto', label: 'Resultado incierto', estados: ['resultado_incierto'] },
  { value: 'en_proceso',         label: 'En emisión',         estados: ['en_proceso'] },
  { value: 'autorizado',         label: 'Con CAE',            estados: ['autorizado'] },
  { value: 'historico',          label: 'Históricos',         estados: ['historico'] },
]
export const estadosDeFiltro = (v) => FILTROS_ARCA.find(f => f.value === v)?.estados ?? null

const ETIQUETA = {
  borrador:           'Borrador',
  en_proceso:         'En emisión',
  resultado_incierto: 'Resultado incierto',
  rechazado:          'Rechazado',
  autorizado:         'Autorizado',
}

// Un histórico no lleva badge: es la mayoría de las filas y no requiere nada.
export function FiscalBadge({ estado, cae }) {
  if (!estado || estado === 'historico') {
    return <span className="arca-historico" title="Registro histórico: emitido fuera del CRM, sin CAE registrado">—</span>
  }
  const texto = estado === 'autorizado' && cae ? `CAE ${String(cae).slice(0, 4)}…` : (ETIQUETA[estado] || estado)
  return <span className={`badge badge-arca-${estado}`} title={cae ? `CAE ${cae}` : undefined}>{texto}</span>
}

// Hoy en Argentina, YYYY-MM-DD (la fecha fiscal es la del envío: arca_reclamar_serie).
const hoyAR = () => new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Buenos_Aires' })

// Validación previa (§5): lo que el CRM no deja emitir o ARCA rechazaría, avisado antes de llamar.
// La base lo repite en arca_comprobante_para_emitir; esto es para no enterarse por un 422.
// `doc` es una fila de facturas_list / notas_list (o lo mismo armado por el formulario).
export function revisarEmision(tabla, doc) {
  const bloqueos = []
  const avisos = []
  const letra = tabla === 'notas' ? doc.tipo_letra : doc.tipo
  if (+doc.percepciones_monto) {
    bloqueos.push(`El comprobante tiene percepciones (${$ar(doc.percepciones_monto)}) y la emisión desde el ` +
      'CRM todavía no las informa a ARCA. Emitilo según el procedimiento fiscal vigente.')
  }
  if (doc.clase && letra && doc.clase !== letra) {
    bloqueos.push(`El cliente es ${doc.condicion_iva}: le corresponde comprobante ${doc.clase}, no ${letra}.`)
  }
  if (+doc.doc_tipo === 80 && !cuitValido(doc.doc_nro)) {
    bloqueos.push(`El CUIT del cliente (${fDocNro(80, doc.doc_nro)}) no es válido: corregilo en Clientes.`)
  } else if (letra === 'A' && +doc.doc_tipo !== 80) {
    bloqueos.push('Un comprobante A requiere el CUIT del receptor: cargalo en Clientes.')
  }
  if (tabla === 'notas') {
    if (doc.factura_estado_fiscal && !FISCALES.includes(doc.factura_estado_fiscal)) {
      bloqueos.push('La factura asociada todavía no está autorizada por ARCA.')
    } else if (doc.factura_estado_fiscal === 'historico') {
      avisos.push(`La factura ${doc.factura_numero} es histórica (emitida en la web de ARCA) y el CRM no ` +
        'la puede verificar contra ARCA. Antes de emitir, confirmá en la web de ARCA que existe con esos datos.')
    }
  }
  if (doc.fecha && doc.fecha !== hoyAR()) {
    avisos.push(`Se emite con fecha de hoy (${fFecha(hoyAR())}), no con la del borrador (${fFecha(doc.fecha)}).`)
  }
  return { bloqueos, avisos }
}

// Emite y avisa con un toast. Nunca lanza: devuelve la respuesta de la Edge Function
// ({ status, estado_fiscal, numero, cae, error, … }).
export async function emitirEnArca(tabla, id) {
  const r = await ArcaAPI.emitir(tabla, id)
  if (r.status === 200 && r.estado_fiscal === 'autorizado') {
    toast.success(`Autorizado por ARCA — N° ${r.numero} · CAE ${r.cae}`, { duration: 6000 })
  } else if (r.estado_fiscal === 'rechazado') {
    toast.error('ARCA rechazó el comprobante: revisá los errores en el detalle.')
  } else if (r.estado_fiscal === 'resultado_incierto') {
    toast.error('No se sabe si ARCA autorizó el comprobante: consultá el estado antes de reintentar.', { duration: 6000 })
  } else {
    toast.error(r.error || 'No se pudo emitir.')
  }
  return r
}

async function reconciliarEnArca(tabla, id) {
  const r = await ArcaAPI.reconciliar(tabla, id)
  if (r.status === 200 && r.estado_fiscal === 'autorizado') {
    toast.success(`ARCA ya lo había autorizado — N° ${r.numero} · CAE ${r.cae}`, { duration: 6000 })
  } else if (r.status === 200 && r.estado_fiscal === 'borrador') {
    toast.success('ARCA confirmó que no lo autorizó: se puede volver a emitir.')
  } else {
    toast.error(r.error || 'No se pudo consultar el estado.')
  }
  return r
}

// Lo que dijo la última acción y no queda en arca_solicitudes (validación del CRM, red, "esperá",
// CAE sin registrar), para que siga a la vista en el panel después del toast. Los rechazos, los
// errores antes de enviar y los inciertos sí quedan auditados y el panel los lee de ahí.
function avisoDe(r) {
  if (!r) return null
  if (r.status === 0) {
    return { tono: 'err', texto: `${r.error} La emisión pudo haber llegado a ARCA: mirá el estado antes de reintentar.` }
  }
  if (r.status === 422) return { tono: 'err', texto: `No se envió a ARCA: ${r.error}` }
  if (r.status === 401 || (r.status >= 500 && r.status !== 503)) return { tono: 'err', texto: r.error }
  if (r.status === 409) return { tono: 'warn', texto: r.error }
  // r.mensaje (reconciliación → borrador) no: queda auditado como no_autorizado y el panel ya lo muestra.
  if (r.recuperado) return { tono: 'ok', texto: `ARCA ya lo había autorizado: se recuperó el CAE ${r.cae} sin volver a emitir.` }
  return null
}

const fMensaje = (m) => (m.Code ? `${m.Code}: ${m.Msg}` : m.Msg)
const fMomento = (ts) => (ts ? new Date(ts).toLocaleString('es-AR', { dateStyle: 'short', timeStyle: 'short' }) : '')

function Mensajes({ titulo, lista, tono }) {
  if (!lista?.length) return null
  return (
    <div className={`arca-msg arca-msg-${tono}`}>
      {titulo && <div className="arca-msg-tit">{titulo}</div>}
      <ul>{lista.map((m, i) => <li key={i}>{typeof m === 'string' ? m : fMensaje(m)}</li>)}</ul>
    </div>
  )
}

/**
 * Panel de emisión de un comprobante (detalle de facturas y notas).
 *   tabla       'facturas' | 'notas'
 *   doc         fila de facturas_list / notas_list
 *   respuesta   respuesta de una emisión hecha antes de abrir el panel (desde el formulario)
 *   onCambio    el estado pudo cambiar: el padre vuelve a leer el comprobante y la lista
 *   onEditar / onDescartar   para borradores y rechazados
 *   onOcupado(bool)          mientras habla con ARCA, el padre no deja cerrar el modal
 */
export function PanelArca({ tabla, doc, respuesta = null, onCambio, onEditar, onDescartar, onOcupado }) {
  const [sol, setSol]         = useState(null)   // arca_solicitud_ultimo
  const [version, setVersion] = useState(0)
  const [accion, setAccion]   = useState(null)   // 'emitir' | 'reconciliar' mientras corre
  const [aviso, setAviso]     = useState(() => avisoDe(respuesta))
  const historico = doc.estado_fiscal === 'historico'

  useEffect(() => {
    if (historico) return
    let vigente = true
    ArcaAPI.solicitud(tabla, doc.id).then(s => { if (vigente) setSol(s) }).catch(() => {})
    return () => { vigente = false }
  }, [tabla, doc.id, doc.estado_fiscal, historico, version])

  if (historico) {
    return (
      <div className="arca-panel arca-panel-historico">
        <div className="arca-panel-head">
          <span className="arca-panel-tit">ARCA</span>
          <span className="arca-panel-txt">
            Registro histórico: se emitió fuera del CRM (web de ARCA) y no tiene CAE registrado en el CRM.
          </span>
        </div>
      </div>
    )
  }

  const estado = sol?.estado_fiscal ?? doc.estado_fiscal
  const cae = sol?.cae ?? doc.cae
  const ultimo = sol?.ultimo
  const ocupado = accion !== null
  const { bloqueos, avisos } = EDITABLES.includes(estado) ? revisarEmision(tabla, doc) : { bloqueos: [], avisos: [] }

  const ejecutar = async (tipo) => {
    setAccion(tipo)
    setAviso(null)
    onOcupado?.(true)
    try {
      const r = tipo === 'emitir' ? await emitirEnArca(tabla, doc.id) : await reconciliarEnArca(tabla, doc.id)
      setAviso(avisoDe(r))
    } finally {
      setAccion(null)
      onOcupado?.(false)
      setVersion(v => v + 1)
      onCambio?.()
    }
  }
  const actualizar = () => { setVersion(v => v + 1); onCambio?.() }

  const TEXTO = {
    borrador:   'Todavía no se envió a ARCA. No suma a saldos ni informes hasta tener CAE.',
    rechazado:  'ARCA rechazó el comprobante. Corregilo y volvé a emitirlo, o descartalo.',
    en_proceso: 'Se está emitiendo. Si en unos minutos sigue así, consultá el estado.',
    resultado_incierto:
      `No se sabe si ARCA lo autorizó${sol?.arca_nro_tentativo ? ` (N° tentativo ${sol.arca_nro_tentativo})` : ''}. ` +
      'Consultá el estado antes de cualquier otro paso: hasta entonces no se puede reenviar, modificar ni ' +
      'descartar, y no se emite otro comprobante de este tipo.',
    autorizado: tabla === 'facturas'
      ? 'No se puede modificar ni anular: se corrige con una Nota de Crédito o Débito.'
      : 'No se puede modificar.',
  }

  return (
    <div className={`arca-panel arca-panel-${estado}`}>
      <div className="arca-panel-head">
        <span className="arca-panel-tit">ARCA</span>
        <FiscalBadge estado={estado} cae={cae} />
        <span className="arca-panel-txt">{TEXTO[estado]}</span>
      </div>

      {estado === 'autorizado' && (
        <div className="arca-datos">
          <span>N° <b className="code">{doc.numero}</b></span>
          <span>CAE <b className="code">{cae}</b></span>
          {sol?.cae_vencimiento && <span>Vence {fFecha(sol.cae_vencimiento)}</span>}
        </div>
      )}

      {/* Último intento, tal cual lo devolvió ARCA */}
      {estado === 'rechazado' && ultimo && (
        <>
          <Mensajes tono="err" titulo={`Errores de ARCA (${fMomento(ultimo.fecha)})`} lista={ultimo.errores} />
          <Mensajes tono="warn" titulo="Observaciones" lista={ultimo.observaciones} />
        </>
      )}
      {estado === 'autorizado' && ultimo?.resultado === 'autorizado' && (
        <Mensajes tono="warn" titulo="ARCA lo autorizó con observaciones" lista={ultimo.observaciones} />
      )}
      {estado === 'resultado_incierto' && ultimo?.resultado === 'incierto' && (
        <Mensajes tono="warn" titulo={`Último intento (${fMomento(ultimo.fecha)})`} lista={ultimo.errores} />
      )}
      {estado === 'borrador' && ultimo?.resultado === 'error_previo' && (
        <Mensajes tono="warn" titulo={`El último intento no llegó a enviarse a ARCA (${fMomento(ultimo.fecha)})`} lista={ultimo.errores} />
      )}
      {estado === 'borrador' && ultimo?.resultado === 'no_autorizado' && (
        <Mensajes tono="ok" lista={[`ARCA confirmó que el intento anterior no se autorizó (${fMomento(ultimo.fecha)}): se puede volver a emitir.`]} />
      )}

      <Mensajes tono="err" titulo="No se puede emitir" lista={bloqueos} />
      <Mensajes tono="warn" lista={avisos} />
      {aviso && <Mensajes tono={aviso.tono} lista={[aviso.texto]} />}

      {ocupado && (
        <div className="arca-ocupado">
          <span className="arca-spinner" aria-hidden />
          {accion === 'emitir'
            ? 'Emitiendo en ARCA… puede tardar hasta 15 segundos. No cierres esta ventana.'
            : 'Consultando a ARCA…'}
        </div>
      )}

      {estado !== 'autorizado' && (
        <div className="arca-panel-acciones">
          {estado === 'borrador' && (
            <>
              <button className="btn btn-primary btn-sm" disabled={ocupado || bloqueos.length > 0} onClick={() => ejecutar('emitir')}>
                ⚡ Emitir en ARCA
              </button>
              {onEditar && <button className="btn btn-secondary btn-sm" disabled={ocupado} onClick={onEditar}>Editar</button>}
              {onDescartar && <button className="btn btn-secondary btn-sm arca-btn-descartar" disabled={ocupado} onClick={onDescartar}>Descartar</button>}
            </>
          )}
          {estado === 'rechazado' && (
            <>
              {onEditar && <button className="btn btn-primary btn-sm" disabled={ocupado} onClick={onEditar}>Corregir</button>}
              <button className="btn btn-secondary btn-sm" disabled={ocupado || bloqueos.length > 0} onClick={() => ejecutar('emitir')}>
                Reintentar emisión
              </button>
              {onDescartar && <button className="btn btn-secondary btn-sm arca-btn-descartar" disabled={ocupado} onClick={onDescartar}>Descartar</button>}
            </>
          )}
          {(estado === 'resultado_incierto' || estado === 'en_proceso') && (
            <button className="btn btn-primary btn-sm" disabled={ocupado} onClick={() => ejecutar('reconciliar')}>
              Consultar estado en ARCA
            </button>
          )}
          {estado === 'en_proceso' && (
            <button className="btn btn-secondary btn-sm" disabled={ocupado} onClick={actualizar}>Actualizar</button>
          )}
        </div>
      )}
    </div>
  )
}

// Franja de la bandeja fiscal arriba de una lista (§5): cuántos hay sin CAE, con atajos al filtro.
// Los inciertos van primero y destacados: bloquean su serie hasta reconciliarlos. `recarga` es
// cualquier valor que cambie cuando la lista se recarga (las filas), para volver a contar.
export function BandejaArca({ tabla, recarga, onFiltrar }) {
  const [b, setB] = useState(null)
  useEffect(() => {
    let vigente = true
    ArcaAPI.bandeja().then(r => { if (vigente) setB(r?.[tabla] ?? null) }).catch(() => {})
    return () => { vigente = false }
  }, [tabla, recarga])
  if (!b) return null

  const plural = (n, uno, varios) => `${n} ${n === 1 ? uno : varios}`
  const grupos = [
    ['resultado_incierto', plural(b.resultado_incierto, 'con resultado incierto', 'con resultado incierto')],
    ['en_proceso',         plural(b.en_proceso, 'en emisión', 'en emisión')],
    ['rechazado',          plural(b.rechazado, 'rechazada', 'rechazadas')],
    ['borrador',           plural(b.borrador, 'borrador', 'borradores')],
  ].filter(([k]) => b[k] > 0)
  if (!grupos.length) return null

  const urgente = b.resultado_incierto > 0
  return (
    <div className={`arca-bandeja${urgente ? ' is-urgente' : ''}`}>
      <span className="arca-bandeja-tit">{tabla === 'facturas' ? 'Facturas' : 'Notas'} sin CAE:</span>
      {grupos.map(([k, texto]) => (
        <button key={k} type="button" className={`arca-chip arca-chip-${k}`} onClick={() => onFiltrar?.(k)}>{texto}</button>
      ))}
      {urgente && (
        <span className="arca-bandeja-nota">Las de resultado incierto bloquean su tipo de comprobante: consultá el estado antes de emitir otra.</span>
      )}
    </div>
  )
}

// ── Ambiente ─────────────────────────────────────────────────────
// /arca/estado una vez por pestaña: el ambiente no cambia sin un redeploy. Si falla se vuelve a
// pedir en el próximo montaje.
let estadoArca = null
function pedirEstado() {
  if (!estadoArca) {
    estadoArca = ArcaAPI.estado().then(r => {
      if (r.status !== 200) estadoArca = null
      return r
    })
  }
  return estadoArca
}

export function useArcaEstado() {
  const [estado, setEstado] = useState(null)
  useEffect(() => {
    let vigente = true
    pedirEstado().then(r => { if (vigente) setEstado(r) })
    return () => { vigente = false }
  }, [])
  return estado
}

// Franja fija en la app conectada a homologación. El ambiente lo informa la función desplegada
// (secret ARCA_AMBIENTE de ese proyecto), no una preferencia de la UI.
export function BannerAmbiente({ estado }) {
  if (estado?.ambiente !== 'homologacion') return null
  return (
    <div className="arca-banner" role="status">
      HOMOLOGACIÓN — ARCA de prueba (PV {estado.punto_venta}): lo que se emite acá no tiene validez fiscal.
    </div>
  )
}

// Indicador de la barra superior: verde si ARCA responde (FEDummy) y hay ticket de WSAA.
export function IndicadorArca({ estado }) {
  if (!estado) return null
  const ok = estado.status === 200 && estado.fedummy?.ok && estado.wsaa?.ok
  const titulo = estado.status !== 200
    ? `ARCA: ${estado.error || 'sin respuesta'}`
    : [
        `ARCA ${estado.ambiente} · PV ${estado.punto_venta}`,
        `WSFE: ${estado.fedummy?.ok ? 'OK' : estado.fedummy?.error}`,
        `WSAA: ${estado.wsaa?.ok ? 'OK' : estado.wsaa?.error}`,
      ].join('\n')
  return (
    <span className={`arca-pill ${ok ? 'is-ok' : 'is-err'}`} title={titulo}>
      <span className="arca-pill-dot" aria-hidden />
      ARCA{estado.ambiente === 'homologacion' ? ' · homologación' : ''}
    </span>
  )
}
