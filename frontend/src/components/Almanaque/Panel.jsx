import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { addMonths, eachDayOfInterval, endOfMonth, endOfWeek, format, parseISO, startOfMonth, startOfWeek } from 'date-fns'
import { es } from 'date-fns/locale'
import { AlmanaqueAPI } from '../../api'
import { fechaLocal } from '../../utils'
import { useAlmanaque, useAnotaciones } from '../../lib/almanaque'
import { useEscape } from '../../hooks/useEscape'
import Anotacion, { CalendarioIcon, EstadoAnotaciones } from './Anotacion'
import './almanaque.css'

export function AlmanaqueBoton() {
  const { abrir, pendientes, fechaAbierta } = useAlmanaque()
  return <button type="button" className="btn btn-secondary btn-sm almanaque-boton" onClick={() => abrir()}
    aria-label={`Abrir almanaque${pendientes > 0 ? `, ${pendientes} pendientes` : ''}`}
    aria-haspopup="dialog" aria-expanded={!!fechaAbierta} title="Almanaque compartido">
    <CalendarioIcon /><span className="almanaque-boton-label">Almanaque</span>
    {pendientes > 0 && <span className="almanaque-contador" aria-hidden="true">{pendientes}</span>}
  </button>
}

export default function AlmanaquePanel() {
  const { fechaAbierta } = useAlmanaque()
  return fechaAbierta ? <PanelAbierto /> : null
}

