// src/views/Informes/index.jsx
import { useState, useEffect } from 'react'
import { InformesAPI, ClientesAPI, CuentasBancariasAPI, MovimientosTesoreriaAPI, PlanCuentasAPI, pdfUrl } from '../../api'
import { $ar, fFecha, hoy } from '../../utils'
import { Loading } from '../../components/UI'
import PDFModal from '../../components/PDFModal'
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Cell
} from 'recharts'

const TABS = [
  { id: 'ventas',         label: '📊 Ventas por período' },
  { id: 'clientes',       label: '🏆 Ranking de clientes' },
  { id: 'deudores',       label: '🚨 Ranking de deudores' },
  { id: 'pendientes',     label: '⏳ Pendientes' },
  { id: 'iva_compras',    label: '📚 Libro IVA Compras' },
  { id: 'nomina_prov',    label: '🏭 Nómina proveedores' },
  { id: 'precios_compra', label: '🏷️ Precios de compra' },
  { id: 'saldos_tes',     label: '🏦 Saldos tesorería' },
  { id: 'subdiario_tes',  label: '📖 Subdiario por cuenta' },
  { id: 'mayor_tes',      label: '📊 Mayor tesorería' },
  { id: 'oper_tes',       label: '🔀 Movimientos por operación' },
  { id: 'cheques_tes',    label: '💳 Cheques' },
  { id: 'comprob_tes',    label: '🧾 Comprobantes tesorería' },
  { id: 'historico_tes',  label: '🕓 Histórico' },
  { id: 'libro_diario',   label: '📘 Libro Diario' },
  { id: 'libro_mayor',    label: '📗 Libro Mayor' },
  { id: 'sumas_saldos',   label: '⚖️ Sumas y Saldos' },
]

// tabs de tesorería que usan el rango desde/hasta (saldos es snapshot, no lleva fecha)
const TES_FECHA_TABS = ['subdiario_tes', 'mayor_tes', 'oper_tes', 'cheques_tes', 'comprob_tes', 'historico_tes']
// tabs contables (Fase E) — todas van por rango de fechas; el mayor además pide cuenta
const CTB_FECHA_TABS = ['libro_diario', 'libro_mayor', 'sumas_saldos']

const primerDiaMes = () => {
  const d = new Date(); d.setDate(1)
  return d.toISOString().split('T')[0]
}

