// src/App.jsx
import { useEffect } from 'react'
import { Routes, Route, Navigate, useLocation } from 'react-router-dom'
import Layout from './components/Layout'
import Login  from './views/Login'
import ErrorBoundary from './components/ErrorBoundary'
import { useAuth } from './lib/auth'

import Dashboard    from './views/Dashboard'
import Clientes     from './views/Clientes'
import Productos    from './views/Productos'
import Presupuestos from './views/Presupuestos'
import Remitos      from './views/Remitos'
import Facturas     from './views/Facturas'
import Notas        from './views/Notas'
import Recibos      from './views/Recibos'
import CtaCte       from './views/CtaCte'
import Cheques      from './views/Cheques'
import Informes     from './views/Informes'

// Compras (Fase A)
import ComprasProveedores from './views/ComprasProveedores'
import ComprasMateriales  from './views/ComprasMateriales'
import ComprasFacturas    from './views/ComprasFacturas'
import ComprasRemitos     from './views/ComprasRemitos'
import ComprasNotas       from './views/ComprasNotas'
import ComprasPagos       from './views/ComprasPagos'
import ComprasCtaCte      from './views/ComprasCtaCte'

// Consultas integrales 360° (Fase B / D)
import ConsultaCliente   from './views/ConsultaCliente'
import ConsultaProveedor from './views/ConsultaProveedor'
import ConsultaCuenta    from './views/ConsultaCuenta'

// Tesorería (Fase C)
import TesoreriaCuentas        from './views/TesoreriaCuentas'
import TesoreriaMovimientos    from './views/TesoreriaMovimientos'
import TesoreriaChequesPropios from './views/TesoreriaChequesPropios'
import TesoreriaConciliacion   from './views/TesoreriaConciliacion'

// Contabilidad (Fase E) — núcleo manual; la generación automática sigue bloqueada en la matriz
import ContabilidadPlanCuentas from './views/ContabilidadPlanCuentas'
import ContabilidadAsientos    from './views/ContabilidadAsientos'

// Cuenta 2 — circuito informal, aislado del oficial (cuenta2.md)
import Cuenta2        from './views/Cuenta2'
import Cuenta2Cheques from './views/Cuenta2Cheques'

export default function App() {
  const { session, loading } = useAuth()
  const location = useLocation()

  // Scrollear la página con el cursor encima de una cantidad o un precio cambiaba el valor sin que
  // el operador se diera cuenta: un input[type=number] enfocado se lleva la rueda del mouse. Un
  // listener global lo cubre en todo el sistema (los ~38 inputs numéricos y los modales incluidos).
  // Se hace blur en vez de preventDefault a propósito: preventDefault frenaría también el scroll de
  // la página, que en un modal largo es peor que el problema que arregla. Al perder el foco el input
  // deja de capturar la rueda y la página sigue scrolleando normal.
  useEffect(() => {
    const onWheel = (e) => {
      const el = e.target
      if (el instanceof HTMLInputElement && el.type === 'number' && el === document.activeElement) {
        el.blur()
      }
    }
    document.addEventListener('wheel', onWheel, { passive: true })
    return () => document.removeEventListener('wheel', onWheel)
  }, [])

  // Mientras se resuelve la sesión inicial (posible restore desde localStorage).
  if (loading) {
    return (
      <div className="login-screen">
        <div className="login-loading">Cargando…</div>
      </div>
    )
  }

  // Sin sesión → sólo la pantalla de acceso. anon no puede leer/escribir nada (RLS).
  if (!session) return <Login />

  // El boundary va DENTRO del Layout para que el menú sobreviva al error y se pueda salir de la
  // pantalla rota; `key` por ruta lo resetea al navegar, sin necesidad de recargar.
  return (
    <Layout>
      <ErrorBoundary key={location.pathname}>
      <Routes>
        <Route path="/"             element={<Dashboard />} />
        <Route path="/clientes"     element={<Clientes />} />
        <Route path="/productos"    element={<Productos />} />
        <Route path="/presupuestos" element={<Presupuestos />} />
        <Route path="/remitos"      element={<Remitos />} />
        <Route path="/facturas"     element={<Facturas />} />
        <Route path="/notas"        element={<Notas />} />
        <Route path="/recibos"      element={<Recibos />} />
        <Route path="/cta-cte"      element={<CtaCte />} />
        <Route path="/cheques"      element={<Cheques />} />
        <Route path="/informes"     element={<Informes />} />

        {/* Compras (Fase A) */}
        <Route path="/compras/proveedores" element={<ComprasProveedores />} />
        <Route path="/compras/materiales"  element={<ComprasMateriales />} />
        <Route path="/compras/facturas"    element={<ComprasFacturas />} />
        <Route path="/compras/remitos"     element={<ComprasRemitos />} />
        <Route path="/compras/notas"       element={<ComprasNotas />} />
        <Route path="/compras/pagos"       element={<ComprasPagos />} />
        <Route path="/compras/cta-cte"     element={<ComprasCtaCte />} />

        {/* Consultas integrales 360° (Fase B / D) */}
        <Route path="/consultas/cliente"   element={<ConsultaCliente />} />
        <Route path="/consultas/proveedor" element={<ConsultaProveedor />} />
        <Route path="/consultas/cuenta"    element={<ConsultaCuenta />} />

        {/* Tesorería (Fase C) */}
        <Route path="/tesoreria/cuentas"        element={<TesoreriaCuentas />} />
        <Route path="/tesoreria/movimientos"    element={<TesoreriaMovimientos />} />
        <Route path="/tesoreria/cheques-propios" element={<TesoreriaChequesPropios />} />
        <Route path="/tesoreria/conciliacion"   element={<TesoreriaConciliacion />} />

        {/* Contabilidad (Fase E) */}
        <Route path="/contabilidad/plan-cuentas" element={<ContabilidadPlanCuentas />} />
        <Route path="/contabilidad/asientos"     element={<ContabilidadAsientos />} />

        {/* Cuenta 2 — una sola vista para ambos sectores; `key` fuerza el remount al cambiar
            de ruta, si no React reusa la instancia y arrastra el estado del otro sector. */}
        <Route path="/cuenta2/ventas"  element={<Cuenta2 key="venta"  tipoSector="venta" />} />
        <Route path="/cuenta2/compras" element={<Cuenta2 key="compra" tipoSector="compra" />} />
        <Route path="/cuenta2/cheques" element={<Cuenta2Cheques />} />

        <Route path="*"             element={<Navigate to="/" replace />} />
      </Routes>
      </ErrorBoundary>
    </Layout>
  )
}
