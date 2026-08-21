// src/components/UI/ClienteSearch.jsx
// Combobox de clientes: reemplaza al <select> plano de los comprobantes. Se escribe razón social o
// CUIT y filtra; con la cartera real un desplegable de cientos de opciones es inusable.
//
// Mantiene la interfaz de un <select>: `value` es el id (string, como el value de un <option>) y
// `onChange` recibe el id como string — o '' al limpiar. Así los formularios que ya tenían un
// handler para el select no necesitan cambiarlo.
import { useEffect, useMemo, useRef, useState } from 'react'

// Tope de filas renderizadas. No es paginación: es para no volcar la cartera entera en el DOM
// cuando todavía no se escribió nada. Al cliente 51 se llega escribiendo, que es el punto.
const MAX_OPCIONES = 50

const etiqueta = (c) => (c.cuit ? `${c.razon_social} — ${c.cuit}` : c.razon_social)

export default function ClienteSearch({
  clientes = [],
  value,
  onChange,
  placeholder = 'Buscar por razón social o CUIT…',
  disabled = false,
}) {
  const [query, setQuery] = useState(null) // null = mostrando el seleccionado; string = tipeando
  const [open, setOpen]   = useState(false)
  const [hi, setHi]       = useState(0)
  const boxRef  = useRef(null)
  const listRef = useRef(null)

  const activos = useMemo(() => clientes.filter(c => c.activo !== false), [clientes])
  const sel     = useMemo(
    () => (value === '' || value == null ? null : activos.find(c => c.id === +value) || null),
    [activos, value],
  )

  const opciones = useMemo(() => {
    const term = (query || '').trim().toLowerCase()
    if (!term) return activos.slice(0, MAX_OPCIONES)
    return activos
      .filter(c => `${c.razon_social} ${c.cuit || ''}`.toLowerCase().includes(term))
      .slice(0, MAX_OPCIONES)
  }, [activos, query])

  // Con el desplegable abierto el input muestra lo tipeado; cerrado, el cliente elegido.
  const texto = open ? (query ?? '') : (sel ? etiqueta(sel) : '')

  useEffect(() => { setHi(0) }, [query, open])

  // Mantiene visible la fila resaltada al moverse con las flechas.
  useEffect(() => {
    if (!open || !listRef.current) return
    listRef.current.querySelector('[data-hi="1"]')?.scrollIntoView({ block: 'nearest' })
  }, [hi, open])

  // Clic fuera → cerrar y volver a mostrar el seleccionado.
  useEffect(() => {
    if (!open) return
    const onDown = (e) => {
      if (boxRef.current && !boxRef.current.contains(e.target)) { setOpen(false); setQuery(null) }
    }
    document.addEventListener('mousedown', onDown)
    return () => document.removeEventListener('mousedown', onDown)
  }, [open])

  const elegir = (c) => {
    onChange(String(c.id))
    setOpen(false)
    setQuery(null)
  }

  const onKeyDown = (e) => {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault()
      if (!open) { setOpen(true); setQuery(''); return }
      setHi(h => {
        const n = opciones.length
        if (!n) return 0
        return e.key === 'ArrowDown' ? (h + 1) % n : (h - 1 + n) % n
      })
    } else if (e.key === 'Enter') {
      if (open && opciones[hi]) { e.preventDefault(); elegir(opciones[hi]) }
    } else if (e.key === 'Escape') {
      if (open) { e.preventDefault(); setOpen(false); setQuery(null) }
    }
  }

  return (
    <div className="cli-search" ref={boxRef}>
      <input
        className="inp"
        value={texto}
        placeholder={sel ? etiqueta(sel) : placeholder}
        disabled={disabled}
        onChange={e => { setQuery(e.target.value); setOpen(true) }}
        onFocus={() => { setOpen(true); setQuery('') }}
        onKeyDown={onKeyDown}
        role="combobox"
        aria-expanded={open}
        aria-autocomplete="list"
      />
      {sel && !disabled && (
        <button
          type="button"
          className="cli-search-clear"
          title="Quitar cliente"
          // mousedown en vez de click: el click llegaría después del blur del input.
          onMouseDown={e => { e.preventDefault(); onChange(''); setQuery(null); setOpen(false) }}
        >×</button>
      )}

      {open && (
        <div className="cli-search-pop" ref={listRef}>
          {opciones.length === 0 && (
            <div className="cli-search-empty">Sin resultados para “{query}”</div>
          )}
          {opciones.map((c, i) => (
            <div
              key={c.id}
              data-hi={i === hi ? '1' : '0'}
              className={`cli-search-opt${i === hi ? ' is-hi' : ''}${sel?.id === c.id ? ' is-sel' : ''}`}
              onMouseEnter={() => setHi(i)}
              // mousedown: el input se blurea antes de que dispare el click y la opción se perdería.
              onMouseDown={e => { e.preventDefault(); elegir(c) }}
            >
              <span className="cli-search-nom">{c.razon_social}</span>
              {c.cuit && <span className="cli-search-cuit">{c.cuit}</span>}
            </div>
          ))}
          {opciones.length === MAX_OPCIONES && (
            <div className="cli-search-empty">Se muestran los primeros {MAX_OPCIONES} — afiná la búsqueda.</div>
          )}
        </div>
      )}
    </div>
  )
}
