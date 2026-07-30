// src/views/Dashboard/index.jsx
import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { InformesAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Loading, Badge } from '../../components/UI'

export default function Dashboard() {
  const [data, setData]       = useState(null)
  const [loading, setLoading] = useState(true)
  const nav = useNavigate()

  useEffect(() => {
    InformesAPI.dashboard().then(setData).finally(() => setLoading(false))
  }, [])

  if (loading) return <Loading />
  if (!data)   return null

  const { kpis, ultimas_facturas, top_deudores, cheques_por_vencer } = data

  const KPI_DEFS = [
    { label: 'Clientes activos',   val: kpis.total_clientes,     icon: '👥', color: '#1d4ed8', sub: 'registrados' },
    { label: 'Total a cobrar',     val: $ar(kpis.total_por_cobrar), icon: '💰', color: '#10b981', sub: 'facturas pendientes' },
    { label: 'Remitos pendientes', val: kpis.remitos_pendientes,  icon: '🚚', color: '#f97316', sub: 'a facturar' },
    { label: 'Presupuestos activos',val: kpis.presupuestos_activos,icon: '📋', color: '#7c3aed', sub: 'vigentes' },
  ]

  return (
    <div>
      {/* KPIs */}
      <div className="kpi-grid">
        {KPI_DEFS.map(k => (
          <div key={k.label} className="kpi-card" style={{ borderLeftColor: k.color }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
              <div>
                <div className="kpi-label">{k.label}</div>
                <div className="kpi-value" style={{ color: k.color }}>{k.val}</div>
                <div className="kpi-sub">{k.sub}</div>
              </div>
              <span style={{ fontSize: 28 }}>{k.icon}</span>
            </div>
          </div>
        ))}
      </div>

      {/* Alertas */}
      {kpis.cheques_vencidos > 0 && (
        <div className="warn-box" style={{ marginBottom: 18 }}>
          <span>⚠️</span>
          <span>Hay <strong>{kpis.cheques_vencidos}</strong> cheque(s) vencido(s) en cartera.
            <button className="btn btn-ghost btn-sm" style={{ marginLeft: 8 }} onClick={() => nav('/cheques')}>Ver cheques</button>
          </span>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 16, marginBottom: 16 }}>
        {/* Últimas facturas */}
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 }}>
            <span style={{ fontWeight: 700, fontSize: 14 }}>Últimas Facturas</span>
            <button className="btn btn-ghost btn-sm" onClick={() => nav('/facturas')}>Ver todas →</button>
          </div>
          {ultimas_facturas.length === 0
            ? <p style={{ color: 'var(--gray-400)', fontSize: 13, textAlign: 'center', padding: '20px 0' }}>Sin facturas</p>
            : ultimas_facturas.map(f => (
              <div key={f.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '9px 0', borderBottom: '1px solid var(--gray-100)' }}>
                <div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <span className="code">{f.numero}</span>
                    <span className={`badge badge-${f.tipo}`}>Fac {f.tipo}</span>
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 2 }}>{f.razon_social}</div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <div style={{ fontWeight: 700 }}>{$ar(f.total)}</div>
                  <Badge estado={f.estado} />
                </div>
              </div>
            ))
          }
        </div>

        {/* Top deudores */}
        <div className="card">
          <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 14 }}>Top Deudores</div>
          {top_deudores.length === 0
            ? <p style={{ color: 'var(--gray-400)', fontSize: 13, textAlign: 'center', padding: '20px 0' }}>Sin deudas pendientes 🎉</p>
            : top_deudores.map((c, i) => (
              <div key={c.id} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '8px 0', borderBottom: '1px solid var(--gray-100)' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ width: 22, height: 22, borderRadius: '50%', background: 'var(--red-100)', color: 'var(--red-600)', fontSize: 11, fontWeight: 700, display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}>{i + 1}</span>
                  <span style={{ fontSize: 13, fontWeight: 500 }}>{c.razon_social.length > 28 ? c.razon_social.slice(0, 28) + '…' : c.razon_social}</span>
                </div>
                <span style={{ fontWeight: 700, color: 'var(--red-500)', fontSize: 13 }}>{$ar(c.saldo_pendiente)}</span>
              </div>
            ))
          }
        </div>
      </div>

      {/* Cheques por vencer */}
      {cheques_por_vencer.length > 0 && (
        <div className="card" style={{ marginBottom: 16 }}>
          <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 12 }}>⏰ Cheques que vencen esta semana</div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 10 }}>
            {cheques_por_vencer.map(ch => (
              <div key={ch.numero} style={{ background: 'var(--amber-50)', border: '1px solid var(--amber-100)', borderRadius: 8, padding: '10px 14px', fontSize: 13, minWidth: 200 }}>
                <div style={{ fontWeight: 700, color: '#92400e' }}>{$ar(ch.monto)}</div>
                <div style={{ fontSize: 12, color: '#a16207' }}>{ch.banco} — Vence: {fFecha(ch.fecha_vcto)}</div>
                {ch.cliente_razon_social && <div style={{ fontSize: 11, color: '#ca8a04', marginTop: 2 }}>{ch.cliente_razon_social}</div>}
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Acciones rápidas */}
      <div className="card">
        <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 14 }}>Acciones rápidas</div>
        <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
          {[
            ['🧾', 'Nueva Factura',      '/facturas'],
            ['📋', 'Nuevo Presupuesto',  '/presupuestos'],
            ['🚚', 'Nuevo Remito',       '/remitos'],
            ['💵', 'Nuevo Recibo',       '/recibos'],
            ['📒', 'Cuenta Corriente',   '/cta-cte'],
            ['📈', 'Ver Informes',       '/informes'],
          ].map(([icon, label, path]) => (
            <button
              key={path}
              onClick={() => nav(path)}
              style={{ padding: '11px 16px', background: 'var(--gray-50)', border: '1px solid var(--gray-200)', borderRadius: 8, cursor: 'pointer', display: 'inline-flex', alignItems: 'center', gap: 8, fontSize: 13, fontWeight: 600, color: 'var(--gray-800)', fontFamily: 'inherit', transition: 'background .15s' }}
              onMouseOver={e => e.currentTarget.style.background = 'var(--blue-50)'}
              onMouseOut={e => e.currentTarget.style.background = 'var(--gray-50)'}
            >
              <span style={{ fontSize: 18 }}>{icon}</span>{label}
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}
