import { createContext, useCallback, useContext, useEffect, useState } from 'react'
import { AlmanaqueAPI } from '../api'
import { hoy } from '../utils'

const AlmanaqueContext = createContext(null)

export function AlmanaqueProvider({ children }) {
  const [fechaAbierta, setFechaAbierta] = useState(null)
  const [pendientes, setPendientes] = useState(null)
  const [revision, setRevision] = useState(0)
  const [fechaHoy, setFechaHoy] = useState(hoy)
  const refrescar = useCallback(() => setRevision(r => r + 1), [])
  const abrir = useCallback((fecha = hoy()) => setFechaAbierta(fecha), [])
  const cerrar = useCallback(() => setFechaAbierta(null), [])

  useEffect(() => {
    const actualizar = () => {
      setFechaHoy(hoy())
      refrescar()
    }
    // Mantiene la fecha al cruzar medianoche y sincroniza al volver a la pestaña.
    const timer = setInterval(() => setFechaHoy(hoy()), 30_000)
    const alVolver = () => { if (!document.hidden) actualizar() }
    window.addEventListener('focus', actualizar)
    document.addEventListener('visibilitychange', alVolver)
    return () => {
      clearInterval(timer)
      window.removeEventListener('focus', actualizar)
      document.removeEventListener('visibilitychange', alVolver)
    }
  }, [refrescar])

  useEffect(() => {
    let activo = true
    AlmanaqueAPI.pendientes(fechaHoy).then(n => { if (activo) setPendientes(n) })
      .catch(() => { if (activo) setPendientes(null) })
    return () => { activo = false }
  }, [fechaHoy, revision])

  return (
    <AlmanaqueContext.Provider value={{ fechaAbierta, fechaHoy, pendientes, revision, abrir, cerrar, refrescar }}>
      {children}
    </AlmanaqueContext.Provider>
  )
}

export function useAlmanaque() {
  const context = useContext(AlmanaqueContext)
  if (!context) throw new Error('useAlmanaque debe usarse dentro de AlmanaqueProvider')
  return context
}

// Panel y Dashboard consultan sus rangos por separado y se actualizan con la misma revisión.
export function useAnotaciones(desde, hasta) {
  const { fechaHoy, revision, refrescar } = useAlmanaque()
  const [datos, setDatos] = useState({ notas: [], atrasadas: [], loading: true, error: false, rango: null })
  useEffect(() => {
    let activo = true
    const rango = `${desde}/${hasta}`
    // Refrescar el mismo rango conserva las filas y el editor que esté a medio cargar.
    setDatos(d => ({ ...d, loading: d.rango !== rango, error: false, rango }))
    Promise.all([AlmanaqueAPI.list({ desde, hasta }), AlmanaqueAPI.atrasadas(fechaHoy)])
      .then(([notas, atrasadas]) => {
        if (activo) setDatos({ notas, atrasadas, loading: false, error: false, rango })
      })
      .catch(() => { if (activo) setDatos(d => ({ ...d, loading: false, error: true })) })
    return () => { activo = false }
  }, [desde, hasta, fechaHoy, revision])
  return { ...datos, reintentar: refrescar }
}
