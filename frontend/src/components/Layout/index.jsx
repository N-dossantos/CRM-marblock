// src/components/Layout/index.jsx
import { useEffect, useState } from 'react'
import { NavLink, useLocation } from 'react-router-dom'
import toast from 'react-hot-toast'
import { fechaLarga } from '../../utils'
import { useAuth } from '../../lib/auth'
import ThemeToggle from '../UI/ThemeToggle'
import FontSizeControl from '../UI/FontSizeControl'
import { useArcaEstado, BannerAmbiente, IndicadorArca } from '../Arca'
import CalendarioPanel, { CalendarioBoton } from '../Calendario/Panel'
import { usePinCuenta2 } from '../../lib/pinCuenta2'
import { PinInput } from '../PinCuenta2'

const NAV = [
  { section: null,       items: [{ to: '/', icon: '📊', label: 'Inicio' }] },
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
    section: 'Configuracion',
    desplegable: true,
    pin: true,
    items: [
      { to: '/cuenta2/ventas',  icon: '🟠', label: 'Ventas' },
      { to: '/cuenta2/compras', icon: '🟠', label: 'Compras' },
      { to: '/cuenta2/cheques', icon: '🟠', label: 'Cheques' },
    ],
  },
]

const VIEW_TITLES = {
  '/':             'Inicio',
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
  '/cuenta2/ventas':  'Ventas',
  '/cuenta2/compras': 'Compras',
  '/cuenta2/cheques': 'Cartera de Cheques',
}

// Los grupos `desplegable` arrancan cerrados y se abren solos al entrar a una de sus páginas, para
// que el ítem activo quede siempre a la vista. Los `pin` muestran el campo del PIN en lugar de los
// ítems hasta desbloquearlos, y no se abren solos: la página bloqueada ya pide el PIN.
function NavGrupo({ group, id }) {
  const { pathname } = useLocation()
  const { desbloqueada, bloquear } = usePinCuenta2()
  const bloqueado = group.pin && !desbloqueada
  const contieneActiva = !bloqueado && group.items.some((item) => item.to === pathname)
  const [abierto, setAbierto] = useState(contieneActiva)

  useEffect(() => { if (contieneActiva) setAbierto(true) }, [contieneActiva])

  const items = group.items.map((item) => (
    <NavLink
      key={item.to}
      to={item.to}
      end={item.to === '/'}
      className={({ isActive }) => `nav-item${isActive ? ' active' : ''}`}
    >
      <span className="nav-icon">{item.icon}</span>
      <span>{item.label}</span>
    </NavLink>
  ))

  if (!group.desplegable) {
    return (
      <div>
        {group.section && <div className="sidebar-section-label">{group.section}</div>}
        {items}
      </div>
    )
  }

  return (
    <div>
      <button
        type="button"
        className="sidebar-section-label sidebar-section-toggle"
        aria-expanded={abierto}
        aria-controls={id}
        onClick={() => setAbierto((a) => !a)}
      >
        <span>{group.section}</span>
        <span className="sidebar-section-chevron" aria-hidden="true">▸</span>
      </button>
      <div id={id} hidden={!abierto}>
        {abierto && bloqueado && <PinInput className="sidebar-pin" autoFocus />}
        {!bloqueado && items}
        {group.pin && !bloqueado && (
          <button type="button" className="nav-item" onClick={() => { bloquear(); setAbierto(false) }}>
            <span className="nav-icon">🔒</span>
            <span>Bloquear</span>
          </button>
        )}
      </div>
    </div>
  )
}

export default function Layout({ children }) {
  const { pathname } = useLocation()
  const { user, signOut } = useAuth()
  const { bloquear } = usePinCuenta2()
  const title = VIEW_TITLES[pathname] || 'CRM Marblock'
  const arca = useArcaEstado()
  const [menuAbierto, setMenuAbierto] = useState(false)

  useEffect(() => { setMenuAbierto(false) }, [pathname])
  useEffect(() => {
    if (!menuAbierto) return
    const cerrar = (event) => { if (event.key === 'Escape') setMenuAbierto(false) }
    window.addEventListener('keydown', cerrar)
    return () => window.removeEventListener('keydown', cerrar)
  }, [menuAbierto])

  async function handleLogout() {
    bloquear()
    await signOut()
    toast.success('Sesión cerrada')
  }

  return (
    <div className="layout">
      {menuAbierto && <button type="button" className="sidebar-backdrop" aria-label="Cerrar menú" onClick={() => setMenuAbierto(false)} />}
      <aside id="main-navigation" className={`sidebar${menuAbierto ? ' sidebar-open' : ''}`}>
        <div className="sidebar-logo">
          <h1>⚡ CRM Marblock</h1>
          <p>Sistema de Gestión</p>
          <button type="button" className="sidebar-close" aria-label="Cerrar menú" onClick={() => setMenuAbierto(false)}>×</button>
        </div>

        <nav style={{ flex: 1, padding: '8px 0' }}>
          {NAV.map((group, gi) => (
            <NavGrupo key={gi} group={group} id={`nav-grupo-${gi}`} />
          ))}
        </nav>

        <FontSizeControl />
        {/* En el celular el header no tiene lugar para el usuario y Salir: van al pie del menú. */}
        <div className="sidebar-sesion">
          {user?.email && <span className="sidebar-sesion-email">{user.email}</span>}
          <button type="button" className="btn btn-secondary btn-sm" onClick={handleLogout}>Salir</button>
        </div>
        <div className="sidebar-footer">v1.0 — Módulo Ventas</div>
      </aside>

      <div className="main-area">
        <BannerAmbiente estado={arca} />
        <header className="topbar">
          <button type="button" className="btn btn-secondary mobile-menu-button" aria-label="Abrir menú" aria-expanded={menuAbierto} aria-controls="main-navigation" onClick={() => setMenuAbierto(true)}>☰</button>
          <span className="topbar-title">{title}</span>
          <div className="topbar-right">
            <IndicadorArca estado={arca} />
            <ThemeToggle />
            <CalendarioBoton />
            <span className="topbar-date">{fechaLarga()}</span>
            {user?.email && <span className="topbar-user">{user.email}</span>}
            <button type="button" className="btn btn-secondary btn-sm topbar-salir" onClick={handleLogout}>
              Salir
            </button>
          </div>
        </header>

        <main className="page-content">
          {children}
        </main>
      </div>
      <CalendarioPanel />
    </div>
  )
}
