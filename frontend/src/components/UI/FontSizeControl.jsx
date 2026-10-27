import { useState } from 'react'

const OPCIONES = [
  { id: 'small', label: 'Chico' },
  { id: 'normal', label: 'Normal' },
  { id: 'large', label: 'Grande' },
]

export default function FontSizeControl() {
  const [size, setSize] = useState(() => document.documentElement.dataset.fontSize || 'normal')

  const elegir = (next) => {
    document.documentElement.dataset.fontSize = next
    setSize(next)
    try { localStorage.setItem('crm-font-size', next) } catch {}
  }

  return (
    <div className="font-size-control" role="group" aria-label="Tamaño de letra">
      <div className="font-size-control-label">Tamaño de letra</div>
      <div className="font-size-options">
        {OPCIONES.map(opcion => (
          <button key={opcion.id} type="button" className="font-size-option"
            aria-pressed={size === opcion.id} onClick={() => elegir(opcion.id)}>
            {opcion.label}
          </button>
        ))}
      </div>
    </div>
  )
}
