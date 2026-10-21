// src/views/Presupuestos/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { PresupuestosAPI, ClientesAPI, ProductosAPI } from '../../api'
import { $ar, fFecha, isVencido } from '../../utils'
import { Badge, Loading, EmptyState, RowActions } from '../../components/UI'
import ComprobanteForm from '../../components/Forms/ComprobanteForm'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

// Aceptados, rechazados y convertidos quedan como historia del cliente (eliminar_presupuesto).
const ELIMINABLES = ['borrador', 'enviado', 'vencido']

export default function Presupuestos() {
  const [rows, setRows]         = useState([])
  const [loading, setLoading]   = useState(true)
  const [clientes, setClientes] = useState([])
  const [productos, setProductos] = useState([])
  const [search, setSearch]     = useState('')
  const [filtroEst, setFiltroEst] = useState('')
  const [form, setForm]         = useState(null) // null | { data, isNew, warnVencido }
  const [pdfModal, setPdfModal] = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    PresupuestosAPI.list({ q: search, estado: filtroEst }).then(setRows).finally(() => setLoading(false))
  }, [search, filtroEst])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    ClientesAPI.list().then(setClientes)
    ProductosAPI.list({ activo: true }).then(setProductos)
  }, [])

  const openNew  = () => setForm({ data: null, isNew: true })
  const openEdit = (p) => {
    const venc = isVencido(p.fecha_vcto) && !['convertido','rechazado','aceptado'].includes(p.estado)
    setForm({ data: p, isNew: false, warnVencido: venc })
  }

  const save = async (payload) => {
    try {
      if (form.isNew) await PresupuestosAPI.create(payload)
      else            await PresupuestosAPI.update(form.data.id, payload)
      toast.success('Presupuesto guardado')
      setForm(null); load()
    } catch (err) { throw err }
  }

  const cambiarEstado = async (id, estado) => {
    try {
      await PresupuestosAPI.cambiarEstado(id, estado)
      load()
    } catch { /* La API muestra el error. */ }
  }

  const eliminar = async (p) => {
    if (!confirm(`¿Eliminar el presupuesto ${p.numero} a nombre de ${p.razon_social}? Se borrarán sus ítems. Esta acción no se puede deshacer.`)) return
    try {
      await PresupuestosAPI.delete(p.id)
      toast.success('Presupuesto eliminado')
      setForm(null)
      load()
    } catch { /* La API muestra el error y conserva el presupuesto abierto. */ }
  }

  const convertirAFactura = (p) => {
    // Navega a facturas con datos pre-cargados — pasamos por sessionStorage
    sessionStorage.setItem('crm_desde_presupuesto', JSON.stringify({
      cliente_id: p.cliente_id, items: p.items, descuento_general: p.descuento_general, presupuesto_id: p.id,
      observaciones: [!p.cliente_id && `Presupuesto a nombre de: ${p.razon_social}`, p.observaciones].filter(Boolean).join('\n'),
    }))
    window.location.href = '/facturas'
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar número, nombre o contacto…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="sel" style={{ width: 170 }} value={filtroEst} onChange={e => setFiltroEst(e.target.value)}>
            <option value="">Todos los estados</option>
            {['borrador','enviado','aceptado','vencido','convertido','rechazado'].map(e => <option key={e} value={e}>{e.charAt(0).toUpperCase()+e.slice(1)}</option>)}
          </select>
        </div>
        <button className="btn btn-primary" onClick={openNew}>+ Nuevo presupuesto</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Fecha</th><th>Vencimiento</th><th>Destinatario</th>
                <th className="th-right">Total</th><th>Estado</th><th className="th-right" style={{ width: 150 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="📋" message="Sin presupuestos" /> : rows.map(p => (
                <tr key={p.id} className="tr-click" onClick={() => openEdit(p)}>
                  <td><span className="code">{p.numero}</span></td>
                  <td>{fFecha(p.fecha)}</td>
                  <td style={{ color: isVencido(p.fecha_vcto) && !['aceptado','convertido','rechazado'].includes(p.estado) ? 'var(--red-500)' : 'inherit', fontWeight: isVencido(p.fecha_vcto) ? 600 : 400 }}>
                    {fFecha(p.fecha_vcto)}
                  </td>
                  <td className="td-bold">{p.razon_social}</td>
                  <td className="td-right td-bold">{$ar(p.total)}</td>
                  <td><Badge estado={p.estado} /></td>
                  <td>
                    <RowActions
                      primary={['borrador', 'enviado', 'aceptado', 'vencido'].includes(p.estado) && { label: 'Facturar', icon: '→', onClick: () => convertirAFactura(p) }}
                      onPdf={() => setPdfModal({ url: `/api/pdf/presupuesto/${p.id}`, titulo: `Presupuesto ${p.numero}` })}
                      items={[
                        { label: 'Ver / Editar', icon: '✎', onClick: () => openEdit(p) },
                        { label: 'Marcar aceptado', icon: '✓', onClick: () => cambiarEstado(p.id, 'aceptado'), hidden: !['borrador', 'enviado', 'vencido'].includes(p.estado) },
                        { label: 'Marcar enviado', icon: '✉', onClick: () => cambiarEstado(p.id, 'enviado'), hidden: p.estado !== 'borrador' },
                        { label: 'Eliminar presupuesto', danger: true, onClick: () => eliminar(p), hidden: !ELIMINABLES.includes(p.estado) },
                      ]}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {form && (
        <ComprobanteForm
          title={form.isNew ? 'Nuevo presupuesto' : `Editar presupuesto ${form.data?.numero || ''}`}
          tipo="presupuesto"
          initial={form.data || {}}
          clientes={clientes}
          productos={productos}
          warnVencido={form.warnVencido}
          onSave={save}
          onDelete={!form.isNew && ELIMINABLES.includes(form.data.estado) ? () => eliminar(form.data) : undefined}
          onClose={() => setForm(null)}
        />
      )}
      {pdfModal && <PDFModal url={pdfModal.url} titulo={pdfModal.titulo} onClose={() => setPdfModal(null)} />}
    </div>
  )
}
