// src/views/ComprasNotas/index.jsx
// Notas de Crédito / Débito de COMPRA (Fase A). Espeja views/Notas: siempre ligadas a una
// factura de compra. El total lo calcula el server (multi-alícuota); el detalle muestra los
// totales persistidos en la cabecera (nota_compra no guarda desglose IVA por ítem).
import { useState, useEffect, useCallback } from 'react'
import { NotasCompraAPI, FacturasCompraAPI, MaterialesAPI, AlicuotasIvaAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Badge, Loading, EmptyState, Modal, ItemsTable } from '../../components/UI'
import NotaCompraForm from '../../components/Forms/NotaCompraForm'
import toast from 'react-hot-toast'

export default function ComprasNotas() {
  const [rows, setRows]           = useState([])
  const [loading, setLoading]     = useState(true)
  const [materiales, setMateriales]   = useState([])
  const [alicuotas, setAlicuotas]     = useState([])
  const [search, setSearch]       = useState('')
  const [filtroTipo, setFiltroTipo] = useState('')
  const [nueva, setNueva]         = useState(null)   // { selFacId, facturaObj }
  const [facturas, setFacturas]   = useState([])
  const [detalle, setDetalle]     = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    NotasCompraAPI.list({ q: search, tipo: filtroTipo }).then(setRows).finally(() => setLoading(false))
  }, [search, filtroTipo])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    MaterialesAPI.list({ activo: true }).then(setMateriales)
    AlicuotasIvaAPI.list().then(setAlicuotas)
  }, [])

  // Facturas de compra seleccionables (todas menos anuladas) al abrir el selector.
  useEffect(() => {
    if (nueva !== null) {
      FacturasCompraAPI.list().then(list => setFacturas(list.filter(f => f.estado !== 'anulada')))
    }
  }, [nueva !== null])

  const onFacSelect = async (facId) => {
    if (!facId) { setNueva(n => ({ ...n, facturaObj: null })); return }
    const fac = await FacturasCompraAPI.get(facId)
    setNueva(n => ({ ...n, selFacId: facId, facturaObj: fac }))
  }

  const save = async (payload) => {
    await NotasCompraAPI.create(payload)
    toast.success('Nota de compra guardada')
    setNueva(null); load()
  }

  const openDetalle = (id) => NotasCompraAPI.get(id).then(setDetalle)

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar por número, proveedor o factura…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="sel" style={{ width: 160 }} value={filtroTipo} onChange={e => setFiltroTipo(e.target.value)}>
            <option value="">NC y ND</option>
            <option value="NC">Solo Notas de Crédito</option>
            <option value="ND">Solo Notas de Débito</option>
          </select>
        </div>
        <button className="btn btn-primary" onClick={() => setNueva({ selFacId: null, facturaObj: null })}>+ Nueva nota C/D</button>
      </div>

      <div className="info-box">
        Las notas de crédito y débito de compra siempre se vinculan a una factura de compra existente. También pueden generarse desde el listado de Facturas de compra.
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Tipo</th><th>Fecha</th><th>Factura orig.</th>
                <th>Proveedor</th><th>Motivo</th>
                <th className="th-right">Neto</th><th className="th-right">IVA</th><th className="th-right">Total</th>
                <th style={{ width: 60 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0
                ? <EmptyState icon="📝" message="Sin notas de compra" />
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
                    <td><button className="btn btn-ghost btn-xs" onClick={() => openDetalle(n.id)}>Ver</button></td>
                  </tr>
                ))
              }
            </tbody>
          </table>
        )}
      </div>

      {/* Selector de factura → abre el form */}
      {nueva && !nueva.facturaObj && (
        <Modal title="Seleccionar factura de compra" size="md" onClose={() => setNueva(null)}>
          <div className="field">
            <label className="lbl">Factura de compra *</label>
            <select className="sel" value={nueva.selFacId || ''} onChange={e => onFacSelect(e.target.value)}>
              <option value="">— Seleccionar factura —</option>
              {facturas.map(f => (
                <option key={f.id} value={f.id}>{f.numero} — {f.razon_social} — {$ar(f.total)} — {fFecha(f.fecha)}</option>
              ))}
            </select>
          </div>
          <p style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 8 }}>
            Se muestran todas las facturas de compra no anuladas.
          </p>
        </Modal>
      )}

      {nueva?.facturaObj && (
        <NotaCompraForm
          factura={nueva.facturaObj}
          materiales={materiales}
          alicuotas={alicuotas}
          onSave={save}
          onClose={() => setNueva(null)}
        />
      )}

      {/* Detalle de nota */}
      {detalle && (
        <Modal title={`${detalle.tipo === 'NC' ? 'Nota de Crédito' : 'Nota de Débito'} ${detalle.numero}`} size="lg" onClose={() => setDetalle(null)}
          footer={<button className="btn btn-secondary" onClick={() => setDetalle(null)}>Cerrar</button>}
        >
          <div className="form-row2" style={{ marginBottom: 14 }}>
            <div><span className="lbl">Factura de compra</span><p className="code">{detalle.factura_numero}</p></div>
            <div><span className="lbl">Proveedor</span><p style={{ fontWeight: 600 }}>{detalle.razon_social}</p></div>
            <div><span className="lbl">Fecha</span><p>{fFecha(detalle.fecha)}</p></div>
            <div><span className="lbl">Motivo</span><p>{detalle.motivo || '—'}</p></div>
          </div>
          <ItemsTable items={detalle.items || []} readonly />
          <div style={{ marginTop: 12, borderTop: '2px solid var(--gray-200)', paddingTop: 12 }}>
            <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 24, fontSize: 13 }}>
              <span style={{ color: 'var(--gray-500)' }}>Neto: <strong style={{ color: 'var(--gray-800)' }}>{$ar(detalle.neto_gravado)}</strong></span>
              <span style={{ color: 'var(--gray-500)' }}>IVA: <strong style={{ color: 'var(--gray-800)' }}>{$ar(detalle.iva_monto)}</strong></span>
              <span style={{ fontWeight: 700 }}>Total: <span style={{ fontSize: 17, fontWeight: 800, color: 'var(--blue-600)' }}>{$ar(detalle.total)}</span></span>
            </div>
          </div>
        </Modal>
      )}
    </div>
  )
}
