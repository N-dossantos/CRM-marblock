// src/views/Facturas/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { useListaPaginada, POR_PAGINA } from '../../hooks/useListaPaginada'
import { FacturasAPI, ClientesAPI, ProductosAPI, AlicuotasIvaAPI, RemitosAPI } from '../../api'
import { $ar, fFecha, fDocNro } from '../../utils'
import { Badge, Loading, EmptyState, Paginador, RowActions } from '../../components/UI'
import ComprobanteForm from '../../components/Forms/ComprobanteForm'
import ReciboForm from '../../components/Forms/ReciboForm'
import NotaForm from '../Notas/NotaForm'
import VentaDetalle from '../../components/Consultas/VentaDetalle'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

export default function Facturas() {
  const [clientes, setClientes] = useState([])
  const [productos, setProductos] = useState([])
  const [alicuotas, setAlicuotas] = useState([])
  const [search, setSearch]     = useState('')
  const [filtroEst, setFiltroEst] = useState('')
  const [facForm, setFacForm]   = useState(null)   // sólo para emitir: una factura emitida no se edita
  const [detalle, setDetalle]   = useState(null)   // factura emitida, en sólo lectura
  const [reciboFor, setReciboFor] = useState(null)
  const [notaFor, setNotaFor]   = useState(null)
  const [pdfModal, setPdfModal] = useState(null) // { url, titulo }
  const [remPend, setRemPend]   = useState([])   // remitos pendientes del cliente elegido
  const [remLoading, setRemLoading] = useState(false)

  const { rows, total, loading, pagina, setPagina, recargar: load } =
    useListaPaginada(FacturasAPI.list, { q: search, estado: filtroEst })
  useEffect(() => {
    ClientesAPI.list().then(setClientes)
    ProductosAPI.list({ activo: true }).then(setProductos)
    AlicuotasIvaAPI.list().then(setAlicuotas)
  }, [])

  // Los remitos pendientes se piden por cliente (no se precarga la tabla entera): el operador
  // elige el cliente y recién ahí aparecen sus entregas sin facturar.
  const cargarRemitos = useCallback(async (cliId) => {
    if (!cliId) { setRemPend([]); return }
    setRemLoading(true)
    try { setRemPend(await RemitosAPI.pendientes(+cliId)) }
    catch { setRemPend([]) }
    finally { setRemLoading(false) }
  }, [])

  // Detectar si viene desde presupuesto o remito
  useEffect(() => {
    const fromPres = sessionStorage.getItem('crm_desde_presupuesto')
    const fromRem  = sessionStorage.getItem('crm_desde_remito')
    if (fromPres) {
      const d = JSON.parse(fromPres)
      sessionStorage.removeItem('crm_desde_presupuesto')
      setFacForm({ data: d, isNew: true })
      cargarRemitos(d.cliente_id)
    } else if (fromRem) {
      const d = JSON.parse(fromRem)
      sessionStorage.removeItem('crm_desde_remito')
      setFacForm({ data: d, isNew: true })
      cargarRemitos(d.cliente_id)
    }
  }, [cargarRemitos])

  const openNew = async () => {
    setRemPend([])
    setFacForm({ data: {}, isNew: true })
  }

  const cerrarForm = () => { setFacForm(null); setRemPend([]) }

  // Una factura emitida ya tiene número y está en manos del cliente (y con ARCA, CAE): no se
  // modifica. Se corrige con NC/ND, o se anula y se emite otra.
  const save = async (payload) => {
    await FacturasAPI.create(payload)
    toast.success('Factura guardada')
    cerrarForm(); load()
  }

  const anular = async (id) => {
    if (!confirm('¿Anular esta factura? Esta acción no se puede deshacer.')) return
    await FacturasAPI.anular(id)
    toast.success('Factura anulada')
    setDetalle(null)
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
                <th className="th-right">IVA</th><th className="th-right">Total</th>
                <th>Estado</th><th className="th-right" style={{ width: 150 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🧾" message="Sin facturas" /> : rows.map(f => (
                <tr key={f.id} className="tr-click" onClick={() => setDetalle({ _doc: 'factura', ...f })}>
                  <td><span className="code" style={{ fontWeight: 700 }}>{f.numero}</span></td>
                  <td><span className={`badge badge-${f.tipo}`}>Fac {f.tipo}</span></td>
                  <td>{fFecha(f.fecha)}</td>
                  <td>
                    <div className="td-bold">{f.razon_social}</div>
                    <div style={{ fontSize: 11, color: 'var(--gray-400)' }}>{fDocNro(f.doc_tipo, f.doc_nro)}</div>
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
                    <RowActions
                      primary={['pendiente', 'parcial'].includes(f.estado) && { label: 'Cobrar', icon: '💵', tone: 'success', onClick: () => abrirCobro(f) }}
                      onPdf={() => setPdfModal({ url: `/api/pdf/factura/${f.id}`, titulo: `Factura ${f.numero}` })}
                      items={[
                        { label: 'Ver detalle', icon: '👁', onClick: () => setDetalle({ _doc: 'factura', ...f }) },
                        { label: 'Nota de crédito / débito', icon: '↩', onClick: () => setNotaFor(f), hidden: f.estado === 'anulada' },
                        { label: 'Anular', icon: '⛔', danger: true, onClick: () => anular(f.id), hidden: f.estado !== 'pendiente' },
                      ]}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <Paginador pagina={pagina} total={total} porPagina={POR_PAGINA} onChange={setPagina} disabled={loading} />
      </div>

      {facForm && (
        <ComprobanteForm
          title="Nueva Factura"
          tipo="factura"
          initial={facForm.data || {}}
          clientes={clientes}
          productos={productos}
          alicuotas={alicuotas}
          remitos={remPend}
          remitosLoading={remLoading}
          onClienteChange={cargarRemitos}
          onSave={save}
          onClose={cerrarForm}
        />
      )}

      {detalle && (
        <VentaDetalle
          doc={detalle}
          onClose={() => setDetalle(null)}
          acciones={detalle.estado !== 'anulada' && <>
            <button className="btn btn-secondary btn-sm" onClick={() => { setNotaFor(detalle); setDetalle(null) }}>NC/ND</button>
            {detalle.estado === 'pendiente' && <button className="btn btn-danger btn-sm" onClick={() => anular(detalle.id)}>Anular</button>}
          </>}
        />
      )}

      {reciboFor && (
        <ReciboForm
          clientes={clientes}
          initial={reciboFor}
          onSave={async (payload) => {
            const { RecibosAPI } = await import('../../api')
            const r = await RecibosAPI.create(payload)
            toast.success(r?.numero ? `Cobro registrado — Recibo ${r.numero}` : 'Cobro registrado')
            setReciboFor(null); load()
          }}
          onClose={() => setReciboFor(null)}
        />
      )}

      {notaFor && (
        <NotaForm
          factura={notaFor}
          productos={productos}
          alicuotas={alicuotas}
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
