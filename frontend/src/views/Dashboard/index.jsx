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

  const maxDeuda = top_deudores.length > 0
    ? Math.max(...top_deudores.map(d => Number(d.saldo_pendiente) || 0), 1)
    : 1

  const KPI_DEFS = [
    {
      kicker: 'COBRANZAS & CARTERA',
      label: 'Total a cobrar',
      val: $ar(kpis.total_por_cobrar),
      accent: 'var(--accent-emerald)',
      bgLight: '#ecfdf5',
      iconColor: '#059669',
      sub: 'Facturas pendientes de cobro',
      icon: (
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <rect x="2" y="4" width="20" height="16" rx="2" />
          <line x1="2" y1="10" x2="22" y2="10" />
        </svg>
      )
    },
    {
      kicker: 'PADRÓN DE CLIENTES',
      label: 'Clientes activos',
      val: kpis.total_clientes,
      accent: 'var(--accent-azure)',
      bgLight: '#eff6ff',
      iconColor: '#2563eb',
      sub: 'Cuentas comerciales registradas',
      icon: (
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
          <circle cx="9" cy="7" r="4" />
          <path d="M23 21v-2a4 4 0 0 0-3-3.87" />
          <path d="M16 3.13a4 4 0 0 1 0 7.75" />
        </svg>
      )
    },
    {
      kicker: 'LOGÍSTICA & DESPACHO',
      label: 'Remitos pendientes',
      val: kpis.remitos_pendientes,
      accent: 'var(--accent-amber)',
      bgLight: '#fffbeb',
      iconColor: '#d97706',
      sub: 'En tránsito sin facturar',
      icon: (
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <rect x="1" y="3" width="15" height="13" />
          <polygon points="16 8 20 8 23 11 23 16 16 16 16 8" />
          <circle cx="5.5" cy="18.5" r="2.5" />
          <circle cx="18.5" cy="18.5" r="2.5" />
        </svg>
      )
    },
    {
      kicker: 'COTIZACIONES & VENTAS',
      label: 'Presupuestos activos',
      val: kpis.presupuestos_activos,
      accent: 'var(--accent-violet)',
      bgLight: '#f5f3ff',
      iconColor: '#7c3aed',
      sub: 'Propuestas vigentes / en seguimiento',
      icon: (
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
          <polyline points="14 2 14 8 20 8" />
          <line x1="16" y1="13" x2="8" y2="13" />
          <line x1="16" y1="17" x2="8" y2="17" />
          <polyline points="10 9 9 9 8 9" />
        </svg>
      )
    },
  ]

  const QUICK_ACTIONS = [
    {
      title: 'Nueva Factura',
      sub: 'Factura oficial A / B',
      to: '/facturas',
      icon: (
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M4 2v20l2-1 2 1 2-1 2 1 2-1 2 1 2-1 2 1V2l-2 1-2-1-2 1-2-1-2 1-2-1-2 1Z" />
          <line x1="8" y1="8" x2="16" y2="8" />
          <line x1="8" y1="12" x2="16" y2="12" />
        </svg>
      )
    },
    {
      title: 'Nuevo Presupuesto',
      sub: 'Cotización comercial',
      to: '/presupuestos',
      icon: (
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
          <polyline points="14 2 14 8 20 8" />
          <line x1="12" y1="18" x2="12" y2="12" />
          <line x1="9" y1="15" x2="15" y2="15" />
        </svg>
      )
    },
    {
      title: 'Nuevo Remito',
      sub: 'Despacho de materiales',
      to: '/remitos',
      icon: (
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <rect x="1" y="3" width="15" height="13" />
          <polygon points="16 8 20 8 23 11 23 16 16 16 16 8" />
          <circle cx="5.5" cy="18.5" r="2.5" />
          <circle cx="18.5" cy="18.5" r="2.5" />
        </svg>
      )
    },
    {
      title: 'Nuevo Recibo',
      sub: 'Imputación de cobranza',
      to: '/recibos',
      icon: (
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <line x1="12" y1="1" x2="12" y2="23" />
          <path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
        </svg>
      )
    },
    {
      title: 'Cuenta Corriente',
      sub: 'Estados de deuda',
      to: '/cta-cte',
      icon: (
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
          <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
        </svg>
      )
    },
    {
      title: 'Informes de Venta',
      sub: 'Libros IVA y métricas',
      to: '/informes',
      icon: (
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <line x1="18" y1="20" x2="18" y2="10" />
          <line x1="12" y1="20" x2="12" y2="4" />
          <line x1="6" y1="20" x2="6" y2="14" />
        </svg>
      )
    },
  ]

  return (
    <div style={{ maxWidth: 1400, margin: '0 auto' }}>
      {/* Executive Header Banner */}
      <div className="dash-banner">
        <div>
          <div className="dash-title">Panel Ejecutivo de Operaciones</div>
          <div className="dash-subtitle">
            Métricas de facturación, cartera de cobranzas y logística en tiempo real — Marblock S.A.
          </div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <div className="dash-badge">
            <span className="dash-badge-dot"></span>
            <span>ERP Sincronizado</span>
          </div>
          <button
            type="button"
            className="btn btn-primary btn-sm"
            style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}
            onClick={() => nav('/facturas')}
          >
            <span>+ Nueva Factura</span>
          </button>
        </div>
      </div>

      {/* KPI Cards Grid (Executive Slate ERP Style) */}
      <div className="kpi-grid">
        {KPI_DEFS.map(k => (
          <div
            key={k.label}
            className="kpi-card"
            style={{ borderTopColor: k.accent }}
          >
            <div>
              <div className="kpi-header">
                <span className="kpi-label">{k.kicker}</span>
                <span
                  className="kpi-icon-badge"
                  style={{ background: k.bgLight, color: k.iconColor }}
                >
                  {k.icon}
                </span>
              </div>
              <div className="kpi-value">{k.val}</div>
            </div>
            <div className="kpi-sub">
              <span>{k.sub}</span>
            </div>
          </div>
        ))}
      </div>

      {/* Alerta Destacada: Cheques Vencidos */}
      {kpis.cheques_vencidos > 0 && (
        <div
          style={{
            background: '#fef2f2',
            border: '1px solid #fee2e2',
            borderLeft: '4px solid #ef4444',
            borderRadius: 8,
            padding: '14px 18px',
            marginBottom: 20,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: 14,
            boxShadow: 'var(--shadow-sm)'
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <span
              style={{
                width: 36,
                height: 36,
                borderRadius: '50%',
                background: '#fee2e2',
                color: '#dc2626',
                display: 'inline-flex',
                alignItems: 'center',
                justifyContent: 'center',
                flexShrink: 0
              }}
            >
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z" />
                <line x1="12" y1="9" x2="12" y2="13" />
                <line x1="12" y1="17" x2="12.01" y2="17" />
              </svg>
            </span>
            <div>
              <div style={{ fontWeight: 700, color: '#991b1b', fontSize: 13 }}>
                Atención: Cartera con cheques vencidos
              </div>
              <div style={{ color: '#b91c1c', fontSize: 12, marginTop: 2 }}>
                Hay <strong>{kpis.cheques_vencidos}</strong> cheque(s) en cartera con fecha de vencimiento expirada pendientes de gestión.
              </div>
            </div>
          </div>
          <button
            type="button"
            className="btn btn-danger btn-sm"
            onClick={() => nav('/cheques')}
          >
            Gestionar Cartera →
          </button>
        </div>
      )}

      {/* Main Split Content Grid */}
      <div className="dash-split-grid">
        {/* Últimas Facturas Emitidas */}
        <div className="card" style={{ padding: '18px 20px' }}>
          <div className="card-header-flex">
            <div className="card-header-title">
              <span>Últimas Facturas Emitidas</span>
              <span className="card-counter">{ultimas_facturas.length} recientes</span>
            </div>
            <button
              type="button"
              className="btn btn-ghost btn-sm"
              onClick={() => nav('/facturas')}
            >
              Ver todas →
            </button>
          </div>

          {ultimas_facturas.length === 0 ? (
            <div className="empty-state" style={{ padding: '36px 0' }}>
              <div className="icon">🧾</div>
              <p>No hay facturas registradas en el período</p>
            </div>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column' }}>
              {ultimas_facturas.map(f => {
                const initials = (f.razon_social || 'CL')
                  .split(' ')
                  .map(w => w[0])
                  .filter(Boolean)
                  .slice(0, 2)
                  .join('')
                  .toUpperCase()

                return (
                  <div
                    key={f.id}
                    className="factura-item"
                    onClick={() => nav('/facturas')}
                    title="Ver en módulo de facturas"
                  >
                    <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                      <div className="factura-avatar">{initials}</div>
                      <div>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                          <span className="code" style={{ fontWeight: 700 }}>{f.numero}</span>
                          <span className={`badge badge-${f.tipo}`}>Fac {f.tipo}</span>
                          {f.fecha && (
                            <span style={{ fontSize: 11, color: 'var(--gray-400)', marginLeft: 4 }}>
                              {fFecha(f.fecha)}
                            </span>
                          )}
                        </div>
                        <div style={{ fontSize: 13, color: 'var(--gray-700)', fontWeight: 500, marginTop: 3 }}>
                          {f.razon_social}
                        </div>
                      </div>
                    </div>
                    <div style={{ textAlign: 'right' }}>
                      <div className="factura-total">{$ar(f.total)}</div>
                      <div style={{ marginTop: 4 }}>
                        <Badge estado={f.estado} />
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>

        {/* Top Deudores */}
        <div className="card" style={{ padding: '18px 20px' }}>
          <div className="card-header-flex">
            <div className="card-header-title">
              <span>Top Deudores</span>
              <span className="card-counter">Concentración</span>
            </div>
            <button
              type="button"
              className="btn btn-ghost btn-sm"
              onClick={() => nav('/cta-cte')}
            >
              Cta. Cte. →
            </button>
          </div>

          {top_deudores.length === 0 ? (
            <div className="empty-state" style={{ padding: '36px 0' }}>
              <div className="icon">🎉</div>
              <p style={{ color: 'var(--green-700)', fontWeight: 600 }}>Sin saldos deudores pendientes</p>
            </div>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column' }}>
              {top_deudores.map((c, i) => {
                const ratio = Math.min(100, Math.round(((Number(c.saldo_pendiente) || 0) / maxDeuda) * 100))

                return (
                  <div key={c.id} className="deudor-item">
                    <div style={{ flex: 1, minWidth: 0, paddingRight: 14 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                        <span className={`deudor-rank ${i === 0 ? 'top-1' : ''}`}>
                          {i + 1}
                        </span>
                        <span
                          style={{
                            fontSize: 13,
                            fontWeight: 600,
                            color: 'var(--gray-800)',
                            whiteSpace: 'nowrap',
                            overflow: 'hidden',
                            textOverflow: 'ellipsis',
                            cursor: 'pointer'
                          }}
                          onClick={() => nav(`/consultas/cliente?id=${c.id}`)}
                          title={`Ver ficha integral de ${c.razon_social}`}
                        >
                          {c.razon_social}
                        </span>
                      </div>
                      <div className="deudor-bar-bg">
                        <div
                          className="deudor-bar-fill"
                          style={{
                            width: `${ratio}%`,
                            background: i === 0 ? '#ef4444' : '#f97316'
                          }}
                        />
                      </div>
                    </div>
                    <div style={{ textAlign: 'right', flexShrink: 0 }}>
                      <div style={{ fontWeight: 700, color: 'var(--red-600)', fontSize: 13, fontVariantNumeric: 'tabular-nums' }}>
                        {$ar(c.saldo_pendiente)}
                      </div>
                      <div style={{ fontSize: 10, color: 'var(--gray-400)', marginTop: 2 }}>
                        {ratio}% del líder
                      </div>
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>
      </div>

      {/* Cheques por vencer en los próximos 7 días */}
      {cheques_por_vencer && cheques_por_vencer.length > 0 && (
        <div className="card" style={{ marginBottom: 20, padding: '18px 20px' }}>
          <div className="card-header-flex">
            <div className="card-header-title">
              <span style={{ color: '#d97706' }}>
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ verticalAlign: 'middle', marginRight: 6 }}>
                  <rect x="3" y="4" width="18" height="18" rx="2" ry="2" />
                  <line x1="16" y1="2" x2="16" y2="6" />
                  <line x1="8" y1="2" x2="8" y2="6" />
                  <line x1="3" y1="10" x2="21" y2="10" />
                </svg>
              </span>
              <span>Cheques por Vencer en los Próximos 7 Días</span>
              <span className="card-counter">{cheques_por_vencer.length}</span>
            </div>
            <button
              type="button"
              className="btn btn-ghost btn-sm"
              onClick={() => nav('/cheques')}
            >
              Ver cartera →
            </button>
          </div>

          <div className="cheques-alert-grid">
            {cheques_por_vencer.map(ch => (
              <div key={ch.numero} className="cheque-chip">
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                  <span style={{ fontWeight: 700, fontSize: 15, color: '#92400e', fontVariantNumeric: 'tabular-nums' }}>
                    {$ar(ch.monto)}
                  </span>
                  <span className="badge badge-pendiente" style={{ fontSize: 10 }}>
                    Vence {fFecha(ch.fecha_vcto)}
                  </span>
                </div>
                <div style={{ fontWeight: 600, color: '#78350f', fontSize: 12, marginTop: 4 }}>
                  {ch.banco} <span style={{ opacity: 0.7 }}>#{ch.numero}</span>
                </div>
                {ch.cliente_razon_social && (
                  <div style={{ fontSize: 11, color: '#b45309', marginTop: 4, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                    👤 {ch.cliente_razon_social}
                  </div>
                )}
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Operaciones & Accesos Rápidos */}
      <div className="card" style={{ padding: '18px 20px' }}>
        <div className="card-header-flex">
          <div className="card-header-title">
            <span>Operaciones & Accesos Rápidos</span>
          </div>
        </div>

        <div className="quick-actions-grid">
          {QUICK_ACTIONS.map(a => (
            <div
              key={a.to}
              className="quick-action-btn"
              onClick={() => nav(a.to)}
            >
              <div className="quick-action-icon">{a.icon}</div>
              <div className="quick-action-title">{a.title}</div>
              <div className="quick-action-sub">{a.sub}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
