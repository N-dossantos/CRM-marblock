// src/api/base.js
// Primitivas compartidas por los módulos de la capa de datos (index.js y cuenta2.js).
// Viven acá y no en index.js para que cuenta2.js no tenga que importar del módulo que
// exporta los *API de Cuenta 1.
import { supabase } from '../lib/supabase'
import toast from 'react-hot-toast'

// ── Manejo de errores ────────────────────────────────────────────
// Replica el interceptor global del viejo Axios: togglea un toast por error, salvo
// PRESUPUESTO_VENCIDO, que ComprobanteForm detecta por err.response.status === 422.
export function fail(error) {
  const raw = error?.message || 'Error de conexión'
  if (raw.includes('PRESUPUESTO_VENCIDO')) {
    const e = new Error('PRESUPUESTO_VENCIDO')
    e.response = { status: 422, data: { error: 'PRESUPUESTO_VENCIDO' } }
    return e // sin toast: lo maneja el formulario
  }
  toast.error(raw)
  return new Error(raw)
}

export const unwrap = ({ data, error }) => { if (error) throw fail(error); return data }
export const rpc    = (fn, args) => supabase.rpc(fn, args).then(unwrap)
export const one    = (rows) => (Array.isArray(rows) ? (rows[0] ?? null) : (rows ?? null))
