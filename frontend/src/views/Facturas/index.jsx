// src/views/Facturas/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { useListaPaginada, POR_PAGINA } from '../../hooks/useListaPaginada'
import { FacturasAPI, NotasAPI, RecibosAPI, ClientesAPI, ProductosAPI, AlicuotasIvaAPI, RemitosAPI } from '../../api'
import { $ar, fFecha, fDocNro } from '../../utils'
import { Badge, Loading, EmptyState, Paginador, RowActions, Vinculados } from '../../components/UI'
import { FiscalBadge, PanelArca, BandejaArca, FILTROS_ARCA, estadosDeFiltro, esFiscal, esEditable, emitirEnArca } from '../../components/Arca'
import ComprobanteForm from '../../components/Forms/ComprobanteForm'
import ReciboForm from '../../components/Forms/ReciboForm'
import NotaForm from '../Notas/NotaForm'
import VentaDetalle from '../../components/Consultas/VentaDetalle'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

// Una factura nace borrador y cuenta para el negocio recién con el CAE de ARCA (PLAN_ARCA.md §4).
// Mientras no lo tiene se edita, se emite o se descarta; con CAE es inmutable y se corrige con
// NC/ND. Sólo lo histórico (cargado antes del CRM fiscal) se anula.
export default function Facturas() {
  const nav = useNavigate()
  const [params] = useSearchParams()
  const [clientes, setClientes] = useState([])
  const [productos, setProductos] = useState([])
  const [alicuotas, setAlicuotas] = useState([])
  const [search, setSearch]     = useState('')
  const [filtroEst, setFiltroEst] = useState('')
  const [filtroArca, setFiltroArca] = useState(() => params.get('arca') || '')
  const [facForm, setFacForm]   = useState(null)   // { data, isNew }: nueva, o un borrador/rechazada a corregir
  const [detalle, setDetalle]   = useState(null)   // { _doc: 'factura', ...fila, _arca: respuesta de la emisión }
  const [arcaOcupado, setArcaOcupado] = useState(false)
  const [reciboFor, setReciboFor] = useState(null)
  const [notaFor, setNotaFor]   = useState(null)
  const [pdfModal, setPdfModal] = useState(null) // { url, titulo }
  const [remPend, setRemPend]   = useState([])   // remitos pendientes del cliente elegido
  const [remLoading, setRemLoading] = useState(false)

  const { rows, total, loading, pagina, setPagina, recargar: load } =
    useListaPaginada(FacturasAPI.list, { q: search, estado: filtroEst, estado_fiscal: estadosDeFiltro(filtroArca) })
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

  const abrirDetalle = (id, respuesta = null) =>
    FacturasAPI.get(id).then(f => f && setDetalle({ _doc: 'factura', ...f, _arca: respuesta }))

  // El panel de ARCA cambió el estado: se relee la factura (número, CAE) y la lista.
  const refrescarDetalle = () => {
    if (detalle) FacturasAPI.get(detalle.id).then(f => f && setDetalle(d => (d?.id === f.id ? { ...d, ...f } : d)))
    load()
  }
  const cerrarDetalle = () => { if (!arcaOcupado) setDetalle(null) }

  // Guarda el borrador (nuevo o corregido) y, si se pidió, lo emite. El formulario queda abierto
  // con "Emitiendo…" hasta que ARCA responde; si no autoriza, se abre el detalle con el panel que
  // muestra el rechazo o el resultado incierto. El borrador ya quedó guardado: no se pierde.
  const save = async (payload, { emitir = false } = {}) => {
    const fac = facForm.isNew
      ? await FacturasAPI.create(payload)
      // Las percepciones vuelven tal cual: el formulario no las edita y sin ellas la RPC las borra.
      : await FacturasAPI.update(facForm.data.id, { ...payload, percepciones: facForm.data.percepciones })
    let r = null
    try {
      if (emitir) r = await emitirEnArca('facturas', fac.id)
    } finally {
      cerrarForm(); load()
    }
    if (!emitir) toast.success(facForm.isNew ? 'Borrador guardado: falta emitirlo en ARCA' : 'Borrador actualizado')
    else if (!(r?.status === 200 && r.estado_fiscal === 'autorizado')) abrirDetalle(fac.id, r)
  }

  const editar = (f) => { setDetalle(null); setFacForm({ data: f, isNew: false }) }

  const descartar = async (f) => {
    const remitos = f.remitos?.length ? ' y sus remitos vuelven a quedar pendientes de facturar' : ''
    if (!confirm(`¿Descartar el borrador de Factura ${f.tipo} a ${f.razon_social} por ${$ar(f.total)}? Se borra con sus ítems${remitos}.`)) return
    await FacturasAPI.descartar(f.id)
    toast.success('Borrador descartado')
    setDetalle(null)
    load()
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

  // La acción obvia de cada fila según su estado fiscal y de cobranza.
  const accionPrincipal = (f) => {
    switch (f.estado_fiscal) {
      case 'borrador':           return { label: 'Emitir', icon: '⚡', onClick: () => abrirDetalle(f.id) }
      case 'rechazado':          return { label: 'Corregir', icon: '✎', tone: 'warn', onClick: () => editar(f) }
      case 'resultado_incierto':
      case 'en_proceso':         return { label: 'Consultar', icon: '⟳', tone: 'warn', onClick: () => abrirDetalle(f.id) }
      default:
        return ['pendiente', 'parcial'].includes(f.estado)
          ? { label: 'Cobrar', icon: '💵', tone: 'success', onClick: () => abrirCobro(f) }
          : null
    }
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
          <select className="sel" style={{ width: 170 }} value={filtroArca} onChange={e => setFiltroArca(e.target.value)}>
            {FILTROS_ARCA.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
          </select>
        </div>
        <button className="btn btn-primary" onClick={openNew}>+ Nueva factura</button>
      </div>

      <BandejaArca tabla="facturas" recarga={rows} onFiltrar={setFiltroArca} />

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Tipo</th><th>Fecha</th><th>Cliente</th>
                <th>Remito</th><th className="th-right">Neto</th>
                <th className="th-right">IVA</th><th className="th-right">Total</th>
                <th>ARCA</th><th>Estado</th><th className="th-right" style={{ width: 150 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🧾" message="Sin facturas" /> : rows.map(f => {
                const fiscal = esFiscal(f)
                const editable = esEditable(f)
                return (
                  <tr key={f.id} className="tr-click" onClick={() => setDetalle({ _doc: 'factura', ...f })}>
                    <td>{f.numero
                      ? <span className="code" style={{ fontWeight: 700 }}>{f.numero}</span>
                      : <span className="sin-numero">sin número</span>}</td>
                    <td><span className={`badge badge-${f.tipo}`}>Fac {f.tipo}</span></td>
                    <td>{fFecha(f.fecha)}</td>
                    <td>
                      <div className="td-bold">{f.razon_social}</div>
                      <div style={{ fontSize: 11, color: 'var(--gray-400)' }}>{fDocNro(f.doc_tipo, f.doc_nro)}</div>
                    </td>
                    <td>
                      {/* Una factura puede cubrir varios remitos: primero el suyo (remito_numero), después el resto. */}
                      <Vinculados
                        numeros={[...new Set([f.remito_numero, ...(f.remitos || []).map(r => r.numero)].filter(Boolean))]}
                        vacio={<span style={{ color: 'var(--gray-400)', fontSize: 12 }}>—</span>}
                      />
                    </td>
                    <td className="td-right" style={{ color: 'var(--gray-500)' }}>{$ar(f.neto_gravado)}</td>
                    <td className="td-right" style={{ color: 'var(--gray-500)' }}>{$ar(f.iva_monto)}</td>
                    <td className="td-right td-bold">{$ar(f.total)}</td>
                    <td><FiscalBadge estado={f.estado_fiscal} cae={f.cae} /></td>
                    {/* El estado de cobranza sólo existe en lo fiscal: un borrador no se cobra. */}
                    <td>{fiscal ? <Badge estado={f.estado} /> : <span className="arca-historico">—</span>}</td>
                    <td>
                      <RowActions
                        primary={accionPrincipal(f)}
                        onPdf={() => setPdfModal({ url: `/api/pdf/factura/${f.id}`, titulo: `Factura ${f.numero || `borrador #${f.id}`}` })}
                        items={[
                          { label: 'Ver detalle', icon: '👁', onClick: () => setDetalle({ _doc: 'factura', ...f }) },
                          { label: 'Editar borrador', icon: '✎', onClick: () => editar(f), hidden: !editable },
                          { label: 'Nota de crédito / débito', icon: '↩', onClick: () => setNotaFor(f), hidden: !fiscal || f.estado === 'anulada' },
                          { label: 'Anular', icon: '⛔', danger: true, onClick: () => anular(f.id), hidden: f.estado_fiscal !== 'historico' || f.estado !== 'pendiente' },
                          { label: 'Descartar borrador', icon: '🗑', danger: true, onClick: () => descartar(f), hidden: !editable },
                        ]}
                      />
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
        <Paginador pagina={pagina} total={total} porPagina={POR_PAGINA} onChange={setPagina} disabled={loading} />
      </div>

      {facForm && (
        <ComprobanteForm
          title={facForm.isNew ? 'Nueva Factura' : `Editar borrador — Factura ${facForm.data.tipo}`}
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
          onClose={cerrarDetalle}
          fiscal={
            <PanelArca
              key={detalle.id}
              tabla="facturas"
              doc={detalle}
              respuesta={detalle._arca}
              onCambio={refrescarDetalle}
              onEditar={() => editar(detalle)}
              onDescartar={() => descartar(detalle)}
              onOcupado={setArcaOcupado}
            />
          }
          acciones={esFiscal(detalle) && detalle.estado !== 'anulada' && <>
            <button className="btn btn-secondary btn-sm" onClick={() => { setNotaFor(detalle); setDetalle(null) }}>NC/ND</button>
            {detalle.estado_fiscal === 'historico' && detalle.estado === 'pendiente' &&
              <button className="btn btn-danger btn-sm" onClick={() => anular(detalle.id)}>Anular</button>}
          </>}
        />
      )}

      {reciboFor && (
        <ReciboForm
          clientes={clientes}
          initial={reciboFor}
          onSave={async (payload) => {
            const r = await RecibosAPI.create(payload)
            toast.success(r?.numero ? `Cobro registrado — Recibo ${r.numero}` : 'Cobro registrado')
            setReciboFor(null); load()
          }}
          onClose={() => setReciboFor(null)}
        />
      )}

      {/* NC/ND sobre una factura con CAE o histórica. Si la emisión no sale, el detalle con el panel
          de ARCA está en Notas C/D. */}
      {notaFor && (
        <NotaForm
          factura={notaFor}
          productos={productos}
          alicuotas={alicuotas}
          onSave={async (payload, { emitir }) => {
            const n = await NotasAPI.create(payload)
            let r = null
            try {
              if (emitir) r = await emitirEnArca('notas', n.id)
            } finally {
              setNotaFor(null); load()
            }
            if (!emitir) toast.success('Borrador de nota guardado: falta emitirlo en ARCA (en Notas C/D)')
            else if (!(r?.status === 200 && r.estado_fiscal === 'autorizado')) nav(`/notas?ver=${n.id}`)
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
