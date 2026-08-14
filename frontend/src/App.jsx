// src/App.jsx
import { Routes, Route, Navigate } from 'react-router-dom'
import Layout from './components/Layout'
import Login  from './views/Login'
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

export default function App() {
  const { session, loading } = useAuth()

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

  return (
    <Layout>
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

        <Route path="*"             element={<Navigate to="/" replace />} />
      </Routes>
    </Layout>
  )
}
