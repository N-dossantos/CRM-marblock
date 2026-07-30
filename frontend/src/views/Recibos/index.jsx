// src/views/Recibos/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { RecibosAPI, ClientesAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Loading, EmptyState, Modal } from '../../components/UI'
import ReciboForm from '../../components/Forms/ReciboForm'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

const TIPO_LABEL = { efectivo: 'Efectivo', transferencia: 'Transferencia', cheque: 'Cheque', echeq: 'E-Cheq' }
const TIPO_COLOR = { efectivo: '#10b981', transferencia: '#1d4ed8', cheque: '#7c3aed', echeq: '#f97316' }

export default function Recibos() {
  const [rows, setRows]         = useState([])
  const [loading, setLoading]   = useState(true)
  const [clientes, setClientes] = useState([])
  const [search, setSearch]     = useState('')
  const [filtroCli, setFiltroCli] = useState('')
  const [nuevo, setNuevo]       = useState(false)
  const [detalle, setDetalle]   = useState(null)
  const [pdfModal, setPdfModal] = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    RecibosAPI.list({ q: search, cliente_id: filtroCli }).then(setRows).finally(() => setLoading(false))
  }, [search, filtroCli])

  useEffect(() => { load() }, [load])
  useEffect(() => { ClientesAPI.list().then(setClientes) }, [])

  const save = async (payload) => {
    await RecibosAPI.create(payload)
    toast.success('Recibo registrado correctamente')
    setNuevo(false)
    load()
  }

  const openDetalle = (id) => RecibosAPI.get(id).then(setDetalle)

  const totalGeneral = rows.reduce((a, r) => a + parseFloat(r.total || 0), 0)

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar recibo o cliente…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="sel" style={{ width: 220 }} value={filtroCli} onChange={e => setFiltroCli(e.target.value)}>
            <option value="">Todos los clientes</option>
            {clientes.map(c => <option key={c.id} value={c.id}>{c.razon_social}</option>)}
          </select>
        </div>
        <button className="btn btn-success" onClick={() => setNuevo(true)}>+ Nuevo recibo de cobro</button>
      </div>

      {/* Resumen rápido */}
      {rows.length > 0 && (
        <div style={{ display: 'flex', gap: 12, marginBottom: 16, flexWrap: 'wrap' }}>
          <div className="card" style={{ padding: '12px 18px', borderLeft: '4px solid #10b981', flex: 1, minWidth: 180 }}>
            <div className="kpi-label">Total cobrado (filtro actual)</div>
            <div className="kpi-value" style={{ color: '#10b981', fontSize: 20 }}>{$ar(totalGeneral)}</div>
          </div>
          <div className="card" style={{ padding: '12px 18px', borderLeft: '4px solid var(--blue-600)', flex: 1, minWidth: 180 }}>
            <div className="kpi-label">Cantidad de recibos</div>
            <div className="kpi-value" style={{ color: 'var(--blue-600)', fontSize: 20 }}>{rows.length}</div>
          </div>
        </div>
      )}

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Fecha</th><th>Cliente</th>
                <th>Facturas imputadas</th><th>Medios de pago</th>
                <th className="th-right">Total cobrado</th><th style={{ width: 80 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0
                ? <EmptyState icon="💵" message="Sin recibos registrados" />
                : rows.map(r => (
                  <tr key={r.id}>
                    <td><span className="code" style={{ fontWeight: 700 }}>{r.numero}</span></td>
                    <td>{fFecha(r.fecha)}</td>
                    <td className="td-bold">{r.razon_social}</td>
                    <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>
                      {r.facturas?.length > 0
                        ? r.facturas.map(f => <span key={f.factura_id} className="code" style={{ marginRight: 4 }}>{f.numero}</span>)
                        : <span style={{ color: 'var(--amber-600)' }}>Pago a cuenta</span>
                      }
                    </td>
                    <td>
                      <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                        {r.medios?.map((m, i) => (
                          <span key={i} style={{ background: `${TIPO_COLOR[m.tipo]}18`, color: TIPO_COLOR[m.tipo], padding: '2px 8px', borderRadius: 10, fontSize: 11, fontWeight: 700 }}>
                            {TIPO_LABEL[m.tipo]} {$ar(m.monto)}
                          </span>
                        ))}
                      </div>
                    </td>
                    <td className="td-right" style={{ color: '#10b981', fontWeight: 700, fontSize: 14 }}>{$ar(r.total)}</td>
                    <td><div style={{ display: 'flex', gap: 4 }}>
                      <button className="btn btn-ghost btn-xs" onClick={() => openDetalle(r.id)}>Ver</button>
                      <button className="btn btn-secondary btn-xs" style={{ background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }} onClick={() => setPdfModal({ url: `/api/pdf/recibo/${r.id}`, titulo: `Recibo ${r.numero}` })}>📄 PDF</button>
                    </div></td>
                  </tr>
                ))
              }
            </tbody>
          </table>
        )}
      </div>

      {nuevo && (
        <ReciboForm
          clientes={clientes}
          initial={{}}
          onSave={save}
          onClose={() => setNuevo(false)}
        />
      )}

      {detalle && (
        <Modal title={`Recibo ${detalle.numero}`} size="md" onClose={() => setDetalle(null)}
          footer={
            <div style={{ display: 'flex', gap: 8, width: '100%', justifyContent: 'space-between', alignItems: 'center' }}>
              <button
                className="btn btn-secondary btn-sm"
                style={{ background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }}
                onClick={() => { setDetalle(null); setPdfModal({ url: `/api/pdf/recibo/${detalle.id}`, titulo: `Recibo ${detalle.numero}` }) }}
              >
                📄 Ver / Imprimir PDF
              </button>
              <button className="btn btn-secondary" onClick={() => setDetalle(null)}>Cerrar</button>
            </div>
          }
        >
          <div className="form-row2" style={{ marginBottom: 16 }}>
            <div><span className="lbl">Fecha</span><p>{fFecha(detalle.fecha)}</p></div>
            <div><span className="lbl">Cliente</span><p className="td-bold">{detalle.razon_social}</p></div>
            <div><span className="lbl">CUIT</span><p className="td-mono">{detalle.cuit}</p></div>
            <div><span className="lbl">Observaciones</span><p style={{ color: 'var(--gray-500)', fontSize: 12 }}>{detalle.observaciones || '—'}</p></div>
          </div>

          {detalle.facturas?.length > 0 && (
            <>
              <div className="lbl" style={{ marginBottom: 8 }}>Facturas imputadas</div>
              <div style={{ border: '1px solid var(--gray-200)', borderRadius: 8, overflow: 'hidden', marginBottom: 14 }}>
                {detalle.facturas.map(f => (
                  <div key={f.factura_id} style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 14px', borderBottom: '1px solid var(--gray-100)' }}>
                    <span className="code">{f.numero}</span>
                  </div>
                ))}
              </div>
            </>
          )}

          <div className="lbl" style={{ marginBottom: 8 }}>Medios de pago</div>
          {detalle.medios?.map((m, i) => (
            <div key={i} className="medio-card" style={{ marginBottom: 8 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span style={{ fontWeight: 700, color: TIPO_COLOR[m.tipo] }}>{TIPO_LABEL[m.tipo]}</span>
                <span style={{ fontSize: 16, fontWeight: 800 }}>{$ar(m.monto)}</span>
              </div>
              {m.detalle && <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 4 }}>{m.detalle}</div>}
              {m.banco && (
                <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 4 }}>
                  Banco: {m.banco}{m.numero_cheque ? ` — Nro. ${m.numero_cheque}` : ''}{m.titular ? ` — Titular: ${m.titular}` : ''}
                  {m.fecha_vcto ? ` — Vence: ${fFecha(m.fecha_vcto)}` : ''}
                </div>
              )}
            </div>
          ))}

          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '12px 0 0', borderTop: '2px solid var(--gray-200)', marginTop: 8 }}>
            <span style={{ fontWeight: 700, fontSize: 15 }}>Total cobrado:</span>
            <span style={{ fontSize: 20, fontWeight: 800, color: '#10b981' }}>{$ar(detalle.total)}</span>
          </div>
        </Modal>
      )}
      {pdfModal && <PDFModal url={pdfModal.url} titulo={pdfModal.titulo} onClose={() => setPdfModal(null)} />}
    </div>
  )
}
