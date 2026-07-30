// src/views/Presupuestos/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { PresupuestosAPI, ClientesAPI, ProductosAPI } from '../../api'
import { $ar, fFecha, isVencido } from '../../utils'
import { Badge, Loading, EmptyState } from '../../components/UI'
import ComprobanteForm from '../../components/Forms/ComprobanteForm'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

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
    await PresupuestosAPI.cambiarEstado(id, estado)
    load()
  }

  const convertirAFactura = (p) => {
    // Navega a facturas con datos pre-cargados — pasamos por sessionStorage
    sessionStorage.setItem('crm_desde_presupuesto', JSON.stringify({
      cliente_id: p.cliente_id, items: p.items, descuento_general: p.descuento_general, presupuesto_id: p.id
    }))
    window.location.href = '/facturas'
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar presupuesto o cliente…" value={search} onChange={e => setSearch(e.target.value)} />
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
                <th>Número</th><th>Fecha</th><th>Vencimiento</th><th>Cliente</th>
                <th className="th-right">Total</th><th>Estado</th><th style={{ width: 260 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="📋" message="Sin presupuestos" /> : rows.map(p => (
                <tr key={p.id}>
                  <td><span className="code">{p.numero}</span></td>
                  <td>{fFecha(p.fecha)}</td>
                  <td style={{ color: isVencido(p.fecha_vcto) && !['aceptado','convertido','rechazado'].includes(p.estado) ? 'var(--red-500)' : 'inherit', fontWeight: isVencido(p.fecha_vcto) ? 600 : 400 }}>
                    {fFecha(p.fecha_vcto)}
                  </td>
                  <td className="td-bold">{p.razon_social}</td>
                  <td className="td-right td-bold">{$ar(p.total)}</td>
                  <td><Badge estado={p.estado} /></td>
                  <td>
                    <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                      <button className="btn btn-ghost btn-xs" onClick={() => openEdit(p)}>Ver / Editar</button>
                      <button className="btn btn-secondary btn-xs" style={{ background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }} onClick={() => setPdfModal({ url: `/api/pdf/presupuesto/${p.id}`, titulo: `Presupuesto ${p.numero}` })}>📄 PDF</button>
                      {['borrador','enviado','vencido'].includes(p.estado) && <>
                        <button className="btn btn-secondary btn-xs" style={{ background: 'var(--blue-50)', color: 'var(--blue-700)', borderColor: 'var(--blue-100)' }} onClick={() => convertirAFactura(p)}>→ Factura</button>
                        <button className="btn btn-secondary btn-xs" style={{ background: 'var(--green-50)', color: 'var(--green-700)', borderColor: 'var(--green-100)' }} onClick={() => cambiarEstado(p.id, 'aceptado')}>✓ Aceptar</button>
                      </>}
                      {p.estado === 'borrador' && <button className="btn btn-secondary btn-xs" onClick={() => cambiarEstado(p.id, 'enviado')}>Enviar</button>}
                    </div>
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
          onClose={() => setForm(null)}
        />
      )}
      {pdfModal && <PDFModal url={pdfModal.url} titulo={pdfModal.titulo} onClose={() => setPdfModal(null)} />}
    </div>
  )
}
