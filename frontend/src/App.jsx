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
        <Route path="*"             element={<Navigate to="/" replace />} />
      </Routes>
    </Layout>
  )
}