function PanelAbierto() {
  const { fechaAbierta, fechaHoy, abrir, cerrar, refrescar } = useAlmanaque()
  const mes = startOfMonth(parseISO(fechaAbierta))
  const desde = fechaLocal(mes)
  const hasta = fechaLocal(endOfMonth(mes))
  const datos = useAnotaciones(desde, hasta)
  const [texto, setTexto] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const panel = useRef(null)
  const nueva = useRef(null)
  const dias = eachDayOfInterval({ start: startOfWeek(mes, { weekStartsOn: 1 }), end: endOfWeek(endOfMonth(mes), { weekStartsOn: 1 }) })
  const diasConNotas = new Set(datos.notas.map(n => n.fecha))
  const notasDia = datos.notas.filter(n => n.fecha === fechaAbierta)
  const atrasadas = datos.atrasadas.filter(n => n.fecha !== fechaAbierta)
  useEscape(cerrar)

  useEffect(() => {
    const anterior = document.activeElement
    const root = document.getElementById('root')
    const eraInerte = root.inert
    root.inert = true
    panel.current.querySelector('button')?.focus()
    return () => {
      root.inert = eraInerte
      if (anterior?.isConnected) anterior.focus()
    }
  }, [])

  // Una nota nueva nunca debe terminar accidentalmente en la fecha elegida antes.
  const seleccionar = (fecha) => {
    abrir(fecha)
    setError('')
  }
  const guardar = async (e) => {
    e.preventDefault()
    if (ocupado) return
    if (!texto.trim() || texto.trim().length > 200) {
      setError('Escribí una anotación de entre 1 y 200 caracteres.'); nueva.current.focus(); return
    }
    setOcupado(true)
    try {
      await AlmanaqueAPI.create({ fecha: fechaAbierta, texto })
      setTexto('')
      setError('')
      refrescar()
      nueva.current?.focus()
    } catch { /* La API muestra el error y conserva el borrador. */ }
    finally { setOcupado(false) }
  }
  const mantenerFoco = (e) => {
    if (e.key !== 'Tab') return
    const elementos = [...panel.current.querySelectorAll('button:not(:disabled), input:not(:disabled), textarea:not(:disabled)')]
    const primero = elementos[0], ultimo = elementos.at(-1)
    if (e.shiftKey && document.activeElement === primero) { e.preventDefault(); ultimo?.focus() }
    else if (!e.shiftKey && document.activeElement === ultimo) { e.preventDefault(); primero?.focus() }
  }

  return createPortal(
    <div className="almanaque-overlay" onClick={e => { if (e.target === e.currentTarget) cerrar() }}>
      <section ref={panel} className="almanaque-panel" role="dialog" aria-modal="true" aria-labelledby="almanaque-titulo" onKeyDown={mantenerFoco}>
        <header className="almanaque-panel-header">
          <div><h2 id="almanaque-titulo">Almanaque</h2><p>Anotaciones compartidas por el equipo</p></div>
          <button type="button" className="btn btn-secondary btn-sm" aria-label="Cerrar almanaque" onClick={cerrar}>×</button>
        </header>
        <div className="almanaque-panel-contenido">
          <nav className="almanaque-mes" aria-label="Navegar meses">
            <button type="button" className="btn btn-secondary btn-sm" aria-label="Mes anterior" onClick={() => seleccionar(fechaLocal(addMonths(mes, -1)))}>‹</button>
            <h3 aria-live="polite">{format(mes, 'MMMM yyyy', { locale: es })}</h3>
            <button type="button" className="btn btn-secondary btn-sm" aria-label="Mes siguiente" onClick={() => seleccionar(fechaLocal(addMonths(mes, 1)))}>›</button>
            <button type="button" className="btn btn-secondary btn-sm" onClick={() => seleccionar(fechaHoy)}>Hoy</button>
          </nav>
          <div className="almanaque-calendario" role="group" aria-label={format(mes, 'MMMM yyyy', { locale: es })}>
            {['L', 'M', 'M', 'J', 'V', 'S', 'D'].map((dia, i) => <span className="almanaque-semana" aria-hidden="true" key={i}>{dia}</span>)}
            {dias.map(d => {
              const fecha = fechaLocal(d)
              const tieneNotas = diasConNotas.has(fecha)
              return <button type="button" key={fecha} className={`almanaque-dia${d.getMonth() !== mes.getMonth() ? ' is-fuera' : ''}${fecha === fechaHoy ? ' is-hoy' : ''}${fecha === fechaAbierta ? ' is-elegido' : ''}`}
                aria-label={`${format(d, "EEEE d 'de' MMMM yyyy", { locale: es })}${tieneNotas ? ', con anotaciones' : ''}`}
                aria-pressed={fecha === fechaAbierta} aria-current={fecha === fechaHoy ? 'date' : undefined}
                onClick={() => seleccionar(fecha)}>
                <span>{d.getDate()}</span>{tieneNotas && <span className="almanaque-marca" aria-hidden="true" />}
              </button>
            })}
          </div>
          <EstadoAnotaciones {...datos} />
          {!datos.error && !datos.loading && <>
            {atrasadas.length > 0 && <section className="almanaque-seccion almanaque-atrasadas" aria-labelledby="almanaque-atrasadas">
              <h3 id="almanaque-atrasadas">Atrasadas <span>{atrasadas.length}</span></h3>
              <ul>{atrasadas.map(n => <Anotacion key={n.id} nota={n} editable mostrarFecha />)}</ul>
            </section>}
            <section className="almanaque-seccion" aria-labelledby="almanaque-dia-titulo">
              <h3 id="almanaque-dia-titulo">{fechaAbierta === fechaHoy ? 'Hoy · ' : ''}{format(parseISO(fechaAbierta), "EEEE d 'de' MMMM", { locale: es })}</h3>
              {notasDia.length ? <ul>{notasDia.map(n => <Anotacion key={n.id} nota={n} editable />)}</ul>
                : <p className="almanaque-vacio">Sin anotaciones para este día.</p>}
            </section>
          </>}
          <form className="almanaque-nueva" onSubmit={guardar}>
            <label className="lbl" htmlFor="almanaque-nueva">Agregar anotación · {format(parseISO(fechaAbierta), 'dd/MM/yyyy')}</label>
            <input ref={nueva} id="almanaque-nueva" className="inp" placeholder="Escribí y presioná Enter" maxLength={200} value={texto}
              aria-describedby="almanaque-ayuda" aria-invalid={!!error} disabled={ocupado}
              onChange={e => { setTexto(e.target.value); setError('') }} />
            <div className="almanaque-nueva-pie"><span id="almanaque-ayuda">{texto.length}/200 caracteres</span>
              <button type="submit" className="btn btn-primary btn-sm" disabled={ocupado}>{ocupado ? 'Guardando…' : 'Agregar'}</button></div>
            {error && <p className="almanaque-error" role="alert">{error}</p>}
          </form>
        </div>
      </section>
    </div>, document.body,
  )
}
