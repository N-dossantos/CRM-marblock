// src/views/Facturas/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { FacturasAPI, ClientesAPI, ProductosAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Badge, Loading, EmptyState } from '../../components/UI'
import ComprobanteForm from '../../components/Forms/ComprobanteForm'
import ReciboForm from '../../components/Forms/ReciboForm'
import NotaForm from '../Notas/NotaForm'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

export default function Facturas() {
  const [rows, setRows]         = useState([])
  const [loading, setLoading]   = useState(true)
  const [clientes, setClientes] = useState([])
  const [productos, setProductos] = useState([])
  const [search, setSearch]     = useState('')
  const [filtroEst, setFiltroEst] = useState('')
  const [facForm, setFacForm]   = useState(null)
  const [reciboFor, setReciboFor] = useState(null)
  const [notaFor, setNotaFor]   = useState(null)
  const [pdfModal, setPdfModal] = useState(null) // { url, titulo }

  const load = useCallback(() => {
    setLoading(true)
    FacturasAPI.list({ q: search, estado: filtroEst }).then(setRows).finally(() => setLoading(false))
  }, [search, filtroEst])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    ClientesAPI.list().then(setClientes)
    ProductosAPI.list({ activo: true }).then(setProductos)
  }, [])

  // Detectar si viene desde presupuesto o remito
  useEffect(() => {
    const fromPres = sessionStorage.getItem('crm_desde_presupuesto')
    const fromRem  = sessionStorage.getItem('crm_desde_remito')
    if (fromPres) {
      const d = JSON.parse(fromPres)
      sessionStorage.removeItem('crm_desde_presupuesto')
      setFacForm({ data: d, isNew: true })
    } else if (fromRem) {
      const d = JSON.parse(fromRem)
      sessionStorage.removeItem('crm_desde_remito')
      setFacForm({ data: d, isNew: true })
    }
  }, [])

  const openNew = async () => {
    setFacForm({ data: {}, isNew: true })
  }

  const save = async (payload) => {
    try {
      if (facForm.isNew) await FacturasAPI.create(payload)
      else               await FacturasAPI.update(facForm.data.id, payload)
      toast.success('Factura guardada')
      setFacForm(null); load()
    } catch (err) { throw err }
  }

  const anular = async (id) => {
    if (!confirm('¿Anular esta factura? Esta acción no se puede deshacer.')) return
    await FacturasAPI.anular(id)
    toast.success('Factura anulada')
    load()
  }

  const abrirCobro = (f) => {
    setReciboFor({ cliId: f.cliente_id, facIds: [f.id], totalSugerido: f.total })
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar factura, cliente o CUIT…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="sel" style={{ width: 170 }} value={filtroEst} onChange={e => setFiltroEst(e.target.value)}>
            <option value="">Todos los estados</option>
            <option value="pendiente">Pendiente</option>
            <option value="parcial">Cobro parcial</option>
            <option value="cobrada">Cobrada</option>
            <option value="anulada">Anulada</option>
          </select>
        </div>
        <button className="btn btn-primary" onClick={openNew}>+ Nueva factura</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Tipo</th><th>Fecha</th><th>Cliente</th>
                <th>Remito</th><th className="th-right">Neto</th>
                <th className="th-right">IVA 21%</th><th className="th-right">Total</th>
                <th>Estado</th><th style={{ width: 220 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🧾" message="Sin facturas" /> : rows.map(f => (
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
                      <button className="btn btn-secondary btn-xs" style={{ background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }} onClick={() => setPdfModal({ url: `/api/pdf/factura/${f.id}`, titulo: `Factura ${f.numero}` })}>📄 PDF</button>
                      {f.estado !== 'anulada' && <>
                        <button className="btn btn-success btn-xs" onClick={() => abrirCobro(f)}>💵 Cobrar</button>
                        <button className="btn btn-secondary btn-xs" onClick={() => setNotaFor(f)}>NC/ND</button>
                      </>}
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
        <ComprobanteForm
          title={facForm.isNew ? 'Nueva Factura' : `Factura ${facForm.data?.numero || ''}`}
          tipo="factura"
          initial={facForm.data || {}}
          clientes={clientes}
          productos={productos}
          onSave={save}
          onClose={() => setFacForm(null)}
        />
      )}

      {reciboFor && (
        <ReciboForm
          clientes={clientes}
          initial={reciboFor}
          onSave={async (payload) => {
            const { RecibosAPI } = await import('../../api')
            await RecibosAPI.create(payload)
            toast.success('Cobro registrado')
            setReciboFor(null); load()
          }}
          onClose={() => setReciboFor(null)}
        />
      )}

      {notaFor && (
        <NotaForm
          factura={notaFor}
          productos={productos}
          onSave={async (payload) => {
            const { NotasAPI } = await import('../../api')
            await NotasAPI.create(payload)
            toast.success('Nota guardada')
            setNotaFor(null); load()
          }}
          onClose={() => setNotaFor(null)}
        />
      )}

      {pdfModal && (
        <PDFModal
          url={pdfModal.url}
          titulo={pdfModal.titulo}
          onClose={() => setPdfModal(null)}
        />
      )}
    </div>
  )
}
