// src/hooks/useEscape.js
// ESC cierra el modal de arriba de todo (M10): cancelar un comprobante o formulario a medio cargar
// equivale a tocar "Cancelar" / "×". Con modales apilados (p. ej. el PDF abierto sobre una factura)
// cierra sólo el último que se abrió — por eso es una pila compartida y no un listener por modal.
// Si otro control ya usó la tecla (ClienteSearch cierra su lista con ESC y hace preventDefault),
// no se cierra el modal: el primer ESC cierra la lista, el segundo el formulario.
import { useEffect, useRef } from 'react'

const pila = []

function onKeyDown(e) {
  if (e.key !== 'Escape' || e.defaultPrevented || !pila.length) return
  e.preventDefault()
  pila[pila.length - 1].current?.()
}

export function useEscape(onClose) {
  // El ref deja que la pila llame siempre al onClose del último render sin re-registrarse en
  // cada render (lo que movería el modal al tope de la pila).
  const ref = useRef(onClose)
  ref.current = onClose

  useEffect(() => {
    if (!pila.length) document.addEventListener('keydown', onKeyDown)
    pila.push(ref)
    return () => {
      pila.splice(pila.indexOf(ref), 1)
      if (!pila.length) document.removeEventListener('keydown', onKeyDown)
    }
  }, [])
}
