import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { addMonths, eachDayOfInterval, endOfMonth, endOfWeek, format, parseISO, startOfMonth, startOfWeek } from 'date-fns'
import { es } from 'date-fns/locale'
import { CalendarioAPI } from '../../api'
import { errorEvento, fechaLocal } from '../../utils'
import { useCalendario, useEventos } from '../../lib/calendario'
import { useEscape } from '../../hooks/useEscape'
import Evento, { CalendarioIcon, EstadoEventos } from './Evento'
import './calendario.css'

export function CalendarioBoton() {
  const { abrir, pendientes, fechaAbierta } = useCalendario()
  return <button type="button" className="btn btn-secondary btn-sm calendario-boton" onClick={() => abrir()}
    aria-label={`Abrir calendario${pendientes > 0 ? `, ${pendientes} pendientes` : ''}`}
    aria-haspopup="dialog" aria-expanded={!!fechaAbierta} title="Calendario compartido">
    <CalendarioIcon /><span className="calendario-boton-label">Calendario</span>
    {pendientes > 0 && <span className="calendario-contador" aria-hidden="true">{pendientes}</span>}
  </button>
}

export default function CalendarioPanel() {
  const { fechaAbierta } = useCalendario()
  return fechaAbierta ? <PanelAbierto /> : null
}

const NUEVO = { titulo: '', descripcion: '' }