export default function Informes() {
  const [tab, setTab]           = useState('ventas')
  const [desde, setDesde]       = useState(primerDiaMes())
  const [hasta, setHasta]       = useState(hoy())
  const [filtroCli, setFiltroCli] = useState('')
  const [qMaterial, setQMaterial] = useState('')
  const [clientes, setClientes] = useState([])
  const [cuentasTes, setCuentasTes] = useState([])
  const [cuentaTes, setCuentaTes]   = useState('')
  const [estadoCheque, setEstadoCheque] = useState('')
  const [cuentasCtb, setCuentasCtb] = useState([])
  const [cuentaCtb, setCuentaCtb]   = useState('')
  const [data, setData]         = useState(null)
  const [loading, setLoading]   = useState(false)
  const [pdfModal, setPdfModal] = useState(null)

  useEffect(() => { ClientesAPI.list().then(setClientes) }, [])
  useEffect(() => {
    CuentasBancariasAPI.list({ activo: true }).then(cs => {
      setCuentasTes(cs)
      setCuentaTes(prev => prev || (cs[0] ? String(cs[0].id) : ''))
    })
  }, [])
  // El libro mayor es por cuenta: sólo tiene sentido sobre cuentas imputables activas.
  useEffect(() => {
    PlanCuentasAPI.list({ imputable: true, activo: true }).then(cs => {
      setCuentasCtb(cs)
      setCuentaCtb(prev => prev || (cs[0] ? String(cs[0].id) : ''))
    })
  }, [])
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
        case 'iva_compras':
          setData(await InformesAPI.ivaCompras({ desde, hasta }))
          break
        case 'nomina_prov':
          setData(await InformesAPI.nominaProveedores())
          break
        case 'precios_compra':
          setData(await InformesAPI.preciosCompra({ q: qMaterial || undefined }))
          break
        case 'saldos_tes':
          setData(await InformesAPI.saldosTesoreria())
          break
        case 'subdiario_tes':
          if (!cuentaTes) { setData(null); break }
          setData(await InformesAPI.subdiarioCuenta(Number(cuentaTes), { desde, hasta }))
          break
        case 'mayor_tes':
          setData(await InformesAPI.mayorTesoreria({ desde, hasta }))
          break
        case 'oper_tes':
          setData(await InformesAPI.movimientosPorOperacion({ desde, hasta }))
          break
        case 'cheques_tes':
          setData(await InformesAPI.chequesTesoreria({ estado: estadoCheque || undefined, desde, hasta }))
          break
        case 'comprob_tes':
          setData(await InformesAPI.comprobantesTesoreria({ desde, hasta }))
          break
        case 'historico_tes':
          setData(await MovimientosTesoreriaAPI.list({ desde, hasta }))
          break
        case 'libro_diario':
          setData(await InformesAPI.libroDiario({ desde, hasta }))
          break
        case 'libro_mayor':
          if (!cuentaCtb) { setData(null); break }
          setData(await InformesAPI.libroMayor(Number(cuentaCtb), { desde, hasta }))
          break
        case 'sumas_saldos':
          setData(await InformesAPI.sumasYSaldos({ desde, hasta }))
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
      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '2px solid var(--gray-200)', overflowX: 'auto' }}>
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
      {tab === 'precios_compra' && (
        <div style={{ display: 'flex', gap: 10, marginBottom: 18, alignItems: 'flex-end', flexWrap: 'wrap' }}>
          <div>
            <label className="lbl">Buscar material</label>
            <input className="inp" style={{ width: 260 }} placeholder="Código o descripción…" value={qMaterial} onChange={e => setQMaterial(e.target.value)} />
          </div>
          <button className="btn btn-primary" onClick={cargar} style={{ marginTop: 2 }}>Consultar</button>
        </div>
      )}

      {(tab === 'ventas' || tab === 'clientes' || tab === 'iva_compras' || TES_FECHA_TABS.includes(tab) || CTB_FECHA_TABS.includes(tab)) && (
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
          {tab === 'subdiario_tes' && (
            <div>
              <label className="lbl">Cuenta</label>
              <select className="sel" style={{ width: 220 }} value={cuentaTes} onChange={e => setCuentaTes(e.target.value)}>
                <option value="">Seleccionar cuenta…</option>
                {cuentasTes.map(c => <option key={c.id} value={c.id}>{c.descripcion}</option>)}
              </select>
            </div>
          )}
          {tab === 'libro_mayor' && (
            <div>
              <label className="lbl">Cuenta</label>
              <select className="sel" style={{ width: 300 }} value={cuentaCtb} onChange={e => setCuentaCtb(e.target.value)}>
                <option value="">Seleccionar cuenta…</option>
                {cuentasCtb.map(c => <option key={c.id} value={c.id}>{c.codigo} — {c.descripcion}</option>)}
              </select>
            </div>
          )}
          {tab === 'cheques_tes' && (
            <div>
              <label className="lbl">Estado (opcional)</label>
              <select className="sel" style={{ width: 200 }} value={estadoCheque} onChange={e => setEstadoCheque(e.target.value)}>
                <option value="">Todos</option>
                <option value="en_cartera">En cartera (terceros)</option>
                <option value="depositado">Depositado (terceros)</option>
                <option value="entregado">Entregado</option>
                <option value="emitido">Emitido (propios)</option>
                <option value="pagado">Pagado (propios)</option>
                <option value="rechazado_banco">Rechazado (terceros)</option>
                <option value="rechazado">Rechazado (propios)</option>
                <option value="anulado">Anulado</option>
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
          {tab === 'subdiario_tes' && data && cuentaTes && (
            <button
              className="btn btn-secondary btn-sm"
              style={{ marginTop: 2, background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }}
              onClick={() => setPdfModal({ url: pdfUrl.subdiarioTesoreria(Number(cuentaTes), desde, hasta), titulo: 'Subdiario por cuenta' })}
            >
              📄 Exportar PDF
            </button>
          )}
          {tab === 'mayor_tes' && data && (
            <button
              className="btn btn-secondary btn-sm"
              style={{ marginTop: 2, background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }}
              onClick={() => setPdfModal({ url: pdfUrl.mayorTesoreria(desde, hasta), titulo: `Mayor de Tesorería ${desde} / ${hasta}` })}
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
          {/* LIBRO IVA COMPRAS */}
          {tab === 'iva_compras' && data.comprobantes && (
            <div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 14, marginBottom: 20 }}>
                {[
                  { label: 'Comprobantes',   val: data.comprobantes.length, color: 'var(--blue-600)' },
                  { label: 'Neto gravado',    val: $ar(data.totales.neto_gravado || 0), color: 'var(--gray-600)' },
                  { label: 'IVA total',       val: $ar(data.totales.iva_monto || 0), color: 'var(--gray-600)' },
                  { label: 'Total compras',   val: $ar(data.totales.total || 0), color: '#f97316' },
                ].map(k => (
                  <div key={k.label} className="card" style={{ padding: '12px 16px' }}>
                    <div className="kpi-label">{k.label}</div>
                    <div className="kpi-value" style={{ color: k.color, fontSize: 17, margin: '5px 0 0' }}>{k.val}</div>
                  </div>
                ))}
              </div>

              <div className="tbl-wrap" style={{ marginBottom: 18 }}>
                <table>
                  <thead><tr>
                    <th>Fecha</th><th>Comprobante</th><th>Proveedor</th><th>CUIT</th>
                    <th>Alícuotas</th><th className="th-right">Neto</th><th className="th-right">IVA</th><th className="th-right">Total</th>
                  </tr></thead>
                  <tbody>
                    {data.comprobantes.length === 0
                      ? <tr><td colSpan={8} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin comprobantes en el período</td></tr>
                      : data.comprobantes.map((c, i) => (
                        <tr key={i}>
                          <td>{fFecha(c.fecha)}</td>
                          <td><span className={`badge badge-${c.tipo}`} style={{ marginRight: 6 }}>{c.tipo}</span><span className="code">{c.punto_venta}-{c.numero}</span></td>
                          <td className="td-bold">{c.razon_social}</td>
                          <td className="td-mono">{c.cuit}</td>
                          <td style={{ fontSize: 11, color: 'var(--gray-500)' }}>
                            {(c.iva_detalle || []).map((d, j) => (
                              <span key={j} style={{ display: 'inline-block', marginRight: 6 }}>{d.porcentaje}%: {$ar(d.iva_monto)}</span>
                            ))}
                          </td>
                          <td className="td-right">{$ar(c.neto_gravado)}</td>
                          <td className="td-right">{$ar(c.iva_monto)}</td>
                          <td className="td-right td-bold">{$ar(c.total)}</td>
                        </tr>
                      ))
                    }
                  </tbody>
                </table>
              </div>

              {data.retenciones?.length > 0 && (
                <div className="card">
                  <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 14 }}>
                    Retenciones aplicadas — total {$ar(data.totales.retenciones || 0)}
                  </div>
                  <div className="tbl-wrap" style={{ boxShadow: 'none', border: 'none' }}>
                    <table>
                      <thead><tr>
                        <th>Fecha</th><th>Proveedor</th><th>Tipo</th><th>Jurisdicción</th><th>Certificado</th><th className="th-right">Monto</th>
                      </tr></thead>
                      <tbody>
                        {data.retenciones.map((r, i) => (
                          <tr key={i}>
                            <td>{fFecha(r.fecha)}</td>
                            <td className="td-bold">{r.razon_social}</td>
                            <td>{r.tipo_retencion}</td>
                            <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{r.jurisdiccion || '—'}</td>
                            <td className="code">{r.numero_certificado || '—'}</td>
                            <td className="td-right td-bold">{$ar(r.monto)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}
            </div>
          )}

          {/* NÓMINA DE PROVEEDORES */}
          {tab === 'nomina_prov' && Array.isArray(data) && (
            <div className="tbl-wrap">
              <table>
                <thead><tr>
                  <th>Proveedor</th><th>CUIT</th><th>Cond. IVA</th><th>Cond. compra</th><th>Teléfono</th>
                  <th className="th-right">Facturas</th><th className="th-right">Total comprado</th><th className="th-right">Saldo pendiente</th>
                </tr></thead>
                <tbody>
                  {data.length === 0
                    ? <tr><td colSpan={8} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin proveedores</td></tr>
                    : data.map(p => (
                      <tr key={p.id} style={{ opacity: p.activo ? 1 : 0.5 }}>
                        <td className="td-bold">{p.razon_social}</td>
                        <td className="td-mono">{p.cuit}</td>
                        <td style={{ fontSize: 12 }}>{p.condicion_iva}</td>
                        <td style={{ fontSize: 12 }}>{p.condicion_compra}</td>
                        <td style={{ fontSize: 12 }}>{p.telefono || '—'}</td>
                        <td className="td-right">{p.cantidad_facturas}</td>
                        <td className="td-right td-bold">{$ar(p.total_comprado)}</td>
                        <td className="td-right" style={{ color: parseFloat(p.saldo_pendiente) > 0 ? 'var(--red-500)' : 'var(--green-600)', fontWeight: 600 }}>
                          {parseFloat(p.saldo_pendiente) > 0 ? $ar(p.saldo_pendiente) : '✓'}
                        </td>
                      </tr>
                    ))
                  }
                </tbody>
              </table>
            </div>
          )}

          {/* PRECIOS DE COMPRA */}
          {tab === 'precios_compra' && Array.isArray(data) && (
            <div className="tbl-wrap">
              <table>
                <thead><tr>
                  <th>Código</th><th>Descripción</th><th>Unidad</th>
                  <th className="th-right">Último precio</th><th>Última compra</th><th>Proveedor</th>
                </tr></thead>
                <tbody>
                  {data.length === 0
                    ? <tr><td colSpan={6} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin datos de compras de materiales</td></tr>
                    : data.map((m, i) => (
                      <tr key={i}>
                        <td><span className="code">{m.codigo || '—'}</span></td>
                        <td className="td-bold">{m.descripcion || '—'}</td>
                        <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{m.unidad_medida || '—'}</td>
                        <td className="td-right td-bold">{$ar(m.ultimo_precio)}</td>
                        <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{fFecha(m.fecha_ultima_compra)}</td>
                        <td style={{ fontSize: 12 }}>{m.ultimo_proveedor || '—'}</td>
                      </tr>
                    ))
                  }
                </tbody>
              </table>
            </div>
          )}
          {/* ═══════════════ TESORERÍA ═══════════════ */}

          {/* SALDOS TESORERÍA */}
          {tab === 'saldos_tes' && data.agrupaciones && (
            <div>
              <div style={{ background: '#eff6ff', border: '1px solid #dbeafe', borderRadius: 10, padding: '14px 18px', marginBottom: 18, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div style={{ fontWeight: 700, color: 'var(--blue-600)', fontSize: 15 }}>Saldo total de tesorería</div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
                  <div style={{ fontSize: 24, fontWeight: 800, color: 'var(--blue-600)' }}>{$ar(data.total_general || 0)}</div>
                  <button
                    className="btn btn-secondary btn-sm"
                    style={{ background: '#fef2f2', color: '#dc2626', borderColor: '#fecaca' }}
                    onClick={() => setPdfModal({ url: pdfUrl.saldosTesoreria(), titulo: 'Saldos de Tesorería' })}
                  >
                    📄 Exportar PDF
                  </button>
                </div>
              </div>
              {data.agrupaciones.length === 0
                ? <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin cuentas cargadas</div>
                : data.agrupaciones.map((g, gi) => (
                  <div className="card" key={gi} style={{ marginBottom: 16 }}>
                    <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 14, display: 'flex', justifyContent: 'space-between' }}>
                      <span>{g.descripcion}</span>
                      <span style={{ color: 'var(--gray-600)' }}>Subtotal: {$ar(g.subtotal || 0)}</span>
                    </div>
                    <div className="tbl-wrap" style={{ boxShadow: 'none', border: 'none' }}>
                      <table>
                        <thead><tr>
                          <th>Cuenta</th><th>Clase</th>
                          <th className="th-right">Saldo inicial</th><th className="th-right">Entradas</th>
                          <th className="th-right">Salidas</th><th className="th-right">Saldo actual</th>
                        </tr></thead>
                        <tbody>
                          {g.cuentas.map(c => (
                            <tr key={c.id}>
                              <td className="td-bold">{c.descripcion}</td>
                              <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{c.clase}</td>
                              <td className="td-right">{$ar(c.saldo_inicial || 0)}</td>
                              <td className="td-right" style={{ color: 'var(--green-600)' }}>{$ar(c.entradas || 0)}</td>
                              <td className="td-right" style={{ color: 'var(--red-500)' }}>{$ar(c.salidas || 0)}</td>
                              <td className="td-right td-bold">{$ar(c.saldo_actual || 0)}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </div>
                ))
              }
            </div>
          )}

          {/* SUBDIARIO POR CUENTA (saldo corrido) */}
          {tab === 'subdiario_tes' && data.movimientos && (
            <div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 14, marginBottom: 20 }}>
                {[
                  { label: 'Cuenta',        val: data.cuenta?.descripcion || '—', color: 'var(--gray-700)' },
                  { label: 'Saldo inicial', val: $ar(data.saldo_inicial || 0),    color: 'var(--gray-600)' },
                  { label: 'Saldo final',   val: $ar(data.saldo_final || 0),      color: 'var(--blue-600)' },
                ].map(k => (
                  <div key={k.label} className="card" style={{ padding: '12px 16px' }}>
                    <div className="kpi-label">{k.label}</div>
                    <div className="kpi-value" style={{ color: k.color, fontSize: 17, margin: '5px 0 0' }}>{k.val}</div>
                  </div>
                ))}
              </div>
              <div className="tbl-wrap">
                <table>
                  <thead><tr>
                    <th>Fecha</th><th>Tipo</th><th>Concepto</th>
                    <th className="th-right">Débito</th><th className="th-right">Crédito</th><th className="th-right">Saldo</th>
                  </tr></thead>
                  <tbody>
                    {data.movimientos.length === 0
                      ? <tr><td colSpan={6} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin movimientos en el período</td></tr>
                      : data.movimientos.map(m => (
                        <tr key={m.id} style={{ opacity: m.anulado ? 0.4 : 1 }}>
                          <td>{fFecha(m.fecha)}</td>
                          <td style={{ fontSize: 12 }}><span className="code">{m.tipo_codigo}</span> {m.tipo_descripcion}</td>
                          <td style={{ fontSize: 12 }}>{m.concepto || '—'}{m.anulado && <span style={{ color: 'var(--red-500)', marginLeft: 6 }}>(anulado)</span>}</td>
                          <td className="td-right" style={{ color: 'var(--red-500)' }}>{m.signo === -1 ? $ar(m.monto) : ''}</td>
                          <td className="td-right" style={{ color: 'var(--green-600)' }}>{m.signo === 1 ? $ar(m.monto) : ''}</td>
                          <td className="td-right td-bold">{$ar(m.saldo_corrido || 0)}</td>
                        </tr>
                      ))
                    }
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {/* MAYOR TESORERÍA */}
          {tab === 'mayor_tes' && data.cuentas && (
            <div className="tbl-wrap">
              <table>
                <thead><tr>
                  <th>Cuenta</th><th>Clase</th>
                  <th className="th-right">Saldo inicial</th><th className="th-right">Débitos</th>
                  <th className="th-right">Créditos</th><th className="th-right">Saldo final</th>
                </tr></thead>
                <tbody>
                  {data.cuentas.length === 0
                    ? <tr><td colSpan={6} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin cuentas</td></tr>
                    : data.cuentas.map(c => (
                      <tr key={c.id}>
                        <td className="td-bold">{c.descripcion}</td>
                        <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{c.clase}</td>
                        <td className="td-right">{$ar(c.saldo_inicial || 0)}</td>
                        <td className="td-right" style={{ color: 'var(--red-500)' }}>{$ar(c.debitos || 0)}</td>
                        <td className="td-right" style={{ color: 'var(--green-600)' }}>{$ar(c.creditos || 0)}</td>
                        <td className="td-right td-bold">{$ar(c.saldo_final || 0)}</td>
                      </tr>
                    ))
                  }
                </tbody>
                {data.totales && data.cuentas.length > 0 && (
                  <tfoot>
                    <tr style={{ fontWeight: 700, borderTop: '2px solid var(--gray-200)' }}>
                      <td colSpan={3} className="td-right">Totales</td>
                      <td className="td-right" style={{ color: 'var(--red-500)' }}>{$ar(data.totales.debitos || 0)}</td>
                      <td className="td-right" style={{ color: 'var(--green-600)' }}>{$ar(data.totales.creditos || 0)}</td>
                      <td className="td-right">{$ar(data.totales.saldo_final || 0)}</td>
                    </tr>
                  </tfoot>
                )}
              </table>
            </div>
          )}

          {/* MOVIMIENTOS POR OPERACIÓN */}
          {tab === 'oper_tes' && data.operaciones && (
            <div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 14, marginBottom: 20 }}>
                {[
                  { label: 'Operaciones', val: data.totales.cantidad,          color: 'var(--blue-600)' },
                  { label: 'Entradas',    val: $ar(data.totales.entradas || 0), color: 'var(--green-600)' },
                  { label: 'Salidas',     val: $ar(data.totales.salidas || 0),  color: 'var(--red-500)' },
                  { label: 'Neto',        val: $ar(data.totales.neto || 0),     color: 'var(--gray-700)' },
                ].map(k => (
                  <div key={k.label} className="card" style={{ padding: '12px 16px' }}>
                    <div className="kpi-label">{k.label}</div>
                    <div className="kpi-value" style={{ color: k.color, fontSize: 17, margin: '5px 0 0' }}>{k.val}</div>
                  </div>
                ))}
              </div>
              <div className="tbl-wrap">
                <table>
                  <thead><tr>
                    <th>Código</th><th>Operación</th><th className="th-right">Cantidad</th>
                    <th className="th-right">Entradas</th><th className="th-right">Salidas</th><th className="th-right">Neto</th>
                  </tr></thead>
                  <tbody>
                    {data.operaciones.length === 0
                      ? <tr><td colSpan={6} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin movimientos en el período</td></tr>
                      : data.operaciones.map((o, i) => (
                        <tr key={i}>
                          <td><span className="code">{o.codigo}</span></td>
                          <td className="td-bold">{o.descripcion}</td>
                          <td className="td-right">{o.cantidad}</td>
                          <td className="td-right" style={{ color: 'var(--green-600)' }}>{$ar(o.entradas || 0)}</td>
                          <td className="td-right" style={{ color: 'var(--red-500)' }}>{$ar(o.salidas || 0)}</td>
                          <td className="td-right td-bold">{$ar(o.neto || 0)}</td>
                        </tr>
                      ))
                    }
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {/* CHEQUES (terceros + propios) */}
          {tab === 'cheques_tes' && data.cheques && (
            <div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 14, marginBottom: 20 }}>
                {[
                  { label: 'Cheques',     val: data.totales.cantidad,           color: 'var(--blue-600)' },
                  { label: 'Monto total', val: $ar(data.totales.monto || 0),    color: 'var(--gray-700)' },
                  { label: 'Terceros',    val: $ar(data.totales.terceros || 0), color: 'var(--green-600)' },
                  { label: 'Propios',     val: $ar(data.totales.propios || 0),  color: 'var(--red-500)' },
                ].map(k => (
                  <div key={k.label} className="card" style={{ padding: '12px 16px' }}>
                    <div className="kpi-label">{k.label}</div>
                    <div className="kpi-value" style={{ color: k.color, fontSize: 17, margin: '5px 0 0' }}>{k.val}</div>
                  </div>
                ))}
              </div>
              <div className="tbl-wrap">
                <table>
                  <thead><tr>
                    <th>Origen</th><th>Número</th><th>Banco</th><th>Tipo</th><th>Entidad</th>
                    <th>Emisión</th><th>Vencimiento</th><th>Estado</th><th className="th-right">Monto</th>
                  </tr></thead>
                  <tbody>
                    {data.cheques.length === 0
                      ? <tr><td colSpan={9} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin cheques</td></tr>
                      : data.cheques.map(c => (
                        <tr key={`${c.origen}-${c.id}`}>
                          <td><span style={{ background: c.origen === 'propio' ? 'var(--amber-100)' : 'var(--blue-100)', color: c.origen === 'propio' ? 'var(--amber-600)' : 'var(--blue-600)', padding: '2px 8px', borderRadius: 8, fontSize: 11, fontWeight: 700 }}>{c.origen}</span></td>
                          <td><span className="code">{c.numero}</span></td>
                          <td style={{ fontSize: 12 }}>{c.banco || '—'}</td>
                          <td style={{ fontSize: 12 }}>{c.tipo}</td>
                          <td style={{ fontSize: 12 }}>{c.entidad || '—'}</td>
                          <td style={{ fontSize: 12 }}>{fFecha(c.fecha_emision)}</td>
                          <td style={{ fontSize: 12 }}>{fFecha(c.fecha_venc)}</td>
                          <td style={{ fontSize: 12 }}>{c.estado}</td>
                          <td className="td-right td-bold">{$ar(c.monto || 0)}</td>
                        </tr>
                      ))
                    }
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {/* COMPROBANTES TESORERÍA */}
          {tab === 'comprob_tes' && data.movimientos && (
            <div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 14, marginBottom: 20 }}>
                {[
                  { label: 'Comprobantes', val: data.totales.cantidad,           color: 'var(--blue-600)' },
                  { label: 'Entradas',     val: $ar(data.totales.entradas || 0), color: 'var(--green-600)' },
                  { label: 'Salidas',      val: $ar(data.totales.salidas || 0),  color: 'var(--red-500)' },
                  { label: 'Neto',         val: $ar(data.totales.neto || 0),     color: 'var(--gray-700)' },
                ].map(k => (
                  <div key={k.label} className="card" style={{ padding: '12px 16px' }}>
                    <div className="kpi-label">{k.label}</div>
                    <div className="kpi-value" style={{ color: k.color, fontSize: 17, margin: '5px 0 0' }}>{k.val}</div>
                  </div>
                ))}
              </div>
              <div className="tbl-wrap">
                <table>
                  <thead><tr>
                    <th>Fecha</th><th>N°</th><th>Cuenta</th><th>Tipo</th><th>Concepto</th>
                    <th>Origen</th><th className="th-right">Importe</th>
                  </tr></thead>
                  <tbody>
                    {data.movimientos.length === 0
                      ? <tr><td colSpan={7} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin comprobantes en el período</td></tr>
                      : data.movimientos.map(m => (
                        <tr key={m.id} style={{ opacity: m.anulado ? 0.4 : 1 }}>
                          <td>{fFecha(m.fecha)}</td>
                          <td>{m.numero ? <span className="code">{m.numero}</span> : '—'}</td>
                          <td style={{ fontSize: 12 }}>{m.cuenta}</td>
                          <td style={{ fontSize: 12 }}><span className="code">{m.tipo_codigo}</span></td>
                          <td style={{ fontSize: 12 }}>{m.concepto || '—'}{m.anulado && <span style={{ color: 'var(--red-500)', marginLeft: 6 }}>(anulado)</span>}</td>
                          <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{m.origen}</td>
                          <td className="td-right td-bold" style={{ color: m.signo === 1 ? 'var(--green-600)' : 'var(--red-500)' }}>{$ar(m.monto_con_signo || 0)}</td>
                        </tr>
                      ))
                    }
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {/* HISTÓRICO (listado plano de movimientos) */}
          {tab === 'historico_tes' && Array.isArray(data) && (
            <div className="tbl-wrap">
              <table>
                <thead><tr>
                  <th>Fecha</th><th>N°</th><th>Cuenta</th><th>Tipo</th><th>Concepto</th>
                  <th>Origen</th><th className="th-right">Importe</th><th>Concil.</th>
                </tr></thead>
                <tbody>
                  {data.length === 0
                    ? <tr><td colSpan={8} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin movimientos en el período</td></tr>
                    : data.map(m => (
                      <tr key={m.id} style={{ opacity: m.anulado ? 0.4 : 1 }}>
                        <td>{fFecha(m.fecha)}</td>
                        <td>{m.numero ? <span className="code">{m.numero}</span> : '—'}</td>
                        <td style={{ fontSize: 12 }}>{m.cuenta_descripcion}</td>
                        <td style={{ fontSize: 12 }}><span className="code">{m.tipo_codigo}</span></td>
                        <td style={{ fontSize: 12 }}>{m.concepto || '—'}{m.anulado && <span style={{ color: 'var(--red-500)', marginLeft: 6 }}>(anulado)</span>}</td>
                        <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{m.origen}</td>
                        <td className="td-right td-bold" style={{ color: m.signo === 1 ? 'var(--green-600)' : 'var(--red-500)' }}>{$ar(m.monto_con_signo || 0)}</td>
                        <td>{m.conciliado ? '✓' : ''}</td>
                      </tr>
                    ))
                  }
                </tbody>
              </table>
            </div>
          )}

          {/* ═══════════════ CONTABILIDAD (Fase E) ═══════════════ */}

          {/* LIBRO DIARIO — asientos cronológicos con sus líneas */}
          {tab === 'libro_diario' && data.asientos && (
            <div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 14, marginBottom: 20 }}>
                {[
                  { label: 'Asientos',    val: data.totales?.cantidad ?? 0,     color: 'var(--gray-700)' },
                  { label: 'Total debe',  val: $ar(data.totales?.debe  || 0),   color: 'var(--blue-600)' },
                  { label: 'Total haber', val: $ar(data.totales?.haber || 0),   color: 'var(--green-600)' },
                ].map(k => (
                  <div key={k.label} className="card" style={{ padding: '12px 16px' }}>
                    <div className="kpi-label">{k.label}</div>
                    <div className="kpi-value" style={{ color: k.color, fontSize: 17, margin: '5px 0 0' }}>{k.val}</div>
                  </div>
                ))}
              </div>
              {data.asientos.length === 0
                ? <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin asientos confirmados en el período</div>
                : data.asientos.map(a => (
                  <div className="card" key={a.id} style={{ marginBottom: 14 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 10, fontSize: 13 }}>
                      <span><span className="code" style={{ fontWeight: 700 }}>{a.numero}</span> · {fFecha(a.fecha)} · <strong>{a.descripcion}</strong></span>
                      <span style={{ color: 'var(--gray-500)' }}>{a.origen}</span>
                    </div>
                    <div className="tbl-wrap" style={{ boxShadow: 'none', border: 'none' }}>
                      <table>
                        <thead><tr>
                          <th style={{ width: 160 }}>Cuenta</th><th>Descripción</th><th>Detalle</th>
                          <th className="th-right" style={{ width: 130 }}>Debe</th>
                          <th className="th-right" style={{ width: 130 }}>Haber</th>
                        </tr></thead>
                        <tbody>
                          {(a.lineas || []).map((l, i) => (
                            <tr key={i}>
                              <td><span className="code">{l.codigo}</span></td>
                              <td>{l.cuenta}</td>
                              <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{l.detalle || '—'}</td>
                              <td className="td-right">{Number(l.debe)  > 0 ? $ar(l.debe)  : ''}</td>
                              <td className="td-right">{Number(l.haber) > 0 ? $ar(l.haber) : ''}</td>
                            </tr>
                          ))}
                          <tr>
                            <td colSpan={3} className="td-bold" style={{ textAlign: 'right' }}>Totales</td>
                            <td className="td-right td-bold">{$ar(a.total_debe  || 0)}</td>
                            <td className="td-right td-bold">{$ar(a.total_haber || 0)}</td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  </div>
                ))
              }
            </div>
          )}

          {/* LIBRO MAYOR — una cuenta, con saldo corrido */}
          {tab === 'libro_mayor' && data.movimientos && (
            <div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 14, marginBottom: 20 }}>
                {[
                  { label: 'Cuenta',        val: `${data.cuenta?.codigo || ''} ${data.cuenta?.descripcion || '—'}`, color: 'var(--gray-700)' },
                  { label: 'Saldo inicial', val: $ar(data.saldo_inicial || 0),          color: 'var(--gray-600)' },
                  { label: 'Saldo final',   val: $ar(data.totales?.saldo_final || 0),   color: 'var(--blue-600)' },
                ].map(k => (
                  <div key={k.label} className="card" style={{ padding: '12px 16px' }}>
                    <div className="kpi-label">{k.label}</div>
                    <div className="kpi-value" style={{ color: k.color, fontSize: 17, margin: '5px 0 0' }}>{k.val}</div>
                  </div>
                ))}
              </div>
              <div className="tbl-wrap">
                <table>
                  <thead><tr>
                    <th style={{ width: 110 }}>Fecha</th><th style={{ width: 90 }}>Asiento</th>
                    <th>Descripción</th><th>Detalle</th>
                    <th className="th-right" style={{ width: 120 }}>Debe</th>
                    <th className="th-right" style={{ width: 120 }}>Haber</th>
                    <th className="th-right" style={{ width: 130 }}>Saldo</th>
                  </tr></thead>
                  <tbody>
                    {data.movimientos.length === 0
                      ? <tr><td colSpan={7} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin movimientos en el período</td></tr>
                      : data.movimientos.map(m => (
                        <tr key={m.item_id}>
                          <td>{fFecha(m.fecha)}</td>
                          <td><span className="code">{m.numero}</span></td>
                          <td style={{ fontSize: 12 }}>{m.descripcion}</td>
                          <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{m.detalle || '—'}</td>
                          <td className="td-right">{Number(m.debe)  > 0 ? $ar(m.debe)  : ''}</td>
                          <td className="td-right">{Number(m.haber) > 0 ? $ar(m.haber) : ''}</td>
                          <td className="td-right td-bold">{$ar(m.saldo || 0)}</td>
                        </tr>
                      ))
                    }
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {/* SUMAS Y SALDOS — balance de comprobación */}
          {tab === 'sumas_saldos' && data.cuentas && (
            <div className="tbl-wrap">
              <table>
                <thead><tr>
                  <th style={{ width: 160 }}>Código</th><th>Cuenta</th><th style={{ width: 110 }}>Tipo</th>
                  <th className="th-right" style={{ width: 130 }}>Saldo inicial</th>
                  <th className="th-right" style={{ width: 130 }}>Debe</th>
                  <th className="th-right" style={{ width: 130 }}>Haber</th>
                  <th className="th-right" style={{ width: 130 }}>Saldo final</th>
                </tr></thead>
                <tbody>
                  {data.cuentas.length === 0
                    ? <tr><td colSpan={7} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin movimientos contables en el período</td></tr>
                    : <>
                        {data.cuentas.map(c => (
                          <tr key={c.id}>
                            <td><span className="code">{c.codigo}</span></td>
                            <td className="td-bold">{c.descripcion}</td>
                            <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{c.tipo_cuenta}</td>
                            <td className="td-right">{$ar(c.saldo_inicial || 0)}</td>
                            <td className="td-right">{$ar(c.debe  || 0)}</td>
                            <td className="td-right">{$ar(c.haber || 0)}</td>
                            <td className="td-right td-bold">{$ar(c.saldo_final || 0)}</td>
                          </tr>
                        ))}
                        <tr>
                          <td colSpan={4} className="td-bold" style={{ textAlign: 'right' }}>Totales</td>
                          <td className="td-right td-bold">{$ar(data.totales?.debe  || 0)}</td>
                          <td className="td-right td-bold">{$ar(data.totales?.haber || 0)}</td>
                          <td className="td-right td-bold">{$ar(data.totales?.saldo_final || 0)}</td>
                        </tr>
                      </>
                  }
                </tbody>
              </table>
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
