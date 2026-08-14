// src/views/ComprasPagos/index.jsx
// Pagos a proveedor (Fase A). Espejo de views/Recibos en sentido contrario: dinero que SALE.
// "+ Nuevo pago" abre PagoProveedorForm (medios multi-modales + imputación a facturas +
// retenciones). Sin PDF por ahora.
import { useState, useEffect, useCallback } from 'react'
import { PagosProveedorAPI, ProveedoresAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Loading, EmptyState, Modal } from '../../components/UI'
import PagoProveedorForm from '../../components/Forms/PagoProveedorForm'
import toast from 'react-hot-toast'

const TIPO_LABEL = { efectivo: 'Efectivo', transferencia: 'Transferencia', cheque_propio: 'Cheque propio', cheque_tercero: 'Cheque cartera' }
const TIPO_COLOR = { efectivo: '#10b981', transferencia: '#1d4ed8', cheque_propio: '#7c3aed', cheque_tercero: '#f97316' }

export default function ComprasPagos() {
  const [rows, setRows]           = useState([])
  const [loading, setLoading]     = useState(true)
  const [proveedores, setProveedores] = useState([])
  const [search, setSearch]       = useState('')
  const [filtroProv, setFiltroProv] = useState('')
  const [nuevo, setNuevo]         = useState(false)
  const [detalle, setDetalle]     = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    PagosProveedorAPI.list({ q: search, proveedor_id: filtroProv || undefined }).then(setRows).finally(() => setLoading(false))
  }, [search, filtroProv])

  useEffect(() => { load() }, [load])
  useEffect(() => { ProveedoresAPI.list().then(setProveedores) }, [])

  const save = async (payload) => {
    await PagosProveedorAPI.create(payload)
    toast.success('Pago registrado correctamente')
    setNuevo(false); load()
  }

  const openDetalle = (id) => PagosProveedorAPI.get(id).then(setDetalle)

  const totalGeneral = rows.reduce((a, r) => a + parseFloat(r.total || 0), 0)

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar pago o proveedor…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="sel" style={{ width: 220 }} value={filtroProv} onChange={e => setFiltroProv(e.target.value)}>
            <option value="">Todos los proveedores</option>
            {proveedores.map(p => <option key={p.id} value={p.id}>{p.razon_social}</option>)}
          </select>
        </div>
        <button className="btn btn-success" onClick={() => setNuevo(true)}>+ Nuevo pago a proveedor</button>
      </div>

      {rows.length > 0 && (
        <div style={{ display: 'flex', gap: 12, marginBottom: 16, flexWrap: 'wrap' }}>
          <div className="card" style={{ padding: '12px 18px', borderLeft: '4px solid #f97316', flex: 1, minWidth: 180 }}>
            <div className="kpi-label">Total pagado (filtro actual)</div>
            <div className="kpi-value" style={{ color: '#f97316', fontSize: 20 }}>{$ar(totalGeneral)}</div>
          </div>
          <div className="card" style={{ padding: '12px 18px', borderLeft: '4px solid var(--blue-600)', flex: 1, minWidth: 180 }}>
            <div className="kpi-label">Cantidad de pagos</div>
            <div className="kpi-value" style={{ color: 'var(--blue-600)', fontSize: 20 }}>{rows.length}</div>
          </div>
        </div>
      )}

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Fecha</th><th>Proveedor</th>
                <th>Facturas imputadas</th><th>Medios de pago</th>
                <th className="th-right">Total</th><th style={{ width: 60 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0
                ? <EmptyState icon="💸" message="Sin pagos registrados" />
                : rows.map(r => (
                  <tr key={r.id}>
                    <td><span className="code" style={{ fontWeight: 700 }}>{r.numero}</span></td>
                    <td>{fFecha(r.fecha)}</td>
                    <td className="td-bold">{r.razon_social}</td>
                    <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>
                      {r.facturas?.length > 0
                        ? r.facturas.map(f => <span key={f.factura_compra_id} className="code" style={{ marginRight: 4 }}>{f.numero}</span>)
                        : <span style={{ color: 'var(--amber-600)' }}>Pago a cuenta</span>
                      }
                    </td>
                    <td>
                      <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                        {r.medios?.map((m, i) => (
                          <span key={i} style={{ background: `${TIPO_COLOR[m.tipo]}18`, color: TIPO_COLOR[m.tipo], padding: '2px 8px', borderRadius: 10, fontSize: 11, fontWeight: 700 }}>
                            {TIPO_LABEL[m.tipo] || m.tipo} {$ar(m.monto)}
                          </span>
                        ))}
                      </div>
                    </td>
                    <td className="td-right" style={{ color: '#f97316', fontWeight: 700, fontSize: 14 }}>{$ar(r.total)}</td>
                    <td><button className="btn btn-ghost btn-xs" onClick={() => openDetalle(r.id)}>Ver</button></td>
                  </tr>
                ))
              }
            </tbody>
          </table>
        )}
      </div>

      {nuevo && (
        <PagoProveedorForm
          proveedores={proveedores}
          initial={{}}
          onSave={save}
          onClose={() => setNuevo(false)}
        />
      )}

      {detalle && (
        <Modal title={`Pago ${detalle.numero}`} size="md" onClose={() => setDetalle(null)}
          footer={<button className="btn btn-secondary" onClick={() => setDetalle(null)}>Cerrar</button>}
        >
          <div className="form-row2" style={{ marginBottom: 16 }}>
            <div><span className="lbl">Fecha</span><p>{fFecha(detalle.fecha)}</p></div>
            <div><span className="lbl">Proveedor</span><p className="td-bold">{detalle.razon_social}</p></div>
            <div><span className="lbl">CUIT</span><p className="td-mono">{detalle.cuit}</p></div>
            <div><span className="lbl">Observaciones</span><p style={{ color: 'var(--gray-500)', fontSize: 12 }}>{detalle.observaciones || '—'}</p></div>
          </div>

          {detalle.facturas?.length > 0 && (
            <>
              <div className="lbl" style={{ marginBottom: 8 }}>Facturas imputadas</div>
              <div style={{ border: '1px solid var(--gray-200)', borderRadius: 8, overflow: 'hidden', marginBottom: 14 }}>
                {detalle.facturas.map(f => (
                  <div key={f.factura_compra_id} style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 14px', borderBottom: '1px solid var(--gray-100)' }}>
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
                <span style={{ fontWeight: 700, color: TIPO_COLOR[m.tipo] }}>{TIPO_LABEL[m.tipo] || m.tipo}</span>
                <span style={{ fontSize: 16, fontWeight: 800 }}>{$ar(m.monto)}</span>
              </div>
              {m.detalle && <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 4 }}>{m.detalle}</div>}
            </div>
          ))}

          {detalle.retenciones?.length > 0 && (
            <>
              <div className="lbl" style={{ margin: '14px 0 8px' }}>Retenciones</div>
              {detalle.retenciones.map((r, i) => (
                <div key={i} style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 14px', border: '1px solid var(--gray-100)', borderRadius: 6, marginBottom: 6, fontSize: 13 }}>
                  <span>{r.tipo_retencion}{r.jurisdiccion ? ` — ${r.jurisdiccion}` : ''} ({r.alicuota}%)</span>
                  <span style={{ fontWeight: 700 }}>{$ar(r.monto)}</span>
                </div>
              ))}
            </>
          )}

          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '12px 0 0', borderTop: '2px solid var(--gray-200)', marginTop: 8 }}>
            <span style={{ fontWeight: 700, fontSize: 15 }}>Total pagado:</span>
            <span style={{ fontSize: 20, fontWeight: 800, color: '#f97316' }}>{$ar(detalle.total)}</span>
          </div>
        </Modal>
      )}
    </div>
  )
}
