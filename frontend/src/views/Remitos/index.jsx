// src/views/Remitos/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { RemitosAPI, ClientesAPI, ProductosAPI, pdfUrl } from '../../api'
import { fFecha } from '../../utils'
import { Badge, Loading, EmptyState } from '../../components/UI'
import ComprobanteForm from '../../components/Forms/ComprobanteForm'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

export default function Remitos() {
  const [rows, setRows]         = useState([])
  const [loading, setLoading]   = useState(true)
  const [clientes, setClientes] = useState([])
  const [productos, setProductos] = useState([])
  const [search, setSearch]     = useState('')
  const [filtroEst, setFiltroEst] = useState('')
  const [form, setForm]         = useState(null)
  const [pdfModal, setPdfModal] = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    RemitosAPI.list({ q: search, estado: filtroEst }).then(setRows).finally(() => setLoading(false))
  }, [search, filtroEst])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    ClientesAPI.list().then(setClientes)
    ProductosAPI.list({ activo: true }).then(setProductos)
  }, [])

  // La sugerencia se pide al abrir el formulario, no al montar la vista: si se cargan
  // remitos durante la sesión, el número sugerido tiene que reflejarlos.
  const nuevo = async () => {
    const sugerido = await RemitosAPI.numeroSugerido().catch(() => null)
    setForm({ data: null, isNew: true, sugerido })
  }

  const save = async (payload) => {
    try {
      let creado = null
      if (form.isNew) creado = await RemitosAPI.create(payload)
      else            await RemitosAPI.update(form.data.id, payload)
      toast.success('Remito guardado')
      setForm(null); load()
      // Al emitir uno nuevo se abre directo la impresión sobre el talonario: la hoja ya
      // está en la impresora y el número del remito es el de esa hoja.
      if (creado?.id) {
        setPdfModal({
          url:    pdfUrl.remitoTalonario(creado.id),
          titulo: `Remito ${creado.numero} — talonario`,
          talonario: true,
        })
      }
    } catch (err) { throw err }
  }

  const anular = async (id) => {
    if (!confirm('¿Anular este remito?')) return
    await RemitosAPI.anular(id)
    toast.success('Remito anulado')
    load()
  }

  const irAFacturar = (r) => {
    sessionStorage.setItem('crm_desde_remito', JSON.stringify({
      cliente_id: r.cliente_id, items: r.items, remito_id: r.id
    }))
    window.location.href = '/facturas'
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar remito o cliente…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="sel" style={{ width: 160 }} value={filtroEst} onChange={e => setFiltroEst(e.target.value)}>
            <option value="">Todos los estados</option>
            <option value="pendiente">Pendiente</option>
            <option value="facturado">Facturado</option>
            <option value="anulado">Anulado</option>
          </select>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          {/* Grilla milimetrada para ajustar la posición de la sobreimpresión. Se imprime
              sobre un formulario del talonario y se lee dónde cayó cada cruz. */}
          <button
            className="btn btn-secondary"
            title="Imprimir grilla de calibración sobre un formulario del talonario"
            onClick={() => setPdfModal({
              url: pdfUrl.remitoCalibracion(),
              titulo: 'Calibración de impresión — remito',
              talonario: true,
            })}
          >
            ⚙ Calibrar
          </button>
          <button className="btn btn-primary" onClick={nuevo}>+ Nuevo remito</button>
        </div>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Fecha</th><th>Cliente</th><th>Ítems</th>
                <th>Factura vinculada</th><th>Estado</th><th style={{ width: 200 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🚚" message="Sin remitos" /> : rows.map(r => (
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
                      <button className="btn btn-secondary btn-xs" style={{ background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }} onClick={() => setPdfModal({ url: pdfUrl.remito(r.id), titulo: `Remito ${r.numero}` })}>📄 PDF</button>
                      <button className="btn btn-secondary btn-xs" onClick={() => setPdfModal({ url: pdfUrl.remitoTalonario(r.id), titulo: `Remito ${r.numero} — talonario`, talonario: true })}>🖨 Talonario</button>
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
        <ComprobanteForm
          title={form.isNew ? 'Nuevo remito' : `Remito ${form.data?.numero || ''}`}
          tipo="remito"
          initial={form.data || {}}
          clientes={clientes}
          productos={productos}
          numeroSugerido={form.sugerido || null}
          onSave={save}
          onClose={() => setForm(null)}
        />
      )}
      {pdfModal && (
        <PDFModal
          url={pdfModal.url}
          titulo={pdfModal.titulo}
          talonario={pdfModal.talonario}
          onClose={() => setPdfModal(null)}
        />
      )}
    </div>
  )
}
