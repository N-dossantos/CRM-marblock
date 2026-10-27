// src/lib/pinCuenta2.jsx
// PIN de 6 dígitos que tapa Cuenta 2 en el menú y en sus páginas. Es una cortina contra miradas,
// NO seguridad: el hash viaja en el bundle (6 dígitos se prueban en segundos) y los datos siguen
// accesibles por la API para cualquier usuario autenticado (RLS "shared staff").
// VITE_CUENTA2_PIN_HASH = SHA-256 en hex de `${SAL}${pin}`. La sal sólo evita que un PIN común se
// descubra buscando su hash en internet.
import { createContext, useContext, useState } from 'react'

const SAL = 'crm-marblock-c2:'
const CLAVE = 'crm-cuenta2-desbloqueada'
const HASH = (import.meta.env.VITE_CUENTA2_PIN_HASH || '').trim().toLowerCase()

// Sin hash válido la sección queda cerrada, y el campo del PIN dice por qué.
const ERROR_CONFIG = !/^[0-9a-f]{64}$/.test(HASH) ? 'Falta configurar VITE_CUENTA2_PIN_HASH.'
  : !globalThis.crypto?.subtle ? 'El PIN necesita https o localhost.'
  : null

async function sha256(texto) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto))
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('')
}

// Se guarda el hash y no un "1": si cambia el PIN, las pestañas abiertas vuelven a pedirlo.
function leerDesbloqueo() {
  try { return !ERROR_CONFIG && sessionStorage.getItem(CLAVE) === HASH } catch { return false }
}

const PinCuenta2Context = createContext(null)

export function PinCuenta2Provider({ children }) {
  const [desbloqueada, setDesbloqueada] = useState(leerDesbloqueo)

  // Queda desbloqueada hasta cerrar la pestaña, tocar Bloquear o Salir.
  async function desbloquear(pin) {
    if (ERROR_CONFIG || (await sha256(SAL + pin)) !== HASH) return false
    try { sessionStorage.setItem(CLAVE, HASH) } catch {}
    setDesbloqueada(true)
    return true
  }

  function bloquear() {
    try { sessionStorage.removeItem(CLAVE) } catch {}
    setDesbloqueada(false)
  }

  return (
    <PinCuenta2Context.Provider value={{ desbloqueada, desbloquear, bloquear, errorConfig: ERROR_CONFIG }}>
      {children}
    </PinCuenta2Context.Provider>
  )
}

export function usePinCuenta2() {
  const context = useContext(PinCuenta2Context)
  if (!context) throw new Error('usePinCuenta2 debe usarse dentro de <PinCuenta2Provider>.')
  return context
}
