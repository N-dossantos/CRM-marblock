// src/views/ComprasCtaCte/index.jsx
// Cuenta corriente de PROVEEDORES (Fase A). Espeja views/CtaCte contra informe_cta_cte_proveedor
// ("composición de saldos" en vivo: facturas debe, NC/pagos/retenciones haber, ND debe).
// Saldo > 0 = le debemos al proveedor. Sin PDF por ahora (no hay Edge Function de compras).
import { useState, useEffect } from 'react'
import { InformesAPI, ProveedoresAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Loading } from '../../components/UI'
import { exportarCtaCte } from '../../utils/excel'

const TIPO_STYLE = {
  FACTURA:       { bg: 'var(--amber-100)', color: 'var(--amber-700)', label: 'Factura' },
  PAGO:          { bg: 'var(--green-100)', color: 'var(--green-700)', label: 'Pago' },
  'NOTA CRED.':  { bg: 'var(--indigo-100)', color: 'var(--indigo-700)', label: 'NC' },
  'NOTA DEB.':   { bg: 'var(--pink-100)', color: 'var(--pink-700)', label: 'ND' },
  'RETENCIÓN':   { bg: 'var(--gray-100)', color: 'var(--gray-700)', label: 'Retención' },
  'SALDO ANTERIOR': { bg: 'var(--gray-100)', color: 'var(--gray-700)', label: 'Saldo anterior' },
}

