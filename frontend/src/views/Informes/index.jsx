// src/views/Informes/index.jsx
import { useState, useEffect } from 'react'
import { InformesAPI, ClientesAPI } from '../../api'
import { $ar, fFecha, hoy } from '../../utils'
import { Loading } from '../../components/UI'
import PDFModal from '../../components/PDFModal'
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Cell
} from 'recharts'

const TABS = [
  { id: 'ventas',     label: '📊 Ventas por período' },
  { id: 'clientes',   label: '🏆 Ranking de clientes' },
  { id: 'deudores',   label: '🚨 Ranking de deudores' },
  { id: 'pendientes', label: '⏳ Pendientes' },
]

const primerDiaMes = () => {
  const d = new Date(); d.setDate(1)
  return d.toISOString().split('T')[0]
}

export default function Informes() {
  const [tab, setTab]           = useState('ventas')
  const [desde, setDesde]       = useState(primerDiaMes())
  const [hasta, setHasta]       = useState(hoy())
  const [filtroCli, setFiltroCli] = useState('')
  const [clientes, setClientes] = useState([])
  const [data, setData]         = useState(null)
  const [loading, setLoading]   = useState(false)
  const [pdfModal, setPdfModal] = useState(null)

  useEffect(() => { ClientesAPI.list().then(setClientes) }, [])
  useEffect(() => { cargar() }, [tab])

  const cargar = async () => {
    setLoading(true)
    setData(null)
    try {
      switch (tab) {
        case 'ventas':
          setData(await InformesAPI.ventas({ desde, hasta, cliente_id: filtroCli || undefined }))
          break
        case 'clientes':
          setData(await InformesAPI.rankingClientes({ desde, hasta }))
          break
        case 'deudores':
          setData(await InformesAPI.rankingDeudores())
          break
        case 'pendientes':
          const [rems, facs] = await Promise.all([
            InformesAPI.remPendientesFacturar(),
            InformesAPI.facPendientesRemitir(),
          ])
          setData({ remitos: rems, facturas: facs })
          break
      }
    } finally {
      setLoading(false)
    }
  }

  const COLORS = ['#1d4ed8','#10b981','#f97316','#7c3aed','#ef4444','#0891b2','#d97706','#059669']

  return (
    <div>
      {/* Tabs */}
      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '2px solid var(--gray-200)' }}>
        {TABS.map(t => (
          <button
            key={t.id}
            onClick={() => setTab(t.id)}
            style={{
              padding: '10px 18px',
              background: 'transparent',
              border: 'none',
              borderBottom: tab === t.id ? '2px solid var(--blue-600)' : '2px solid transparent',
              marginBottom: -2,
              color: tab === t.id ? 'var(--blue-600)' : 'var(--gray-500)',
              fontWeight: tab === t.id ? 700 : 400,
              fontSize: 13,
              cursor: 'pointer',
              fontFamily: 'inherit',
              whiteSpace: 'nowrap',
              transition: 'color .15s',
            }}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* Filtros */}
      {(tab === 'ventas' || tab === 'clientes') && (
        <div style={{ display: 'flex', gap: 10, marginBottom: 18, alignItems: 'flex-end', flexWrap: 'wrap' }}>
          <div>
            <label className="lbl">Desde</label>
            <input type="date" className="inp" style={{ width: 150 }} value={desde} onChange={e => setDesde(e.target.value)} />
          </div>
          <div>
            <label className="lbl">Hasta</label>
            <input type="date" className="inp" style={{ width: 150 }} value={hasta} onChange={e => setHasta(e.target.value)} />
          </div>
          {tab === 'ventas' && (
            <div>
              <label className="lbl">Cliente (opcional)</label>
              <select className="sel" style={{ width: 220 }} value={filtroCli} onChange={e => setFiltroCli(e.target.value)}>
                <option value="">Todos los clientes</option>
                {clientes.map(c => <option key={c.id} value={c.id}>{c.razon_social}</option>)}
              </select>
            </div>
          )}
          <button className="btn btn-primary" onClick={cargar} style={{ marginTop: 2 }}>Consultar</button>
          {tab === 'ventas' && data && (
            <button
              className="btn btn-secondary btn-sm"
              style={{ marginTop: 2, background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }}
              onClick={() => {
                const p = new URLSearchParams({ desde, hasta })
                if (filtroCli) p.set('cliente_id', filtroCli)
                setPdfModal({ url: `/api/pdf/ventas?${p.toString()}`, titulo: `Resumen de Ventas ${desde} / ${hasta}` })
              }}
            >
              📄 Exportar PDF
            </button>
          )}
        </div>
      )}

      {loading ? <Loading /> : data && (
        <>
          {/* VENTAS POR PERÍODO */}
          {tab === 'ventas' && (
            <div>
              {/* KPIs del período */}
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 14, marginBottom: 20 }}>
                {[
                  { label: 'Facturas emitidas',  val: data.totales.cantidad_facturas, color: 'var(--blue-600)' },
                  { label: 'Neto gravado',        val: $ar(data.totales.neto_gravado || 0), color: 'var(--gray-600)' },
                  { label: 'IVA 21%',             val: $ar(data.totales.iva_total || 0), color: 'var(--gray-600)' },
                  { label: 'Total facturado',     val: $ar(data.totales.total_facturado || 0), color: '#10b981' },
                  { label: 'Total cobrado',       val: $ar(data.totales.total_cobrado || 0), color: 'var(--green-700)' },
                  { label: 'Total pendiente',     val: $ar(data.totales.total_pendiente || 0), color: 'var(--red-500)' },
                  { label: 'Descuentos otorgados',val: $ar(data.totales.descuento_total || 0), color: 'var(--amber-600)' },
                  { label: 'Cant. clientes',      val: data.por_cliente.length, color: 'var(--purple-600)' },
                ].map(k => (
                  <div key={k.label} className="card" style={{ padding: '12px 16px' }}>
                    <div className="kpi-label">{k.label}</div>
                    <div className="kpi-value" style={{ color: k.color, fontSize: 17, margin: '5px 0 0' }}>{k.val}</div>
                  </div>
                ))}
              </div>

              {/* Gráfico por mes */}
              {data.por_mes.length > 0 && (
                <div className="card" style={{ marginBottom: 18 }}>
                  <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 14 }}>Facturación mensual</div>
                  <ResponsiveContainer width="100%" height={220}>
                    <BarChart data={data.por_mes} margin={{ top: 4, right: 16, bottom: 4, left: 60 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--gray-200)" />
                      <XAxis dataKey="mes" tick={{ fontSize: 12 }} />
                      <YAxis tickFormatter={v => `$${(v/1000).toFixed(0)}k`} tick={{ fontSize: 11 }} />
                      <Tooltip formatter={v => [$ar(v), 'Total']} labelStyle={{ fontWeight: 700 }} />
                      <Bar dataKey="total" fill="var(--blue-600)" radius={[4,4,0,0]}>
                        {data.por_mes.map((_, i) => <Cell key={i} fill={COLORS[i % COLORS.length]} />)}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              )}

              {/* Top productos */}
              {data.por_producto.length > 0 && (
                <div className="card" style={{ marginBottom: 18 }}>
                  <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 14 }}>Top productos facturados</div>
                  <div className="tbl-wrap" style={{ boxShadow: 'none', border: 'none' }}>
                    <table>
                      <thead><tr>
                        <th>#</th><th>Código</th><th>Descripción</th>
                        <th className="th-right">Cant. total</th><th className="th-right">Neto facturado</th>
                      </tr></thead>
                      <tbody>
                        {data.por_producto.slice(0, 10).map((p, i) => (
                          <tr key={i}>
                            <td style={{ color: 'var(--gray-400)', fontWeight: 700 }}>{i + 1}</td>
                            <td><span className="code">{p.codigo || '—'}</span></td>
                            <td>{p.descripcion || '—'}</td>
                            <td className="td-right">{p.total_cantidad}</td>
                            <td className="td-right td-bold">{$ar(p.total_neto)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}

              {/* Por cliente */}
              {data.por_cliente.length > 0 && (
                <div className="card">
                  <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 14 }}>Ventas por cliente</div>
                  <div className="tbl-wrap" style={{ boxShadow: 'none', border: 'none' }}>
                    <table>
                      <thead><tr>
                        <th>Cliente</th><th>CUIT</th><th className="th-right">Facturas</th>
                        <th className="th-right">Total</th><th className="th-right">Pendiente</th>
                      </tr></thead>
                      <tbody>
                        {data.por_cliente.map((c, i) => (
                          <tr key={i}>
                            <td className="td-bold">{c.razon_social}</td>
                            <td className="td-mono">{c.cuit}</td>
                            <td className="td-right">{c.cantidad_facturas}</td>
                            <td className="td-right td-bold">{$ar(c.total_facturado)}</td>
                            <td className="td-right" style={{ color: parseFloat(c.pendiente) > 0 ? 'var(--red-500)' : 'var(--green-600)', fontWeight: 600 }}>
                              {parseFloat(c.pendiente) > 0 ? $ar(c.pendiente) : '✓ Cobrada'}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}
            </div>
          )}

          {/* RANKING CLIENTES */}
          {tab === 'clientes' && Array.isArray(data) && (
            <div>
              <div className="card" style={{ marginBottom: 16 }}>
                <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 14 }}>Ranking de clientes por volumen de compra</div>
                {data.length > 0 && (
                  <ResponsiveContainer width="100%" height={200}>
                    <BarChart data={data.slice(0, 10)} layout="vertical" margin={{ top: 4, right: 60, bottom: 4, left: 180 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--gray-200)" />
                      <XAxis type="number" tickFormatter={v => `$${(v/1000).toFixed(0)}k`} tick={{ fontSize: 11 }} />
                      <YAxis type="category" dataKey="razon_social" tick={{ fontSize: 11 }} width={175}
                        tickFormatter={v => v.length > 24 ? v.slice(0, 24) + '…' : v} />
                      <Tooltip formatter={v => [$ar(v), 'Total facturado']} />
                      <Bar dataKey="total_facturado" fill="var(--blue-600)" radius={[0,4,4,0]}>
                        {data.slice(0,10).map((_,i) => <Cell key={i} fill={COLORS[i % COLORS.length]} />)}
                      </Bar>
                    </BarChart>
                  </ResponsiveContainer>
                )}
              </div>
              <div className="tbl-wrap">
                <table>
                  <thead><tr>
                    <th>#</th><th>Cliente</th><th>CUIT</th><th className="th-right">Facturas</th>
                    <th className="th-right">Total facturado</th><th className="th-right">Saldo pendiente</th><th>Última compra</th>
                  </tr></thead>
                  <tbody>
                    {data.length === 0
                      ? <tr><td colSpan={7} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin datos para el período</td></tr>
                      : data.map((c, i) => (
                        <tr key={c.id}>
                          <td style={{ fontWeight: 800, color: i < 3 ? 'var(--amber-600)' : 'var(--gray-400)' }}>{i + 1}</td>
                          <td className="td-bold">{c.razon_social}</td>
                          <td className="td-mono">{c.cuit}</td>
                          <td className="td-right">{c.cantidad_facturas}</td>
                          <td className="td-right td-bold">{$ar(c.total_facturado)}</td>
                          <td className="td-right" style={{ color: parseFloat(c.saldo_pendiente) > 0 ? 'var(--red-500)' : 'var(--green-600)', fontWeight: 600 }}>
                            {parseFloat(c.saldo_pendiente) > 0 ? $ar(c.saldo_pendiente) : '✓'}
                          </td>
                          <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{fFecha(c.ultima_compra)}</td>
                        </tr>
                      ))
                    }
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {/* RANKING DEUDORES */}
          {tab === 'deudores' && Array.isArray(data) && (
            <div>
              {data.length === 0 ? (
                <div className="card" style={{ textAlign: 'center', padding: '60px 20px', color: 'var(--green-600)' }}>
                  <div style={{ fontSize: 40, marginBottom: 12 }}>🎉</div>
                  <p style={{ fontWeight: 700, fontSize: 16 }}>¡Sin deudas pendientes!</p>
                  <p style={{ color: 'var(--gray-400)', marginTop: 4 }}>Todos los clientes están al día.</p>
                </div>
              ) : (
                <>
                  {/* Alerta total adeudado */}
                  <div style={{ background: 'var(--red-50)', border: '1px solid var(--red-100)', borderRadius: 10, padding: '14px 18px', marginBottom: 18, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <div>
                      <div style={{ fontWeight: 700, color: 'var(--red-600)', fontSize: 15 }}>Total adeudado por clientes</div>
                      <div style={{ fontSize: 12, color: 'var(--red-400)', marginTop: 2 }}>{data.length} cliente(s) con saldo pendiente</div>
                    </div>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                      <div style={{ fontSize: 26, fontWeight: 800, color: 'var(--red-600)' }}>
                        {$ar(data.reduce((a, c) => a + parseFloat(c.total_pendiente || 0), 0))}
                      </div>
                      <button
                        className="btn btn-secondary btn-sm"
                        style={{ background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }}
                        onClick={() => setPdfModal({ url: '/api/pdf/ranking-deudores', titulo: 'Ranking de Deudores' })}
                      >
                        📄 Exportar PDF
                      </button>
                    </div>
                  </div>
                  <div className="tbl-wrap">
                    <table>
                      <thead><tr>
                        <th>#</th><th>Cliente</th><th>CUIT</th><th>Teléfono</th>
                        <th className="th-right">Facturas pend.</th>
                        <th className="th-right">Total adeudado</th>
                        <th className="th-right">Factura más antigua</th>
                        <th className="th-right">Días de deuda</th>
                      </tr></thead>
                      <tbody>
                        {data.map((c, i) => (
                          <tr key={c.id}>
                            <td style={{ fontWeight: 800, color: i < 3 ? 'var(--red-500)' : 'var(--gray-400)' }}>{i + 1}</td>
                            <td className="td-bold">{c.razon_social}</td>
                            <td className="td-mono">{c.cuit}</td>
                            <td style={{ fontSize: 12 }}>{c.telefono || '—'}</td>
                            <td className="td-right">{c.facturas_pendientes}</td>
                            <td className="td-right" style={{ color: 'var(--red-500)', fontWeight: 700 }}>{$ar(c.total_pendiente)}</td>
                            <td className="td-right" style={{ fontSize: 12, color: 'var(--gray-500)' }}>{fFecha(c.factura_mas_antigua)}</td>
                            <td className="td-right">
                              <span style={{ background: c.dias_deuda > 60 ? 'var(--red-100)' : c.dias_deuda > 30 ? 'var(--amber-100)' : 'var(--green-100)', color: c.dias_deuda > 60 ? 'var(--red-600)' : c.dias_deuda > 30 ? 'var(--amber-600)' : 'var(--green-600)', padding: '2px 8px', borderRadius: 8, fontSize: 12, fontWeight: 700 }}>
                                {c.dias_deuda} días
                              </span>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </>
              )}
            </div>
          )}

          {/* PENDIENTES */}
          {tab === 'pendientes' && data.remitos && (
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 18 }}>
              {/* Remitos pendientes a facturar */}
              <div className="card">
                <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 14, color: 'var(--gray-800)' }}>
                  🚚 Remitos pendientes de facturar
                  <span style={{ background: 'var(--amber-100)', color: 'var(--amber-600)', padding: '2px 8px', borderRadius: 10, fontSize: 12, marginLeft: 8 }}>{data.remitos.length}</span>
                </div>
                {data.remitos.length === 0
                  ? <p style={{ color: 'var(--gray-400)', fontSize: 13, textAlign: 'center', padding: 20 }}>Sin remitos pendientes</p>
                  : <div className="tbl-wrap" style={{ boxShadow: 'none', border: 'none' }}>
                    <table>
                      <thead><tr><th>Remito</th><th>Fecha</th><th>Cliente</th><th className="th-right">Días</th></tr></thead>
                      <tbody>
                        {data.remitos.map(r => (
                          <tr key={r.id}>
                            <td><span className="code">{r.numero}</span></td>
                            <td style={{ fontSize: 12 }}>{fFecha(r.fecha)}</td>
                            <td style={{ fontSize: 12, fontWeight: 500 }}>{r.razon_social.length > 22 ? r.razon_social.slice(0, 22) + '…' : r.razon_social}</td>
                            <td className="td-right">
                              <span style={{ background: r.dias_pendiente > 7 ? 'var(--red-100)' : 'var(--amber-100)', color: r.dias_pendiente > 7 ? 'var(--red-600)' : 'var(--amber-600)', padding: '2px 7px', borderRadius: 8, fontSize: 11, fontWeight: 700 }}>
                                {r.dias_pendiente}d
                              </span>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                }
              </div>

              {/* Facturas pendientes de remitir */}
              <div className="card">
                <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 14, color: 'var(--gray-800)' }}>
                  🧾 Facturas pendientes de remitir
                  <span style={{ background: 'var(--blue-100)', color: 'var(--blue-600)', padding: '2px 8px', borderRadius: 10, fontSize: 12, marginLeft: 8 }}>{data.facturas.length}</span>
                </div>
                {data.facturas.length === 0
                  ? <p style={{ color: 'var(--gray-400)', fontSize: 13, textAlign: 'center', padding: 20 }}>Sin facturas pendientes</p>
                  : <div className="tbl-wrap" style={{ boxShadow: 'none', border: 'none' }}>
                    <table>
                      <thead><tr><th>Factura</th><th>Fecha</th><th>Cliente</th><th className="th-right">Total</th><th className="th-right">Días</th></tr></thead>
                      <tbody>
                        {data.facturas.map(f => (
                          <tr key={f.id}>
                            <td><span className="code">{f.numero}</span></td>
                            <td style={{ fontSize: 12 }}>{fFecha(f.fecha)}</td>
                            <td style={{ fontSize: 12, fontWeight: 500 }}>{f.razon_social.length > 18 ? f.razon_social.slice(0, 18) + '…' : f.razon_social}</td>
                            <td className="td-right td-bold">{$ar(f.total)}</td>
                            <td className="td-right">
                              <span style={{ background: f.dias_pendiente > 7 ? 'var(--red-100)' : 'var(--amber-100)', color: f.dias_pendiente > 7 ? 'var(--red-600)' : 'var(--amber-600)', padding: '2px 7px', borderRadius: 8, fontSize: 11, fontWeight: 700 }}>
                                {f.dias_pendiente}d
                              </span>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                }
              </div>
            </div>
          )}
        </>
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
