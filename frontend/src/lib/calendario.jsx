import { createContext, useCallback, useContext, useEffect, useState } from 'react'
import { CalendarioAPI } from '../api'
import { hoy } from '../utils'

const CalendarioContext = createContext(null)

export function CalendarioProvider({ children }) {
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
    CalendarioAPI.pendientes(fechaHoy).then(n => { if (activo) setPendientes(n) })
      .catch(() => { if (activo) setPendientes(null) })
    return () => { activo = false }
  }, [fechaHoy, revision])

  return (
    <CalendarioContext.Provider value={{ fechaAbierta, fechaHoy, pendientes, revision, abrir, cerrar, refrescar }}>
      {children}
    </CalendarioContext.Provider>
  )
}

export function useCalendario() {
  const context = useContext(CalendarioContext)
  if (!context) throw new Error('useCalendario debe usarse dentro de CalendarioProvider')
  return context
}

// Panel y Dashboard consultan sus rangos por separado y se actualizan con la misma revisión.
export function useEventos(desde, hasta) {
  const { fechaHoy, revision, refrescar } = useCalendario()
  const [datos, setDatos] = useState({ eventos: [], atrasados: [], loading: true, error: false, rango: null })
  useEffect(() => {
    let activo = true
    const rango = `${desde}/${hasta}`
    // Refrescar el mismo rango conserva las filas y el editor que esté a medio cargar.
    setDatos(d => ({ ...d, loading: d.rango !== rango, error: false, rango }))
    Promise.all([CalendarioAPI.list({ desde, hasta }), CalendarioAPI.atrasados(fechaHoy)])
      .then(([eventos, atrasados]) => {
        if (activo) setDatos({ eventos, atrasados, loading: false, error: false, rango })
      })
      .catch(() => { if (activo) setDatos(d => ({ ...d, loading: false, error: true })) })
    return () => { activo = false }
  }, [desde, hasta, fechaHoy, revision])
  return { ...datos, reintentar: refrescar }
}
