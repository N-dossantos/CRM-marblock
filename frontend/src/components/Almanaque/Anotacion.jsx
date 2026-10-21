import { useState } from 'react'
import { AlmanaqueAPI } from '../../api'
import { fFecha } from '../../utils'
import { useAlmanaque } from '../../lib/almanaque'

export function CalendarioIcon() {
  return <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <rect x="3" y="5" width="18" height="16" rx="2" /><path d="M16 3v4M8 3v4M3 11h18M8 15h2M14 15h2M8 18h2" />
  </svg>
}

export default function Anotacion({ nota, editable = false, mostrarFecha = false }) {
  const { abrir, refrescar } = useAlmanaque()
  const [editando, setEditando] = useState(false)
  const [form, setForm] = useState({ fecha: nota.fecha, texto: nota.texto })
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
    if (!editable) { abrir(nota.fecha); return }
    setForm({ fecha: nota.fecha, texto: nota.texto })
    setError('')
    setEditando(true)
  }
  const guardar = (e) => {
    e.preventDefault()
    if (!form.texto.trim() || form.texto.trim().length > 200) {
      setError('Escribí una anotación de entre 1 y 200 caracteres.'); return
    }
    ejecutar(() => AlmanaqueAPI.update(nota.id, form))
  }

  return (
    <li className={`almanaque-nota${nota.hecha ? ' is-hecha' : ''}`}>
      <input type="checkbox" checked={nota.hecha} disabled={ocupado}
        aria-label={`${nota.hecha ? 'Marcar pendiente' : 'Marcar hecha'}: ${nota.texto}`}
        onChange={e => ejecutar(() => AlmanaqueAPI.tildar(nota.id, e.target.checked))} />
      {editando ? (
        <form className="almanaque-editor" onSubmit={guardar}>
          <label className="lbl" htmlFor={`nota-fecha-${nota.id}`}>Fecha</label>
          <input id={`nota-fecha-${nota.id}`} className="inp" type="date" value={form.fecha} required disabled={ocupado}
            onChange={e => setForm(f => ({ ...f, fecha: e.target.value }))} />
          <label className="lbl" htmlFor={`nota-texto-${nota.id}`}>Anotación</label>
          <textarea id={`nota-texto-${nota.id}`} className="inp" value={form.texto} maxLength={200} required autoFocus disabled={ocupado}
            onChange={e => setForm(f => ({ ...f, texto: e.target.value }))} />
          {error && <p className="almanaque-error" role="alert">{error}</p>}
          <div className="almanaque-editor-acciones">
            <button type="button" className="btn btn-secondary btn-sm" disabled={ocupado} onClick={() => setEditando(false)}>Cancelar</button>
            <button className="btn btn-primary btn-sm" disabled={ocupado}>{ocupado ? 'Guardando…' : 'Guardar cambios'}</button>
          </div>
        </form>
      ) : (
        <>
          <button type="button" className="almanaque-nota-texto" onClick={editar} disabled={ocupado}
            title={editable ? 'Editar fecha o texto' : 'Abrir este día en el almanaque'}>
            {mostrarFecha && <time dateTime={nota.fecha}>{fFecha(nota.fecha)}</time>}
            <span>{nota.texto}</span>
          </button>
          {editable && <button type="button" className="almanaque-borrar" disabled={ocupado}
            aria-label={`Eliminar anotación: ${nota.texto}`} title="Eliminar anotación"
            onClick={() => {
              if (confirm(`¿Eliminar la anotación «${nota.texto}»?`)) ejecutar(() => AlmanaqueAPI.delete(nota.id))
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

export function EstadoAnotaciones({ loading, error, reintentar }) {
  if (error) return <div className="almanaque-error" role="alert">
    No se pudieron cargar las anotaciones.
    <button type="button" className="btn btn-secondary btn-sm" onClick={reintentar}>Reintentar</button>
  </div>
  if (loading) return <p className="almanaque-vacio" role="status">Cargando anotaciones…</p>
  return null
}
