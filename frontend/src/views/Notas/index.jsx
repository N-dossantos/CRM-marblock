// src/views/Notas/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { NotasAPI, FacturasAPI, ProductosAPI, AlicuotasIvaAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Badge, Loading, EmptyState, Modal, ItemsTable, TotalesBox } from '../../components/UI'
import NotaForm from './NotaForm'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

export default function Notas() {
  const [rows, setRows]         = useState([])
  const [loading, setLoading]   = useState(true)
  const [productos, setProductos] = useState([])
  const [alicuotas, setAlicuotas] = useState([])
  const [search, setSearch]     = useState('')
  const [filtroTipo, setFiltroTipo] = useState('')
  const [nueva, setNueva]       = useState(null) // { factura }
  const [detalle, setDetalle]   = useState(null) // nota completa
  const [pdfModal, setPdfModal] = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    NotasAPI.list({ q: search, tipo: filtroTipo }).then(setRows).finally(() => setLoading(false))
  }, [search, filtroTipo])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    ProductosAPI.list({ activo: true }).then(setProductos)
    AlicuotasIvaAPI.list().then(setAlicuotas)
  }, [])

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
  // últimos 60 días; con texto se busca en el servidor por número, cliente o CUIT.
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
      FacturasAPI.list(q.length >= 2 ? { q } : { desde: hace60.toISOString().split('T')[0] })
        .then(fs => { if (vigente) setFacturas(fs.filter(f => f.estado !== 'anulada').slice(0, 50)) })
        .finally(() => { if (vigente) setBuscandoFac(false) })
    }, q ? 300 : 0)
    return () => { vigente = false; clearTimeout(t) }
  }, [nueva !== null, nueva?.facturaObj, busqFac])

  const save = async (payload) => {
    await NotasAPI.create(payload)
    toast.success('Nota guardada correctamente')
    setNueva(null)
    load()
  }

  const openDetalle = (id) => NotasAPI.get(id).then(setDetalle)

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
        </div>
        <button className="btn btn-primary" onClick={abrirNueva}>+ Nueva nota C/D</button>
      </div>

      <div className="info-box">
        Las notas de crédito y débito siempre deben estar vinculadas a una factura existente. También pueden generarse directamente desde el listado de Facturas.
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Tipo</th><th>Fecha</th><th>Factura orig.</th>
                <th>Cliente</th><th>Motivo</th>
                <th className="th-right">Neto</th><th className="th-right">IVA 21%</th><th className="th-right">Total</th>
                <th style={{ width: 80 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0
                ? <EmptyState icon="📝" message="Sin notas. Generarlas desde Facturas o desde el botón + Nueva nota C/D." />
                : rows.map(n => (
                  <tr key={n.id}>
                    <td><span className="code">{n.numero}</span></td>
                    <td><Badge estado={n.tipo} /></td>
                    <td>{fFecha(n.fecha)}</td>
                    <td><span className="code">{n.factura_numero}</span></td>
                    <td className="td-bold">{n.razon_social}</td>
                    <td style={{ fontSize: 12, color: 'var(--gray-500)', maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{n.motivo || '—'}</td>
                    <td className="td-right" style={{ color: 'var(--gray-500)' }}>{$ar(n.neto_gravado)}</td>
                    <td className="td-right" style={{ color: 'var(--gray-500)' }}>{$ar(n.iva_monto)}</td>
                    <td className="td-right td-bold">{$ar(n.total)}</td>
                    <td><div style={{ display: 'flex', gap: 4 }}>
                      <button className="btn btn-ghost btn-xs" onClick={() => openDetalle(n.id)}>Ver</button>
                      <button className="btn btn-secondary btn-xs" style={{ background: 'var(--red-50)', color: 'var(--red-600)', borderColor: 'var(--red-100)' }} onClick={() => setPdfModal({ url: `/api/pdf/nota/${n.id}`, titulo: `${n.tipo === 'NC' ? 'Nota de Crédito' : 'Nota de Débito'} ${n.numero}` })}>📄 PDF</button>
                    </div></td>
                  </tr>
                ))
              }
            </tbody>
          </table>
        )}
      </div>

      {/* Modal selector de factura → abre el form */}
      {nueva && !nueva.facturaObj && (
        <Modal title="Seleccionar factura de referencia" size="lg" onClose={() => setNueva(null)}>
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
                <Badge estado={f.estado} />
                <span style={{ fontWeight: 700, minWidth: 110, textAlign: 'right' }}>{$ar(f.total)}</span>
              </button>
            ))}
          </div>
          <p style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 8 }}>
            {busqFac.trim().length >= 2 ? 'Hasta 50 resultados, las más recientes primero.' : 'Facturas de los últimos 60 días. Escribí para buscar en toda la historia.'}
          </p>
        </Modal>
      )}

      {nueva?.facturaObj && (
        <NotaForm
          factura={nueva.facturaObj}
          productos={productos}
          alicuotas={alicuotas}
          onSave={save}
          onClose={() => setNueva(null)}
        />
      )}

      {/* Detalle de nota */}
      {detalle && (
        <Modal title={`${detalle.tipo === 'NC' ? 'Nota de Crédito' : 'Nota de Débito'} ${detalle.numero}`} size="lg" onClose={() => setDetalle(null)}
          footer={
            <div style={{ display: 'flex', gap: 8, width: '100%', justifyContent: 'space-between', alignItems: 'center' }}>
              <button
                className="btn btn-secondary btn-sm"
                style={{ background: 'var(--red-50)', color: 'var(--red-600)', borderColor: 'var(--red-100)' }}
                onClick={() => { setDetalle(null); setPdfModal({ url: `/api/pdf/nota/${detalle.id}`, titulo: `${detalle.tipo === 'NC' ? 'Nota de Crédito' : 'Nota de Débito'} ${detalle.numero}` }) }}
              >
                📄 Ver / Imprimir PDF
              </button>
              <button className="btn btn-secondary" onClick={() => setDetalle(null)}>Cerrar</button>
            </div>
          }
        >
          <div className="form-row2" style={{ marginBottom: 14 }}>
            <div><span className="lbl">Factura de referencia</span><p className="code">{detalle.factura_numero}</p></div>
            <div><span className="lbl">Cliente</span><p style={{ fontWeight: 600 }}>{detalle.razon_social}</p></div>
            <div><span className="lbl">Fecha</span><p>{fFecha(detalle.fecha)}</p></div>
            <div><span className="lbl">Motivo</span><p>{detalle.motivo || '—'}</p></div>
          </div>
          <ItemsTable items={detalle.items || []} readonly />
          <div style={{ marginTop: 12 }}>
            <TotalesBox items={detalle.items || []} dtoGeneral={0} />
          </div>
        </Modal>
      )}
      {pdfModal && <PDFModal url={pdfModal.url} titulo={pdfModal.titulo} onClose={() => setPdfModal(null)} />}
    </div>
  )
}
