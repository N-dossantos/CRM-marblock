// src/views/Notas/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { NotasAPI, FacturasAPI, ProductosAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Badge, Loading, EmptyState, Modal, ItemsTable, TotalesBox } from '../../components/UI'
import NotaForm from './NotaForm'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

export default function Notas() {
  const [rows, setRows]         = useState([])
  const [loading, setLoading]   = useState(true)
  const [productos, setProductos] = useState([])
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
  useEffect(() => { ProductosAPI.list({ activo: true }).then(setProductos) }, [])

  const abrirNueva = async () => {
    // Permite seleccionar la factura desde este panel también
    setNueva({ selFacId: null, facturaObj: null })
  }

  const onFacSelect = async (facId) => {
    if (!facId) { setNueva(n => ({ ...n, facturaObj: null })); return }
    const fac = await FacturasAPI.get(facId)
    setNueva(n => ({ ...n, selFacId: facId, facturaObj: fac }))
  }

  const [facturas, setFacturas] = useState([])
  useEffect(() => {
    if (nueva !== null) {
      FacturasAPI.list({ estado: 'pendiente' }).then(f1 =>
        FacturasAPI.list({ estado: 'cobrada' }).then(f2 =>
          FacturasAPI.list({ estado: 'parcial' }).then(f3 => {
            const merged = [...f1, ...f2, ...f3]
            const unique = merged.filter((v,i,a) => a.findIndex(x => x.id === v.id) === i)
            setFacturas(unique)
          })
        )
      )
    }
  }, [nueva !== null])

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
                      <button className="btn btn-secondary btn-xs" style={{ background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }} onClick={() => setPdfModal({ url: `/api/pdf/nota/${n.id}`, titulo: `${n.tipo === 'NC' ? 'Nota de Crédito' : 'Nota de Débito'} ${n.numero}` })}>📄 PDF</button>
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
        <Modal title="Seleccionar factura de referencia" size="md" onClose={() => setNueva(null)}>
          <div className="field">
            <label className="lbl">Factura *</label>
            <select className="sel" value={nueva.selFacId || ''} onChange={e => onFacSelect(e.target.value)}>
              <option value="">— Seleccionar factura —</option>
              {facturas.map(f => (
                <option key={f.id} value={f.id}>{f.numero} — {f.razon_social} — {$ar(f.total)} — {fFecha(f.fecha)}</option>
              ))}
            </select>
          </div>
          <p style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 8 }}>
            Se muestran facturas en estado pendiente, cobrada parcial y cobrada.
          </p>
        </Modal>
      )}

      {nueva?.facturaObj && (
        <NotaForm
          factura={nueva.facturaObj}
          productos={productos}
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
                style={{ background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }}
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
