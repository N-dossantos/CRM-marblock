// src/views/Notas/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { useSearchParams } from 'react-router-dom'
import { NotasAPI, FacturasAPI, ProductosAPI, AlicuotasIvaAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Badge, Loading, EmptyState, Modal, RowActions } from '../../components/UI'
import { FiscalBadge, PanelArca, BandejaArca, FILTROS_ARCA, estadosDeFiltro, esEditable, emitirEnArca, FISCALES } from '../../components/Arca'
import NotaForm from './NotaForm'
import VentaDetalle from '../../components/Consultas/VentaDetalle'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

const nombreNota = (n) => `${n.tipo === 'NC' ? 'Nota de Crédito' : 'Nota de Débito'} ${n.tipo_letra || ''}`.trim()

// Como las facturas, una nota nace borrador y ajusta el saldo de su factura recién con su propio
// CAE (PLAN_ARCA.md §4). La lista no es paginada (son pocas): el filtro de ARCA se aplica acá.
export default function Notas() {
  const [params, setParams] = useSearchParams()
  const [rows, setRows]         = useState([])
  const [loading, setLoading]   = useState(true)
  const [productos, setProductos] = useState([])
  const [alicuotas, setAlicuotas] = useState([])
  const [search, setSearch]     = useState('')
  const [filtroTipo, setFiltroTipo] = useState('')
  const [filtroArca, setFiltroArca] = useState(() => params.get('arca') || '')
  const [nueva, setNueva]       = useState(null) // { selFacId, facturaObj }
  const [editando, setEditando] = useState(null) // { nota, factura }: borrador o rechazada a corregir
  const [detalle, setDetalle]   = useState(null) // { _doc: 'nota', ...fila, _arca: respuesta de la emisión }
  const [arcaOcupado, setArcaOcupado] = useState(false)
  const [pdfModal, setPdfModal] = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    return NotasAPI.list({ q: search, tipo: filtroTipo }).then(setRows).finally(() => setLoading(false))
  }, [search, filtroTipo])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    ProductosAPI.list({ activo: true }).then(setProductos)
    AlicuotasIvaAPI.list().then(setAlicuotas)
  }, [])

  const estadosArca = estadosDeFiltro(filtroArca)
  const visibles = estadosArca ? rows.filter(n => estadosArca.includes(n.estado_fiscal)) : rows

  const abrirDetalle = useCallback((id, respuesta = null) =>
    NotasAPI.get(id).then(n => n && setDetalle({ _doc: 'nota', ...n, _arca: respuesta })), [])

  // Llegada desde Facturas cuando la emisión de una NC/ND no salió: /notas?ver=<id>.
  useEffect(() => {
    const ver = params.get('ver')
    if (!ver) return
    abrirDetalle(+ver)
    const resto = new URLSearchParams(params)
    resto.delete('ver')
    setParams(resto, { replace: true })
  }, [params, setParams, abrirDetalle])

  const refrescarDetalle = () => {
    if (detalle) NotasAPI.get(detalle.id).then(n => n && setDetalle(d => (d?.id === n.id ? { ...d, ...n } : d)))
    load()
  }
  const cerrarDetalle = () => { if (!arcaOcupado) setDetalle(null) }

  const abrirNueva = async () => {
    // Permite seleccionar la factura desde este panel también
    setBusqFac('')
    setNueva({ selFacId: null, facturaObj: null })
  }

  const onFacSelect = async (facId) => {
    if (!facId) { setNueva(n => ({ ...n, facturaObj: null })); return }
    const fac = await FacturasAPI.get(facId)
    setNueva(n => ({ ...n, selFacId: facId, facturaObj: fac }))
  }

  // Buscador de la factura a imputar. Con la historia de Tango son ~4.500 facturas: un desplegable
  // con todas no se puede usar (y PostgREST corta en 1.000). Sin texto se ofrecen las de los
  // últimos 60 días; con texto se busca en el servidor por número, cliente o CUIT. Sólo facturas
  // con CAE o históricas: crear_nota rechaza las demás.
  const [facturas, setFacturas] = useState([])
  const [busqFac, setBusqFac]   = useState('')
  const [buscandoFac, setBuscandoFac] = useState(false)
  useEffect(() => {
    if (nueva === null || nueva.facturaObj) return
    const q = busqFac.trim()
    let vigente = true
    const t = setTimeout(() => {
      setBuscandoFac(true)
      const hace60 = new Date(); hace60.setDate(hace60.getDate() - 60)
      FacturasAPI.list({ ...(q.length >= 2 ? { q } : { desde: hace60.toISOString().split('T')[0] }), estado_fiscal: FISCALES })
        .then(fs => { if (vigente) setFacturas(fs.filter(f => f.estado !== 'anulada').slice(0, 50)) })
        .finally(() => { if (vigente) setBuscandoFac(false) })
    }, q ? 300 : 0)
    return () => { vigente = false; clearTimeout(t) }
  }, [nueva !== null, nueva?.facturaObj, busqFac])

  // Guarda el borrador (nuevo o corregido) y, si se pidió, lo emite. Si ARCA no autoriza, se abre
  // el detalle con el panel que muestra el rechazo o el resultado incierto.
  const save = async (payload, { emitir = false } = {}) => {
    const n = editando
      // Las percepciones vuelven tal cual: el formulario no las edita y sin ellas la RPC las borra.
      ? await NotasAPI.update(editando.nota.id, { ...payload, percepciones: editando.nota.percepciones })
      : await NotasAPI.create(payload)
    let r = null
    try {
      if (emitir) r = await emitirEnArca('notas', n.id)
    } finally {
      setNueva(null); setEditando(null); load()
    }
    if (!emitir) toast.success(editando ? 'Borrador actualizado' : 'Borrador guardado: falta emitirlo en ARCA')
    else if (!(r?.status === 200 && r.estado_fiscal === 'autorizado')) abrirDetalle(n.id, r)
  }

  const editar = async (n) => {
    const factura = await FacturasAPI.get(n.factura_id)
    setDetalle(null)
    setEditando({ nota: n, factura })
  }

  const descartar = async (n) => {
    if (!confirm(`¿Descartar el borrador de ${nombreNota(n)} a ${n.razon_social} por ${$ar(n.total)}? Se borra con sus ítems.`)) return
    await NotasAPI.descartar(n.id)
    toast.success('Borrador descartado')
    setDetalle(null)
    load()
  }

  const verPdf = (n) => setPdfModal({ url: `/api/pdf/nota/${n.id}`, titulo: `${nombreNota(n)} ${n.numero || `borrador #${n.id}`}` })

  const accionPrincipal = (n) => {
    switch (n.estado_fiscal) {
      case 'borrador':           return { label: 'Emitir', icon: '⚡', onClick: () => abrirDetalle(n.id) }
      case 'rechazado':          return { label: 'Corregir', icon: '✎', tone: 'warn', onClick: () => editar(n) }
      case 'resultado_incierto':
      case 'en_proceso':         return { label: 'Consultar', icon: '⟳', tone: 'warn', onClick: () => abrirDetalle(n.id) }
      default:                   return null
    }
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar por número, cliente o factura…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="sel" style={{ width: 160 }} value={filtroTipo} onChange={e => setFiltroTipo(e.target.value)}>
            <option value="">NC y ND</option>
            <option value="NC">Solo Notas de Crédito</option>
            <option value="ND">Solo Notas de Débito</option>
          </select>
          <select className="sel" style={{ width: 170 }} value={filtroArca} onChange={e => setFiltroArca(e.target.value)}>
            {FILTROS_ARCA.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
          </select>
        </div>
        <button className="btn btn-primary" onClick={abrirNueva}>+ Nueva nota C/D</button>
      </div>

      <div className="info-box">
        Las notas de crédito y débito siempre deben estar vinculadas a una factura con CAE o histórica. También pueden generarse directamente desde el listado de Facturas.
      </div>

      <BandejaArca tabla="notas" recarga={rows} onFiltrar={setFiltroArca} />

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Tipo</th><th>Fecha</th><th>Factura orig.</th>
                <th>Cliente</th><th>Motivo</th>
                <th className="th-right">Neto</th><th className="th-right">IVA</th><th className="th-right">Total</th>
                <th>ARCA</th><th className="th-right" style={{ width: 150 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {visibles.length === 0
                ? <EmptyState icon="📝" message="Sin notas. Generarlas desde Facturas o desde el botón + Nueva nota C/D." />
                : visibles.map(n => (
                  <tr key={n.id} className="tr-click" onClick={() => setDetalle({ _doc: 'nota', ...n })}>
                    <td>{n.numero
                      ? <span className="code">{n.numero}</span>
                      : <span className="sin-numero">sin número</span>}</td>
                    <td><Badge estado={n.tipo} /> <span style={{ fontSize: 11, color: 'var(--gray-500)' }}>{n.tipo_letra}</span></td>
                    <td>{fFecha(n.fecha)}</td>
                    <td><span className="code">{n.factura_numero}</span></td>
                    <td className="td-bold">{n.razon_social}</td>
                    <td style={{ fontSize: 12, color: 'var(--gray-500)', maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{n.motivo || '—'}</td>
                    <td className="td-right" style={{ color: 'var(--gray-500)' }}>{$ar(n.neto_gravado)}</td>
                    <td className="td-right" style={{ color: 'var(--gray-500)' }}>{$ar(n.iva_monto)}</td>
                    <td className="td-right td-bold">{$ar(n.total)}</td>
                    <td><FiscalBadge estado={n.estado_fiscal} cae={n.cae} /></td>
                    <td>
                      <RowActions
                        primary={accionPrincipal(n)}
                        onPdf={() => verPdf(n)}
                        items={[
                          { label: 'Ver detalle', icon: '👁', onClick: () => setDetalle({ _doc: 'nota', ...n }) },
                          { label: 'Editar borrador', icon: '✎', onClick: () => editar(n), hidden: !esEditable(n) },
                          { label: 'Descartar borrador', icon: '🗑', danger: true, onClick: () => descartar(n), hidden: !esEditable(n) },
                        ]}
                      />
                    </td>
                  </tr>
                ))
              }
            </tbody>
          </table>
        )}
      </div>

      {/* Modal selector de factura → abre el form */}
      {nueva && !nueva.facturaObj && (
        <Modal almanaque={false} title="Seleccionar factura de referencia" size="lg" onClose={() => setNueva(null)}>
          <div className="field">
            <label className="lbl">Buscar factura *</label>
            <input className="search-inp" style={{ width: '100%' }} autoFocus
              placeholder="Número (ej. 00002-00002150), cliente o CUIT…"
              value={busqFac} onChange={e => setBusqFac(e.target.value)} />
          </div>
          <div style={{ border: '1px solid var(--gray-200)', borderRadius: 8, maxHeight: 380, overflowY: 'auto' }}>
            {buscandoFac ? (
              <div style={{ padding: 20, textAlign: 'center', color: 'var(--gray-400)' }}>Buscando…</div>
            ) : facturas.length === 0 ? (
              <div style={{ padding: 20, textAlign: 'center', color: 'var(--gray-400)' }}>Sin facturas para esa búsqueda</div>
            ) : facturas.map(f => (
              <button key={f.id} type="button" onClick={() => onFacSelect(f.id)}
                style={{ display: 'flex', gap: 12, alignItems: 'center', width: '100%', padding: '9px 14px', border: 0, borderBottom: '1px solid var(--gray-100)', background: 'transparent', cursor: 'pointer', textAlign: 'left' }}>
                <span className="code">{f.numero}</span>
                <span style={{ fontSize: 12, color: 'var(--gray-500)' }}>{fFecha(f.fecha)}</span>
                <span style={{ flex: 1, fontWeight: 600 }}>{f.razon_social}</span>
                <FiscalBadge estado={f.estado_fiscal} cae={f.cae} />
                <Badge estado={f.estado} />
                <span style={{ fontWeight: 700, minWidth: 110, textAlign: 'right' }}>{$ar(f.total)}</span>
              </button>
            ))}
          </div>
          <p style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 8 }}>
            {busqFac.trim().length >= 2 ? 'Hasta 50 resultados, las más recientes primero.' : 'Facturas de los últimos 60 días. Escribí para buscar en toda la historia.'}
            {' '}Sólo facturas con CAE o históricas.
          </p>
        </Modal>
      )}

      {(nueva?.facturaObj || editando) && (
        <NotaForm
          factura={editando ? editando.factura : nueva.facturaObj}
          nota={editando?.nota ?? null}
          productos={productos}
          alicuotas={alicuotas}
          onSave={save}
          onClose={() => { setNueva(null); setEditando(null) }}
        />
      )}

      {detalle && (
        <VentaDetalle
          doc={detalle}
          onClose={cerrarDetalle}
          fiscal={
            <PanelArca
              key={detalle.id}
              tabla="notas"
              doc={detalle}
              respuesta={detalle._arca}
              onCambio={refrescarDetalle}
              onEditar={() => editar(detalle)}
              onDescartar={() => descartar(detalle)}
              onOcupado={setArcaOcupado}
            />
          }
        />
      )}
      {pdfModal && <PDFModal url={pdfModal.url} titulo={pdfModal.titulo} onClose={() => setPdfModal(null)} />}
    </div>
  )
}
