// src/components/PinCuenta2/index.jsx
// Campo del PIN de Cuenta 2 y guarda de sus páginas (ver lib/pinCuenta2.jsx).
import { useState } from 'react'
import { usePinCuenta2 } from '../../lib/pinCuenta2'

// Se verifica solo al completar los 6 dígitos. No es un <form> ni un type="password" para que el
// navegador no ofrezca guardarlo como contraseña: los dígitos se tapan por CSS (.pin-input).
export function PinInput({ className = '', autoFocus }) {
  const { desbloquear, errorConfig } = usePinCuenta2()
  const [pin, setPin] = useState('')
  const [error, setError] = useState('')

  if (errorConfig) return <div className={`pin-error ${className}`}>{errorConfig}</div>

  async function handleChange(e) {
    const valor = e.target.value.replace(/\D/g, '').slice(0, 6)
    setPin(valor)
    setError('')
    if (valor.length < 6) return
    if (!(await desbloquear(valor))) {
      setPin('')
      setError('PIN incorrecto')
    }
  }

  return (
    <div className={className}>
      <input
        className="inp pin-input"
        type="text"
        inputMode="numeric"
        autoComplete="off"
        maxLength={6}
        value={pin}
        onChange={handleChange}
        autoFocus={autoFocus}
        placeholder="PIN"
        aria-label="PIN de 6 dígitos"
        aria-invalid={!!error}
      />
      {error && <div className="pin-error" role="alert">{error}</div>}
    </div>
  )
}

// Las rutas se pueden abrir escribiendo la dirección, así que el PIN se pide también acá y no sólo
// en el menú.
export function ConPinCuenta2({ children }) {
  const { desbloqueada } = usePinCuenta2()
  if (desbloqueada) return children

  return (
    <div className="card pin-card">
      <div className="pin-card-title">🔒 Sección protegida</div>
      <p className="form-hint">Ingresá el PIN de 6 dígitos para continuar.</p>
      <PinInput autoFocus />
    </div>
  )
}
