// src/components/Layout/index.jsx
import { NavLink, useLocation } from 'react-router-dom'
import toast from 'react-hot-toast'
import { fechaLarga } from '../../utils'
import { useAuth } from '../../lib/auth'

const NAV = [
  { section: null,       items: [{ to: '/', icon: '📊', label: 'Dashboard' }] },
  {
    section: 'Ventas',
    items: [
      { to: '/clientes',     icon: '👥', label: 'Clientes' },
      { to: '/productos',    icon: '📦', label: 'Lista de precios' },
      { to: '/presupuestos', icon: '📋', label: 'Presupuestos' },
      { to: '/remitos',      icon: '🚚', label: 'Remitos' },
      { to: '/facturas',     icon: '🧾', label: 'Facturas' },
      { to: '/notas',        icon: '📝', label: 'Notas C / D' },
      { to: '/recibos',      icon: '💵', label: 'Recibos / Cobros' },
    ],
  },
  {
    section: 'Financiero',
    items: [
      { to: '/cta-cte', icon: '📒', label: 'Cuenta Corriente' },
      { to: '/cheques',  icon: '🏦', label: 'Cartera Cheques' },
    ],
  },
  {
    section: 'Análisis',
    items: [
      { to: '/informes', icon: '📈', label: 'Informes' },
    ],
  },
]

const VIEW_TITLES = {
  '/':             'Dashboard',
  '/clientes':     'Clientes',
  '/productos':    'Lista de Precios',
  '/presupuestos': 'Presupuestos',
  '/remitos':      'Remitos',
  '/facturas':     'Facturas',
  '/notas':        'Notas de Crédito / Débito',
  '/recibos':      'Recibos de Cobro',
  '/cta-cte':      'Cuenta Corriente',
  '/cheques':      'Cartera de Cheques',
  '/informes':     'Informes',
}

export default function Layout({ children }) {
  const { pathname } = useLocation()
  const { user, signOut } = useAuth()
  const title = VIEW_TITLES[pathname] || 'CRM Pro'

  async function handleLogout() {
    await signOut()
    toast.success('Sesión cerrada')
  }

  return (
    <div className="layout">
      <aside className="sidebar">
        <div className="sidebar-logo">
          <h1>⚡ CRM Pro</h1>
          <p>Sistema de Gestión</p>
        </div>

        <nav style={{ flex: 1, padding: '8px 0' }}>
          {NAV.map((group, gi) => (
            <div key={gi}>
              {group.section && (
                <div className="sidebar-section-label">{group.section}</div>
              )}
              {group.items.map((item) => (
                <NavLink
                  key={item.to}
                  to={item.to}
                  end={item.to === '/'}
                  className={({ isActive }) => `nav-item${isActive ? ' active' : ''}`}
                >
                  <span className="nav-icon">{item.icon}</span>
                  <span>{item.label}</span>
                </NavLink>
              ))}
            </div>
          ))}
        </nav>

        <div className="sidebar-footer">v1.0 — Módulo Ventas</div>
      </aside>

      <div className="main-area">
        <header className="topbar">
          <span className="topbar-title">{title}</span>
          <div className="topbar-right">
            <span className="topbar-date">{fechaLarga()}</span>
            {user?.email && <span className="topbar-user">{user.email}</span>}
            <button type="button" className="btn btn-secondary btn-sm" onClick={handleLogout}>
              Salir
            </button>
          </div>
        </header>

        <main className="page-content">
          {children}
        </main>
      </div>
    </div>
  )
}
