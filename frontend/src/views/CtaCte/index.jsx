// src/views/CtaCte/index.jsx
import { useState, useEffect } from 'react'
import { InformesAPI, ClientesAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Loading } from '../../components/UI'
import PDFModal from '../../components/PDFModal'

const TIPO_STYLE = {
  FACTURA:    { bg: '#fef3c7', color: '#92400e', label: 'Factura' },
  RECIBO:     { bg: '#d1fae5', color: '#065f46', label: 'Recibo' },
  'NOTA CRED.': { bg: '#e0e7ff', color: '#3730a3', label: 'NC' },
  'NOTA DEB.':  { bg: '#fce7f3', color: '#9d174d', label: 'ND' },
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

  const cargar = () => {
    if (!selCli) return
    setLoading(true)
    const params = {}
    if (desde) params.desde = desde
    if (hasta) params.hasta = hasta
    InformesAPI.ctaCte(selCli, params).then(setData).finally(() => setLoading(false))
  }

  useEffect(() => { if (selCli) cargar() }, [selCli])

  const clisFiltrados = clientes.filter(c =>
    !search || c.razon_social.toLowerCase().includes(search.toLowerCase()) || c.cuit.includes(search)
  )

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '270px 1fr', gap: 18, height: 'calc(100vh - 54px - 48px)', overflow: 'hidden' }}>
      {/* Panel izquierdo: lista de clientes */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 0, overflow: 'hidden' }}>
        <div className="card" style={{ padding: '14px', marginBottom: 0, borderBottom: 'none', borderBottomLeftRadius: 0, borderBottomRightRadius: 0 }}>
          <input
            className="search-inp"
            style={{ width: '100%' }}
            placeholder="Buscar cliente…"
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <div style={{ flex: 1, overflowY: 'auto', background: '#fff', border: '1px solid var(--gray-200)', borderTopLeftRadius: 0, borderTopRightRadius: 0, borderRadius: '0 0 12px 12px' }}>
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
                <div style={{ fontWeight: selCli === c.id ? 700 : 500, fontSize: 13, color: 'var(--gray-800)' }}>
                  {c.razon_social.length > 28 ? c.razon_social.slice(0, 28) + '…' : c.razon_social}
                </div>
                {saldo !== null && (
                  <div style={{ fontSize: 12, fontWeight: 700, color: saldo > 0 ? 'var(--red-500)' : saldo < 0 ? '#10b981' : 'var(--gray-400)', marginTop: 2 }}>
                    {$ar(saldo)} {saldo > 0 ? '▲ Debe' : saldo < 0 ? '▼ A favor' : '✓ Sin saldo'}
                  </div>
                )}
                {saldo === null && <div style={{ fontSize: 11, color: 'var(--gray-400)', marginTop: 2 }}>{c.cuit}</div>}
              </div>
            )
          })}
        </div>
      </div>

      {/* Panel derecho: movimientos */}
      <div style={{ overflowY: 'auto' }}>
        {!selCli ? (
          <div className="card" style={{ textAlign: 'center', padding: '60px 20px' }}>
            <div style={{ fontSize: 40, marginBottom: 12 }}>📒</div>
            <p style={{ color: 'var(--gray-400)', fontSize: 14 }}>Seleccione un cliente para ver su cuenta corriente</p>
          </div>
        ) : loading ? (
          <Loading />
        ) : data ? (
          <div>
            {/* Header del cliente */}
            <div className="card" style={{ marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <h2 style={{ fontSize: 17, fontWeight: 700, color: 'var(--gray-800)' }}>{data.cliente.razon_social}</h2>
                  <div style={{ fontSize: 13, color: 'var(--gray-500)', marginTop: 4 }}>
                    CUIT: {data.cliente.cuit} &nbsp;·&nbsp; {data.cliente.condicion_iva}
                    {data.cliente.email && ` · ${data.cliente.email}`}
                  </div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px', marginBottom: 4 }}>Saldo actual</div>
                  <div style={{ fontSize: 28, fontWeight: 800, color: data.saldo_total > 0 ? 'var(--red-500)' : data.saldo_total < 0 ? '#10b981' : 'var(--gray-400)', lineHeight: 1 }}>
                    {$ar(data.saldo_total)}
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 4 }}>
                    {data.saldo_total > 0 ? '⬆ Saldo deudor' : data.saldo_total < 0 ? '⬇ Saldo a favor' : '✓ Cuenta balanceada'}
                  </div>
                  <button
                    className="btn btn-secondary btn-sm"
                    style={{ marginTop: 10, background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }}
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
                </div>
              </div>

              {/* Filtro de fechas */}
              <div style={{ display: 'flex', gap: 10, marginTop: 14, paddingTop: 14, borderTop: '1px solid var(--gray-100)', alignItems: 'center' }}>
                <span style={{ fontSize: 12, color: 'var(--gray-500)', fontWeight: 600 }}>Filtrar por período:</span>
                <input type="date" className="inp" style={{ width: 150 }} value={desde} onChange={e => setDesde(e.target.value)} />
                <span style={{ color: 'var(--gray-400)' }}>al</span>
                <input type="date" className="inp" style={{ width: 150 }} value={hasta} onChange={e => setHasta(e.target.value)} />
                <button className="btn btn-secondary btn-sm" onClick={cargar}>Aplicar</button>
                <button className="btn btn-ghost btn-sm" onClick={() => { setDesde(''); setHasta(''); setTimeout(cargar, 0) }}>Limpiar</button>
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
                          <span style={{ background: ts.bg, color: ts.color, padding: '2px 9px', borderRadius: 10, fontSize: 11, fontWeight: 700 }}>
                            {ts.label}
                          </span>
                        </td>
                        <td className="td-right" style={{ color: parseFloat(m.debe) > 0 ? 'var(--red-500)' : 'var(--gray-300)', fontWeight: parseFloat(m.debe) > 0 ? 600 : 400 }}>
                          {parseFloat(m.debe) > 0 ? $ar(m.debe) : '—'}
                        </td>
                        <td className="td-right" style={{ color: parseFloat(m.haber) > 0 ? '#10b981' : 'var(--gray-300)', fontWeight: parseFloat(m.haber) > 0 ? 600 : 400 }}>
                          {parseFloat(m.haber) > 0 ? $ar(m.haber) : '—'}
                        </td>
                        <td className="td-right" style={{ fontWeight: 700, color: parseFloat(m.saldo) > 0 ? 'var(--red-500)' : parseFloat(m.saldo) < 0 ? '#10b981' : 'var(--gray-600)' }}>
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
