// src/views/ComprasRemitos/index.jsx
// Remitos de COMPRA (Fase A). Espeja views/Remitos pero contra proveedores/materiales.
// "→ Factura" deja el remito en sessionStorage y navega a /compras/facturas, donde el form
// se abre prellenado (proveedor + ítems + remito_compra_id). Sin PDF (comprobante del proveedor).
import { useState, useEffect, useCallback } from 'react'
import { RemitosCompraAPI, ProveedoresAPI, MaterialesAPI } from '../../api'
import { fFecha } from '../../utils'
import { Badge, Loading, EmptyState } from '../../components/UI'
import CompraComprobanteForm from '../../components/Forms/CompraComprobanteForm'
import toast from 'react-hot-toast'

export default function ComprasRemitos() {
  const [rows, setRows]           = useState([])
  const [loading, setLoading]     = useState(true)
  const [proveedores, setProveedores] = useState([])
  const [materiales, setMateriales]   = useState([])
  const [search, setSearch]       = useState('')
  const [filtroEst, setFiltroEst] = useState('')
  const [form, setForm]           = useState(null)  // { data, isNew }

  const load = useCallback(() => {
    setLoading(true)
    RemitosCompraAPI.list({ q: search, estado: filtroEst }).then(setRows).finally(() => setLoading(false))
  }, [search, filtroEst])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    ProveedoresAPI.list().then(setProveedores)
    MaterialesAPI.list({ activo: true }).then(setMateriales)
  }, [])

  const save = async (payload) => {
    try {
      if (form.isNew) await RemitosCompraAPI.create(payload)
      else            await RemitosCompraAPI.update(form.data.id, payload)
      toast.success('Remito de compra guardado')
      setForm(null); load()
    } catch (err) { throw err }
  }

  const anular = async (id) => {
    if (!confirm('¿Anular este remito de compra?')) return
    await RemitosCompraAPI.anular(id)
    toast.success('Remito anulado')
    load()
  }

  const irAFacturar = (r) => {
    sessionStorage.setItem('crm_desde_remito_compra', JSON.stringify({
      proveedor_id: r.proveedor_id, remito_compra_id: r.id, items: r.items || [],
    }))
    window.location.href = '/compras/facturas'
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar remito o proveedor…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="sel" style={{ width: 160 }} value={filtroEst} onChange={e => setFiltroEst(e.target.value)}>
            <option value="">Todos los estados</option>
            <option value="pendiente">Pendiente</option>
            <option value="facturado">Facturado</option>
            <option value="anulado">Anulado</option>
          </select>
        </div>
        <button className="btn btn-primary" onClick={() => setForm({ data: {}, isNew: true })}>+ Nuevo remito</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Fecha</th><th>Proveedor</th><th>Ítems</th>
                <th>Factura vinculada</th><th>Estado</th><th style={{ width: 200 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🚚" message="Sin remitos de compra" /> : rows.map(r => (
                <tr key={r.id}>
                  <td><span className="code">{r.numero}</span></td>
                  <td>{fFecha(r.fecha)}</td>
                  <td className="td-bold">{r.razon_social}</td>
                  <td style={{ color: 'var(--gray-500)' }}>{r.items?.length || 0} ítem(s)</td>
                  <td>
                    {r.factura_numero
                      ? <span className="code" style={{ color: 'var(--green-600)' }}>{r.factura_numero}</span>
                      : <Badge estado="pendiente" />}
                  </td>
                  <td><Badge estado={r.estado} /></td>
                  <td>
                    <div style={{ display: 'flex', gap: 4 }}>
                      <button className="btn btn-ghost btn-xs" onClick={() => setForm({ data: r, isNew: false })}>Ver</button>
                      {r.estado === 'pendiente' && <>
                        <button className="btn btn-secondary btn-xs" style={{ background: 'var(--blue-50)', color: 'var(--blue-700)', borderColor: 'var(--blue-100)' }} onClick={() => irAFacturar(r)}>→ Factura</button>
                        <button className="btn btn-danger btn-xs" onClick={() => anular(r.id)}>Anular</button>
                      </>}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {form && (
        <CompraComprobanteForm
          title={form.isNew ? 'Nuevo remito de compra' : `Remito ${form.data?.numero || ''}`}
          tipo="remito"
          initial={form.data || {}}
          proveedores={proveedores}
          materiales={materiales}
          onSave={save}
          onClose={() => setForm(null)}
        />
      )}
    </div>
  )
}