function PanelAbierto() {
  const { fechaAbierta, fechaHoy, abrir, cerrar, refrescar } = useCalendario()
  const mes = startOfMonth(parseISO(fechaAbierta))
  const desde = fechaLocal(mes)
  const hasta = fechaLocal(endOfMonth(mes))
  const datos = useEventos(desde, hasta)
  const [nuevo, setNuevo] = useState(NUEVO)
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')
  const panel = useRef(null)
  const titulo = useRef(null)
  const volverAlTitulo = useRef(false)
  const dias = eachDayOfInterval({ start: startOfWeek(mes, { weekStartsOn: 1 }), end: endOfWeek(endOfMonth(mes), { weekStartsOn: 1 }) })
  const diasConEventos = new Set(datos.eventos.map(ev => ev.fecha))
  const eventosDia = datos.eventos.filter(ev => ev.fecha === fechaAbierta)
  const atrasados = datos.atrasados.filter(ev => ev.fecha !== fechaAbierta)
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

  // Mientras guarda, el campo está deshabilitado y no toma el foco: vuelve cuando se habilita, así se
  // pueden cargar varios eventos seguidos con Enter.
  useEffect(() => {
    if (!ocupado && volverAlTitulo.current) {
      volverAlTitulo.current = false
      titulo.current?.focus()
    }
  }, [ocupado])

  // Un evento nuevo nunca debe terminar accidentalmente en la fecha elegida antes.
  const seleccionar = (fecha) => {
    abrir(fecha)
    setError('')
  }
  const cambiar = (campo) => (e) => {
    setNuevo(n => ({ ...n, [campo]: e.target.value }))
    setError('')
  }
  // Enter en el título guarda (es un input del form); en la descripción es un salto de línea.
  const guardar = async (e) => {
    e.preventDefault()
    if (ocupado) return
    const problema = errorEvento(nuevo)
    if (problema) { setError(problema); titulo.current.focus(); return }
    setOcupado(true)
    try {
      await CalendarioAPI.create({ fecha: fechaAbierta, ...nuevo })
      setNuevo(NUEVO)
      setError('')
      refrescar()
    } catch { /* La API muestra el error y conserva el borrador. */ }
    finally {
      volverAlTitulo.current = true
      setOcupado(false)
    }
  }
  const mantenerFoco = (e) => {
    if (e.key !== 'Tab') return
    const elementos = [...panel.current.querySelectorAll('button:not(:disabled), input:not(:disabled), textarea:not(:disabled)')]
    const primero = elementos[0], ultimo = elementos.at(-1)
    if (e.shiftKey && document.activeElement === primero) { e.preventDefault(); ultimo?.focus() }
    else if (!e.shiftKey && document.activeElement === ultimo) { e.preventDefault(); primero?.focus() }
  }

  return createPortal(
    <div className="calendario-overlay" onClick={e => { if (e.target === e.currentTarget) cerrar() }}>
      <section ref={panel} className="calendario-panel" role="dialog" aria-modal="true" aria-labelledby="calendario-titulo" onKeyDown={mantenerFoco}>
        <header className="calendario-panel-header">
          <div><h2 id="calendario-titulo">Calendario</h2><p>Eventos compartidos por el equipo</p></div>
          <button type="button" className="btn btn-secondary btn-sm" aria-label="Cerrar calendario" onClick={cerrar}>×</button>
        </header>
        <div className="calendario-panel-contenido">
          <nav className="calendario-mes" aria-label="Navegar meses">
            <button type="button" className="btn btn-secondary btn-sm" aria-label="Mes anterior" onClick={() => seleccionar(fechaLocal(addMonths(mes, -1)))}>‹</button>
            <h3 aria-live="polite">{format(mes, 'MMMM yyyy', { locale: es })}</h3>
            <button type="button" className="btn btn-secondary btn-sm" aria-label="Mes siguiente" onClick={() => seleccionar(fechaLocal(addMonths(mes, 1)))}>›</button>
            <button type="button" className="btn btn-secondary btn-sm" onClick={() => seleccionar(fechaHoy)}>Hoy</button>
          </nav>
          <div className="calendario-grilla" role="group" aria-label={format(mes, 'MMMM yyyy', { locale: es })}>
            {['L', 'M', 'M', 'J', 'V', 'S', 'D'].map((dia, i) => <span className="calendario-semana" aria-hidden="true" key={i}>{dia}</span>)}
            {dias.map(d => {
              const fecha = fechaLocal(d)
              const tieneEventos = diasConEventos.has(fecha)
              return <button type="button" key={fecha} className={`calendario-dia${d.getMonth() !== mes.getMonth() ? ' is-fuera' : ''}${fecha === fechaHoy ? ' is-hoy' : ''}${fecha === fechaAbierta ? ' is-elegido' : ''}`}
                aria-label={`${format(d, "EEEE d 'de' MMMM yyyy", { locale: es })}${tieneEventos ? ', con eventos' : ''}`}
                aria-pressed={fecha === fechaAbierta} aria-current={fecha === fechaHoy ? 'date' : undefined}
                onClick={() => seleccionar(fecha)}>
                <span>{d.getDate()}</span>{tieneEventos && <span className="calendario-marca" aria-hidden="true" />}
              </button>
            })}
          </div>
          <EstadoEventos {...datos} />
          {!datos.error && !datos.loading && <>
            {atrasados.length > 0 && <section className="calendario-seccion calendario-atrasados" aria-labelledby="calendario-atrasados">
              <h3 id="calendario-atrasados">Atrasados <span>{atrasados.length}</span></h3>
              <ul>{atrasados.map(ev => <Evento key={ev.id} evento={ev} editable mostrarFecha />)}</ul>
            </section>}
            <section className="calendario-seccion" aria-labelledby="calendario-dia-titulo">
              <h3 id="calendario-dia-titulo">{fechaAbierta === fechaHoy ? 'Hoy · ' : ''}{format(parseISO(fechaAbierta), "EEEE d 'de' MMMM", { locale: es })}</h3>
              {eventosDia.length ? <ul>{eventosDia.map(ev => <Evento key={ev.id} evento={ev} editable />)}</ul>
                : <p className="calendario-vacio">Sin eventos para este día.</p>}
            </section>
          </>}
          <form className="calendario-nuevo" onSubmit={guardar} aria-labelledby="calendario-nuevo-encabezado">
            <h3 id="calendario-nuevo-encabezado">Agregar evento · {format(parseISO(fechaAbierta), 'dd/MM/yyyy')}</h3>
            <label className="lbl" htmlFor="calendario-nuevo-titulo">Título</label>
            <input ref={titulo} id="calendario-nuevo-titulo" className="inp" placeholder="Por ej. Cliente Duramat" maxLength={100}
              value={nuevo.titulo} aria-describedby="calendario-ayuda" aria-invalid={!!error} disabled={ocupado}
              onChange={cambiar('titulo')} />
            <label className="lbl" htmlFor="calendario-nuevo-descripcion">Descripción (opcional)</label>
            <textarea id="calendario-nuevo-descripcion" className="inp" maxLength={500} value={nuevo.descripcion} disabled={ocupado}
              placeholder="Por ej. viene a retirar 10 bloques de 20 estándar" onChange={cambiar('descripcion')} />
            <div className="calendario-nuevo-pie">
              <span id="calendario-ayuda">Enter en el título guarda · {nuevo.titulo.length}/100 · {nuevo.descripcion.length}/500</span>
              <button type="submit" className="btn btn-primary btn-sm" disabled={ocupado}>{ocupado ? 'Guardando…' : 'Agregar'}</button>
            </div>
            {error && <p className="calendario-error" role="alert">{error}</p>}
          </form>
        </div>
      </section>
    </div>, document.body,
  )
}
