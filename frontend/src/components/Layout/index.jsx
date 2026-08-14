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
    section: 'Compras',
    items: [
      { to: '/compras/proveedores', icon: '🏭', label: 'Proveedores' },
      { to: '/compras/materiales',  icon: '🧱', label: 'Materiales' },
      { to: '/compras/remitos',     icon: '🚚', label: 'Remitos de compra' },
      { to: '/compras/facturas',    icon: '🧾', label: 'Facturas de compra' },
      { to: '/compras/notas',       icon: '📝', label: 'Notas C / D compra' },
      { to: '/compras/pagos',       icon: '💸', label: 'Pagos a proveedor' },
      { to: '/compras/cta-cte',     icon: '📕', label: 'Cta. Cte. Proveedores' },
    ],
  },
  {
    section: 'Tesorería',
    items: [
      { to: '/tesoreria/cuentas',         icon: '🏛️', label: 'Cuentas y Cajas' },
      { to: '/tesoreria/movimientos',     icon: '💱', label: 'Movimientos' },
      { to: '/tesoreria/cheques-propios', icon: '🖊️', label: 'Cheques Propios' },
      { to: '/tesoreria/conciliacion',    icon: '⚖️', label: 'Conciliación' },
    ],
  },
  {
    section: 'Contabilidad',
    items: [
      { to: '/contabilidad/plan-cuentas', icon: '📗', label: 'Plan de Cuentas' },
      { to: '/contabilidad/asientos',     icon: '📘', label: 'Asientos' },
    ],
  },
  {
    section: 'Consultas',
    items: [
      { to: '/consultas/cliente',   icon: '🔎', label: 'Ficha de Cliente' },
      { to: '/consultas/proveedor', icon: '🔍', label: 'Ficha de Proveedor' },
      { to: '/consultas/cuenta',    icon: '🏦', label: 'Ficha de Cuenta' },
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
  // Circuito informal, aislado del oficial (cuenta2.md). Bloque propio a propósito: que se
  // vea separado en la navegación refuerza que los saldos no se mezclan con Cuenta 1.
  {
    section: 'Cuenta 2',
    items: [
      { to: '/cuenta2/ventas',  icon: '🟠', label: 'Ventas C2' },
      { to: '/cuenta2/compras', icon: '🟠', label: 'Compras C2' },
      { to: '/cuenta2/cheques', icon: '🟠', label: 'Cheques C2' },
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
  '/compras/proveedores': 'Proveedores',
  '/compras/materiales':  'Materiales',
  '/compras/remitos':     'Remitos de Compra',
  '/compras/facturas':    'Facturas de Compra',
  '/compras/notas':       'Notas de Crédito / Débito de Compra',
  '/compras/pagos':       'Pagos a Proveedor',
  '/compras/cta-cte':     'Cuenta Corriente de Proveedores',
  '/consultas/cliente':   'Consulta Integral de Cliente',
  '/consultas/proveedor': 'Consulta Integral de Proveedor',
  '/consultas/cuenta':    'Consulta Integral de Cuenta',
  '/tesoreria/cuentas':         'Cuentas y Cajas',
  '/tesoreria/movimientos':     'Movimientos de Tesorería',
  '/tesoreria/cheques-propios': 'Cheques Propios',
  '/tesoreria/conciliacion':    'Conciliación Bancaria',
  '/contabilidad/plan-cuentas': 'Plan de Cuentas',
  '/contabilidad/asientos':     'Asientos Contables',
  '/cuenta2/ventas':  'Cuenta 2 — Ventas',
  '/cuenta2/compras': 'Cuenta 2 — Compras',
  '/cuenta2/cheques': 'Cuenta 2 — Cartera de Cheques',
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
