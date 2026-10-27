// src/views/CtaCte/index.jsx
import { useState, useEffect } from 'react'
import { InformesAPI, ClientesAPI } from '../../api'
import { $ar, fFecha, fDoc, fDocNro, clienteCoincide } from '../../utils'
import { Loading } from '../../components/UI'
import PDFModal from '../../components/PDFModal'
import { exportarCtaCte } from '../../utils/excel'

const TIPO_STYLE = {
  FACTURA:    { bg: 'var(--amber-100)', color: 'var(--amber-700)', label: 'Factura' },
  RECIBO:     { bg: 'var(--green-100)', color: 'var(--green-700)', label: 'Recibo' },
  'NOTA CRED.': { bg: 'var(--indigo-100)', color: 'var(--indigo-700)', label: 'NC' },
  'NOTA DEB.':  { bg: 'var(--pink-100)', color: 'var(--pink-700)', label: 'ND' },
  'SALDO ANTERIOR': { bg: 'var(--gray-100)', color: 'var(--gray-700)', label: 'Saldo anterior' },
}

export default function CtaCte() {
  const [clientes, setClientes]     = useState([])
  const [selCli, setSelCli]         = useState('')
  const [data, setData]             = useState(null)
  const [loading, setLoading]       = useState(false)
  const [search, setSearch]         = useState('')
  const [desde, setDesde]           = useState('')
  const [hasta, setHasta]           = useState('')
  const [pdfModal, setPdfModal]     = useState(null)

  useEffect(() => { ClientesAPI.list().then(setClientes) }, [])

  // `fechas` permite consultar con otras fechas que las del estado ("Limpiar" las vacía y consulta
  // en el mismo click: el estado nuevo recién se ve en el próximo render).
  const cargar = (fechas = { desde, hasta }) => {
    if (!selCli) return
    setLoading(true)
    const params = {}
    if (fechas.desde) params.desde = fechas.desde
    if (fechas.hasta) params.hasta = fechas.hasta
    InformesAPI.ctaCte(selCli, params).then(setData).finally(() => setLoading(false))
  }

  useEffect(() => { if (selCli) cargar() }, [selCli])

  const clisFiltrados = clientes.filter(c =>
    clienteCoincide(c, search)
  )

  return (
    <div className="financiero-ctacte">
      {/* Panel izquierdo: lista de clientes */}
      <div className="financiero-clientes">
        <div className="card" style={{ padding: '14px', marginBottom: 0, borderBottom: 'none', borderBottomLeftRadius: 0, borderBottomRightRadius: 0 }}>
          <input
            className="search-inp"
            style={{ width: '100%' }}
            placeholder="Buscar cliente…"
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <div className="financiero-clientes-lista">
          {clisFiltrados.map(c => {
            const saldo = data?.cliente?.id === c.id ? data.saldo_total : null
            return (
              <div
                key={c.id}
                onClick={() => setSelCli(c.id)}
                style={{
                  padding: '10px 14px',
                  cursor: 'pointer',
                  borderBottom: '1px solid var(--gray-100)',
                  background: selCli === c.id ? 'var(--blue-50)' : 'transparent',
                  borderLeft: selCli === c.id ? '3px solid var(--blue-600)' : '3px solid transparent',
                  transition: 'background .12s',
                }}
              >
                <div style={{ fontWeight: selCli === c.id ? 700 : 500, fontSize: 'calc(13px * var(--font-scale))', color: 'var(--gray-800)' }}>
                  {c.razon_social.length > 28 ? c.razon_social.slice(0, 28) + '…' : c.razon_social}
                </div>
                {saldo !== null && (
                  <div style={{ fontSize: 'calc(12px * var(--font-scale))', fontWeight: 700, color: saldo > 0 ? 'var(--red-500)' : saldo < 0 ? 'var(--green-600)' : 'var(--gray-400)', marginTop: 2 }}>
                    {$ar(saldo)} {saldo > 0 ? '▲ Debe' : saldo < 0 ? '▼ A favor' : '✓ Sin saldo'}
                  </div>
                )}
                {saldo === null && <div style={{ fontSize: 'calc(11px * var(--font-scale))', color: 'var(--gray-400)', marginTop: 2 }}>{fDocNro(c.doc_tipo, c.doc_nro)}</div>}
              </div>
            )
          })}
        </div>
      </div>

      {/* Panel derecho: movimientos */}
      <div className="financiero-detalle">
        {!selCli ? (
          <div className="card" style={{ textAlign: 'center', padding: '60px 20px' }}>
            <div style={{ fontSize: 'calc(40px * var(--font-scale))', marginBottom: 12 }}>📒</div>
            <p style={{ color: 'var(--gray-400)', fontSize: 'calc(14px * var(--font-scale))' }}>Seleccione un cliente para ver su cuenta corriente</p>
          </div>
        ) : loading ? (
          <Loading />
        ) : data ? (
          <div>
            {/* Header del cliente */}
            <div className="card" style={{ marginBottom: 14 }}>
              <div className="financiero-resumen">
                <div>
                  <h2 style={{ fontSize: 'calc(17px * var(--font-scale))', fontWeight: 700, color: 'var(--gray-800)' }}>{data.cliente.razon_social}</h2>
                  <div style={{ fontSize: 'calc(13px * var(--font-scale))', color: 'var(--gray-500)', marginTop: 4 }}>
                    {fDoc(data.cliente.doc_tipo, data.cliente.doc_nro)} &nbsp;·&nbsp; {data.cliente.condicion_iva}
                    {data.cliente.email && ` · ${data.cliente.email}`}
                  </div>
                </div>
                <div className="financiero-resumen-saldo">
                  <div style={{ fontSize: 'calc(11px * var(--font-scale))', fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px', marginBottom: 4 }}>{data.hasta ? `Saldo al ${fFecha(data.hasta)}` : 'Saldo actual'}</div>
                  <div style={{ fontSize: 'calc(28px * var(--font-scale))', fontWeight: 800, color: data.saldo_total > 0 ? 'var(--red-500)' : data.saldo_total < 0 ? 'var(--green-600)' : 'var(--gray-400)', lineHeight: 1 }}>
                    {$ar(data.saldo_total)}
                  </div>
                  <div style={{ fontSize: 'calc(12px * var(--font-scale))', color: 'var(--gray-400)', marginTop: 4 }}>
                    {data.saldo_total > 0 ? '⬆ Saldo deudor' : data.saldo_total < 0 ? '⬇ Saldo a favor' : '✓ Cuenta balanceada'}
                  </div>
                  <button
                    className="btn btn-secondary btn-sm"
                    style={{ marginTop: 10, background: 'var(--red-50)', color: 'var(--red-600)', borderColor: 'var(--red-100)' }}
                    onClick={() => {
                      const params = new URLSearchParams()
                      if (desde) params.set('desde', desde)
                      if (hasta) params.set('hasta', hasta)
                      const qs = params.toString() ? `?${params.toString()}` : ''
                      setPdfModal({ url: `/api/pdf/cta-cte/${selCli}${qs}`, titulo: `Cuenta Corriente — ${data.cliente.razon_social}` })
                    }}
                  >
                    📄 Generar PDF
                  </button>
                  <button
                    className="btn btn-secondary btn-sm"
                    style={{ marginTop: 10, marginLeft: 6, background: 'var(--green-50)', color: 'var(--green-700)', borderColor: 'var(--green-100)' }}
                    onClick={() => exportarCtaCte(data, data.cliente, 'Cliente', fDoc(data.cliente.doc_tipo, data.cliente.doc_nro))}
                  >
                    📊 Excel
                  </button>
                </div>
              </div>

              {/* Filtro de fechas */}
              <div className="financiero-filtros">
                <span style={{ fontSize: 'calc(12px * var(--font-scale))', color: 'var(--gray-500)', fontWeight: 600 }}>Filtrar por período:</span>
                <input type="date" className="inp" style={{ width: 150 }} value={desde} onChange={e => setDesde(e.target.value)} />
                <span style={{ color: 'var(--gray-400)' }}>al</span>
                <input type="date" className="inp" style={{ width: 150 }} value={hasta} onChange={e => setHasta(e.target.value)} />
                <button className="btn btn-secondary btn-sm" onClick={() => cargar()}>Aplicar</button>
                <button className="btn btn-ghost btn-sm" onClick={() => { setDesde(''); setHasta(''); cargar({}) }}>Limpiar</button>
              </div>
            </div>

            {/* Tabla de movimientos */}
            <div className="tbl-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Fecha</th>
                    <th>Comprobante</th>
                    <th>Tipo</th>
                    <th className="th-right">Debe ($)</th>
                    <th className="th-right">Haber ($)</th>
                    <th className="th-right">Saldo ($)</th>
                  </tr>
                </thead>
                <tbody>
                  {data.movimientos.length === 0 ? (
                    <tr><td colSpan={6} style={{ textAlign: 'center', padding: '40px', color: 'var(--gray-400)' }}>Sin movimientos en el período</td></tr>
                  ) : data.movimientos.map((m, i) => {
                    const ts = TIPO_STYLE[m.tipo] || { bg: 'var(--gray-100)', color: 'var(--gray-600)', label: m.tipo }
                    return (
                      <tr key={i}>
                        <td>{fFecha(m.fecha)}</td>
                        <td><span className="code">{m.comprobante}</span></td>
                        <td>
                          <span style={{ background: ts.bg, color: ts.color, padding: '2px 9px', borderRadius: 10, fontSize: 'calc(11px * var(--font-scale))', fontWeight: 700 }}>
                            {ts.label}
                          </span>
                        </td>
                        <td className="td-right" style={{ color: parseFloat(m.debe) > 0 ? 'var(--red-500)' : 'var(--gray-300)', fontWeight: parseFloat(m.debe) > 0 ? 600 : 400 }}>
                          {parseFloat(m.debe) > 0 ? $ar(m.debe) : '—'}
                        </td>
                        <td className="td-right" style={{ color: parseFloat(m.haber) > 0 ? 'var(--green-600)' : 'var(--gray-300)', fontWeight: parseFloat(m.haber) > 0 ? 600 : 400 }}>
                          {parseFloat(m.haber) > 0 ? $ar(m.haber) : '—'}
                        </td>
                        <td className="td-right" style={{ fontWeight: 700, color: parseFloat(m.saldo) > 0 ? 'var(--red-500)' : parseFloat(m.saldo) < 0 ? 'var(--green-600)' : 'var(--gray-600)' }}>
                          {$ar(m.saldo)}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </div>
        ) : null}
      </div>

      {pdfModal && <PDFModal url={pdfModal.url} titulo={pdfModal.titulo} onClose={() => setPdfModal(null)} />}
    </div>
  )
}
