import { useState } from 'react'
import { CalendarioAPI } from '../../api'
import { errorEvento, fFecha } from '../../utils'
import { useCalendario } from '../../lib/calendario'

export function CalendarioIcon() {
  return <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <rect x="3" y="5" width="18" height="16" rx="2" /><path d="M16 3v4M8 3v4M3 11h18M8 15h2M14 15h2M8 18h2" />
  </svg>
}

export default function Evento({ evento, editable = false, mostrarFecha = false }) {
  const { abrir, refrescar } = useCalendario()
  const [editando, setEditando] = useState(false)
  const [form, setForm] = useState(() => formDe(evento))
  const [ocupado, setOcupado] = useState(false)
  const [error, setError] = useState('')

  const ejecutar = async (accion) => {
    if (ocupado) return
    setOcupado(true)
    try {
      await accion()
      setEditando(false)
      refrescar()
    } catch { /* La API informa el error; el editor conserva el texto. */ }
    finally { setOcupado(false) }
  }
  const editar = () => {
    if (!editable) { abrir(evento.fecha); return }
    setForm(formDe(evento))
    setError('')
    setEditando(true)
  }
  const guardar = (e) => {
    e.preventDefault()
    const problema = errorEvento(form)
    if (problema) { setError(problema); return }
    ejecutar(() => CalendarioAPI.update(evento.id, form))
  }

  return (
    <li className={`calendario-evento${evento.hecha ? ' is-hecha' : ''}`}>
      <input type="checkbox" checked={evento.hecha} disabled={ocupado}
        aria-label={`${evento.hecha ? 'Marcar pendiente' : 'Marcar hecho'}: ${evento.titulo}`}
        onChange={e => ejecutar(() => CalendarioAPI.tildar(evento.id, e.target.checked))} />
      {editando ? (
        <form className="calendario-editor" onSubmit={guardar}>
          <label className="lbl" htmlFor={`evento-fecha-${evento.id}`}>Fecha</label>
          <input id={`evento-fecha-${evento.id}`} className="inp" type="date" value={form.fecha} required disabled={ocupado}
            onChange={e => setForm(f => ({ ...f, fecha: e.target.value }))} />
          <label className="lbl" htmlFor={`evento-titulo-${evento.id}`}>Título</label>
          <input id={`evento-titulo-${evento.id}`} className="inp" value={form.titulo} maxLength={100} required autoFocus disabled={ocupado}
            onChange={e => setForm(f => ({ ...f, titulo: e.target.value }))} />
          <label className="lbl" htmlFor={`evento-descripcion-${evento.id}`}>Descripción (opcional)</label>
          <textarea id={`evento-descripcion-${evento.id}`} className="inp" value={form.descripcion} maxLength={500} disabled={ocupado}
            onChange={e => setForm(f => ({ ...f, descripcion: e.target.value }))} />
          {error && <p className="calendario-error" role="alert">{error}</p>}
          <div className="calendario-editor-acciones">
            <button type="button" className="btn btn-secondary btn-sm" disabled={ocupado} onClick={() => setEditando(false)}>Cancelar</button>
            <button className="btn btn-primary btn-sm" disabled={ocupado}>{ocupado ? 'Guardando…' : 'Guardar cambios'}</button>
          </div>
        </form>
      ) : (
        <>
          <button type="button" className="calendario-evento-texto" onClick={editar} disabled={ocupado}
            title={editable ? 'Editar el evento' : 'Abrir este día en el calendario'}>
            {mostrarFecha && <time dateTime={evento.fecha}>{fFecha(evento.fecha)}</time>}
            <span className="calendario-evento-titulo">{evento.titulo}</span>
            {evento.descripcion && <span className="calendario-evento-descripcion">{evento.descripcion}</span>}
          </button>
          {editable && <button type="button" className="calendario-borrar" disabled={ocupado}
            aria-label={`Eliminar evento: ${evento.titulo}`} title="Eliminar evento"
            onClick={() => {
              if (confirm(`¿Eliminar el evento «${evento.titulo}»?`)) ejecutar(() => CalendarioAPI.delete(evento.id))
            }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
              <path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7" />
            </svg>
          </button>}
        </>
      )}
    </li>
  )
}

const formDe = (evento) => ({ fecha: evento.fecha, titulo: evento.titulo, descripcion: evento.descripcion ?? '' })

export function EstadoEventos({ loading, error, reintentar }) {
  if (error) return <div className="calendario-error" role="alert">
    No se pudieron cargar los eventos.
    <button type="button" className="btn btn-secondary btn-sm" onClick={reintentar}>Reintentar</button>
  </div>
  if (loading) return <p className="calendario-vacio" role="status">Cargando eventos…</p>
  return null
}
