// src/views/ComprasFacturas/index.jsx
// Facturas de COMPRA (Fase A). Espeja views/Facturas pero: proveedor (no cliente),
// numeración del proveedor, IVA multi-alícuota, "Pagar" abre PagoProveedorForm y
// "NC/ND" abre NotaCompraForm. Sin PDF: los comprobantes de compra son del proveedor.
import { useState, useEffect, useCallback } from 'react'
import { FacturasCompraAPI, ProveedoresAPI, MaterialesAPI, AlicuotasIvaAPI, PagosProveedorAPI, NotasCompraAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Badge, Loading, EmptyState } from '../../components/UI'
import CompraComprobanteForm from '../../components/Forms/CompraComprobanteForm'
import PagoProveedorForm from '../../components/Forms/PagoProveedorForm'
import NotaCompraForm from '../../components/Forms/NotaCompraForm'
import toast from 'react-hot-toast'

export default function ComprasFacturas() {
  const [rows, setRows]           = useState([])
  const [loading, setLoading]     = useState(true)
  const [proveedores, setProveedores] = useState([])
  const [materiales, setMateriales]   = useState([])
  const [alicuotas, setAlicuotas]     = useState([])
  const [search, setSearch]       = useState('')
  const [filtroEst, setFiltroEst] = useState('')
  const [facForm, setFacForm]     = useState(null)  // { data, isNew }
  const [pagoFor, setPagoFor]     = useState(null)  // { provId, facIds, totalSugerido }
  const [notaFor, setNotaFor]     = useState(null)  // factura

  const load = useCallback(() => {
    setLoading(true)
    FacturasCompraAPI.list({ q: search, estado: filtroEst }).then(setRows).finally(() => setLoading(false))
  }, [search, filtroEst])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    ProveedoresAPI.list().then(setProveedores)
    MaterialesAPI.list({ activo: true }).then(setMateriales)
    AlicuotasIvaAPI.list().then(setAlicuotas)
  }, [])

  // Prefill al venir desde un remito de compra ("→ Factura").
  useEffect(() => {
    const fromRem = sessionStorage.getItem('crm_desde_remito_compra')
    if (fromRem) {
      const d = JSON.parse(fromRem)
      sessionStorage.removeItem('crm_desde_remito_compra')
      setFacForm({ data: d, isNew: true })
    }
  }, [])

  const save = async (payload) => {
    try {
      if (facForm.isNew) await FacturasCompraAPI.create(payload)
      else               await FacturasCompraAPI.update(facForm.data.id, payload)
      toast.success('Factura de compra guardada')
      setFacForm(null); load()
    } catch (err) { throw err }
  }

  const anular = async (id) => {
    if (!confirm('¿Anular esta factura de compra? Esta acción no se puede deshacer.')) return
    await FacturasCompraAPI.anular(id)
    toast.success('Factura anulada')
    load()
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar factura, proveedor o CUIT…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="sel" style={{ width: 170 }} value={filtroEst} onChange={e => setFiltroEst(e.target.value)}>
            <option value="">Todos los estados</option>
            <option value="pendiente">Pendiente</option>
            <option value="parcial">Pago parcial</option>
            <option value="pagada">Pagada</option>
            <option value="anulada">Anulada</option>
          </select>
        </div>
        <button className="btn btn-primary" onClick={() => setFacForm({ data: {}, isNew: true })}>+ Nueva factura</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Tipo</th><th>Fecha</th><th>Proveedor</th>
                <th>Remito</th><th className="th-right">Neto</th>
                <th className="th-right">IVA</th><th className="th-right">Total</th>
                <th>Estado</th><th style={{ width: 220 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🧾" message="Sin facturas de compra" /> : rows.map(f => (
                <tr key={f.id}>
                  <td><span className="code" style={{ fontWeight: 700 }}>{f.numero}</span></td>
                  <td><span className={`badge badge-${f.tipo}`}>Fac {f.tipo}</span></td>
                  <td>{fFecha(f.fecha)}</td>
                  <td>
                    <div className="td-bold">{f.razon_social}</div>
                    <div style={{ fontSize: 11, color: 'var(--gray-400)' }}>{f.cuit}</div>
                  </td>
                  <td>
                    {f.remito_numero
                      ? <span className="code" style={{ color: 'var(--green-600)' }}>{f.remito_numero}</span>
                      : <span style={{ color: 'var(--gray-400)', fontSize: 12 }}>—</span>}
                  </td>
                  <td className="td-right" style={{ color: 'var(--gray-500)' }}>{$ar(f.neto_gravado)}</td>
                  <td className="td-right" style={{ color: 'var(--gray-500)' }}>{$ar(f.iva_monto)}</td>
                  <td className="td-right td-bold">{$ar(f.total)}</td>
                  <td><Badge estado={f.estado} /></td>
                  <td>
                    <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                      <button className="btn btn-ghost btn-xs" onClick={() => setFacForm({ data: f, isNew: false })}>Ver</button>
                      {f.estado !== 'anulada' && f.estado !== 'pagada' && (
                        <button className="btn btn-success btn-xs" onClick={() => setPagoFor({ provId: f.proveedor_id, facIds: [f.id], totalSugerido: f.total })}>💸 Pagar</button>
                      )}
                      {f.estado !== 'anulada' && (
                        <button className="btn btn-secondary btn-xs" onClick={() => setNotaFor(f)}>NC/ND</button>
                      )}
                      {f.estado === 'pendiente' && <button className="btn btn-danger btn-xs" onClick={() => anular(f.id)}>Anular</button>}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {facForm && (
        <CompraComprobanteForm
          title={facForm.isNew ? 'Nueva Factura de Compra' : `Factura ${facForm.data?.numero || ''}`}
          tipo="factura"
          initial={facForm.data || {}}
          proveedores={proveedores}
          materiales={materiales}
          alicuotas={alicuotas}
          onSave={save}
          onClose={() => setFacForm(null)}
        />
      )}

      {pagoFor && (
        <PagoProveedorForm
          proveedores={proveedores}
          initial={pagoFor}
          onSave={async (payload) => {
            await PagosProveedorAPI.create(payload)
            toast.success('Pago registrado')
            setPagoFor(null); load()
          }}
          onClose={() => setPagoFor(null)}
        />
      )}

      {notaFor && (
        <NotaCompraForm
          factura={notaFor}
          materiales={materiales}
          alicuotas={alicuotas}
          onSave={async (payload) => {
            await NotasCompraAPI.create(payload)
            toast.success('Nota guardada')
            setNotaFor(null); load()
          }}
          onClose={() => setNotaFor(null)}
        />
      )}
    </div>
  )
}
