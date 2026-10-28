// src/hooks/useNumeroRepetido.js
// Recibo o remito con el número de una hoja que ya se usó: se avisa mientras se escribe y el
// formulario no deja guardar, en vez de enterarse recién al final por el error de la base (que lo
// sigue frenando igual con el UNIQUE de `numero`).
//
//   const repetido = useNumeroRepetido(RecibosAPI.buscarNumero, '00001-00004302')
//   // null mientras no se sabe o está libre; { numero, fecha, razon_social } si ya existe.
import { useEffect, useState } from 'react'

export function useNumeroRepetido(buscar, numero, activo = true) {
  const [repetido, setRepetido] = useState(null)
  useEffect(() => {
    setRepetido(null)
    if (!activo || !/^\d{5}-\d{8}$/.test(numero || '')) return
    let vigente = true
    // Una consulta por número terminado de escribir, no por tecla.
    const t = setTimeout(() => {
      buscar(numero).then(r => { if (vigente) setRepetido(r || null) }).catch(() => {})
    }, 250)
    return () => { vigente = false; clearTimeout(t) }
  }, [buscar, numero, activo])
  return repetido
}