export default function ComprasCtaCte() {
  const [proveedores, setProveedores] = useState([])
  const [selProv, setSelProv]   = useState('')
  const [data, setData]         = useState(null)
  const [loading, setLoading]   = useState(false)
  const [search, setSearch]     = useState('')
  const [desde, setDesde]       = useState('')
  const [hasta, setHasta]       = useState('')

  useEffect(() => { ProveedoresAPI.list().then(setProveedores) }, [])

  // `fechas` permite consultar con otras fechas que las del estado ("Limpiar" las vacía y consulta
  // en el mismo click: el estado nuevo recién se ve en el próximo render).
  const cargar = (fechas = { desde, hasta }) => {
    if (!selProv) return
    setLoading(true)
    const params = {}
    if (fechas.desde) params.desde = fechas.desde
    if (fechas.hasta) params.hasta = fechas.hasta
    InformesAPI.ctaCteProveedor(selProv, params).then(setData).finally(() => setLoading(false))
  }

  useEffect(() => { if (selProv) cargar() }, [selProv])

  const provsFiltrados = proveedores.filter(p =>
    !search || p.razon_social.toLowerCase().includes(search.toLowerCase()) || (p.cuit || '').includes(search)
  )

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '270px 1fr', gap: 18, height: 'calc(100vh - 54px - 48px)', overflow: 'hidden' }}>
      {/* Panel izquierdo: proveedores */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 0, overflow: 'hidden' }}>
        <div className="card" style={{ padding: '14px', marginBottom: 0, borderBottom: 'none', borderBottomLeftRadius: 0, borderBottomRightRadius: 0 }}>
          <input className="search-inp" style={{ width: '100%' }} placeholder="Buscar proveedor…" value={search} onChange={e => setSearch(e.target.value)} />
        </div>
        <div style={{ flex: 1, overflowY: 'auto', background: 'var(--surface)', border: '1px solid var(--gray-200)', borderTopLeftRadius: 0, borderTopRightRadius: 0, borderRadius: '0 0 12px 12px' }}>
          {provsFiltrados.map(p => {
            const saldo = data?.proveedor?.id === p.id ? data.saldo_total : null
            return (
              <div
                key={p.id}
                onClick={() => setSelProv(p.id)}
                style={{
                  padding: '10px 14px', cursor: 'pointer', borderBottom: '1px solid var(--gray-100)',
                  background: selProv === p.id ? 'var(--blue-50)' : 'transparent',
                  borderLeft: selProv === p.id ? '3px solid var(--blue-600)' : '3px solid transparent',
                  transition: 'background .12s',
                }}
              >
                <div style={{ fontWeight: selProv === p.id ? 700 : 500, fontSize: 13, color: 'var(--gray-800)' }}>
                  {p.razon_social.length > 28 ? p.razon_social.slice(0, 28) + '…' : p.razon_social}
                </div>
                {saldo !== null && (
                  <div style={{ fontSize: 12, fontWeight: 700, color: saldo > 0 ? 'var(--red-500)' : saldo < 0 ? 'var(--green-600)' : 'var(--gray-400)', marginTop: 2 }}>
                    {$ar(saldo)} {saldo > 0 ? '▲ Le debemos' : saldo < 0 ? '▼ A favor' : '✓ Sin saldo'}
                  </div>
                )}
                {saldo === null && <div style={{ fontSize: 11, color: 'var(--gray-400)', marginTop: 2 }}>{p.cuit}</div>}
              </div>
            )
          })}
        </div>
      </div>

      {/* Panel derecho: movimientos */}
      <div style={{ overflowY: 'auto' }}>
        {!selProv ? (
          <div className="card" style={{ textAlign: 'center', padding: '60px 20px' }}>
            <div style={{ fontSize: 40, marginBottom: 12 }}>📒</div>
            <p style={{ color: 'var(--gray-400)', fontSize: 14 }}>Seleccione un proveedor para ver su cuenta corriente</p>
          </div>
        ) : loading ? (
          <Loading />
        ) : data ? (
          <div>
            <div className="card" style={{ marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <h2 style={{ fontSize: 17, fontWeight: 700, color: 'var(--gray-800)' }}>{data.proveedor.razon_social}</h2>
                  <div style={{ fontSize: 13, color: 'var(--gray-500)', marginTop: 4 }}>
                    CUIT: {data.proveedor.cuit} &nbsp;·&nbsp; {data.proveedor.condicion_iva}
                    {data.proveedor.email && ` · ${data.proveedor.email}`}
                  </div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px', marginBottom: 4 }}>{data.hasta ? `Saldo al ${fFecha(data.hasta)}` : 'Saldo actual'}</div>
                  <div style={{ fontSize: 28, fontWeight: 800, color: data.saldo_total > 0 ? 'var(--red-500)' : data.saldo_total < 0 ? 'var(--green-600)' : 'var(--gray-400)', lineHeight: 1 }}>
                    {$ar(data.saldo_total)}
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 4 }}>
                    {data.saldo_total > 0 ? '⬆ Le debemos' : data.saldo_total < 0 ? '⬇ Saldo a favor' : '✓ Cuenta balanceada'}
                  </div>
                  <button
                    className="btn btn-secondary btn-sm"
                    style={{ marginTop: 10, background: 'var(--green-50)', color: 'var(--green-700)', borderColor: 'var(--green-100)' }}
                    onClick={() => exportarCtaCte(data, data.proveedor, 'Proveedor')}
                  >
                    📊 Excel
                  </button>
                </div>
              </div>

              <div style={{ display: 'flex', gap: 10, marginTop: 14, paddingTop: 14, borderTop: '1px solid var(--gray-100)', alignItems: 'center' }}>
                <span style={{ fontSize: 12, color: 'var(--gray-500)', fontWeight: 600 }}>Filtrar por período:</span>
                <input type="date" className="inp" style={{ width: 150 }} value={desde} onChange={e => setDesde(e.target.value)} />
                <span style={{ color: 'var(--gray-400)' }}>al</span>
                <input type="date" className="inp" style={{ width: 150 }} value={hasta} onChange={e => setHasta(e.target.value)} />
                <button className="btn btn-secondary btn-sm" onClick={() => cargar()}>Aplicar</button>
                <button className="btn btn-ghost btn-sm" onClick={() => { setDesde(''); setHasta(''); cargar({}) }}>Limpiar</button>
              </div>
            </div>

            <div className="tbl-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Fecha</th><th>Comprobante</th><th>Tipo</th>
                    <th className="th-right">Debe ($)</th><th className="th-right">Haber ($)</th><th className="th-right">Saldo ($)</th>
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
                        <td><span style={{ background: ts.bg, color: ts.color, padding: '2px 9px', borderRadius: 10, fontSize: 11, fontWeight: 700 }}>{ts.label}</span></td>
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
    </div>
  )
}
