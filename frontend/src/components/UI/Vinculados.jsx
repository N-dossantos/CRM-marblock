// src/components/UI/Vinculados.jsx
// Celda de "comprobante vinculado" en los listados (remitos ↔ facturas): se ve el primer número
// y, si hay más, un "+N ▾" que despliega el resto. Sólo informativo: la columna no se ensancha ni
// salta de renglón con tres o cuatro números juntos.
//
//   <Vinculados numeros={['00002-00010391', '00002-00010392']} vacio={<Badge estado="pendiente" />} />
//
// Como RowActions: los clics no llegan al <tr> (que abre el detalle) y la lista va por portal con
// position:fixed porque .tbl-wrap tiene overflow:hidden y la recortaría.
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'

export default function Vinculados({ numeros = [], vacio = null }) {
  const [open, setOpen] = useState(false)
  const [pos, setPos]   = useState(null)
  const btnRef  = useRef(null)
  const menuRef = useRef(null)

  const cerrar = () => { setOpen(false); setPos(null) }

  // Debajo del botón, alineado a su borde izquierdo; si no entra abajo, hacia arriba.
  useLayoutEffect(() => {
    if (!open || !btnRef.current || !menuRef.current) return
    const r = btnRef.current.getBoundingClientRect()
    const { offsetHeight: h, offsetWidth: w } = menuRef.current
    const abajo = r.bottom + 4 + h <= window.innerHeight - 8
    setPos({
      top:  abajo ? r.bottom + 4 : Math.max(8, r.top - 4 - h),
      left: Math.max(8, Math.min(r.left, window.innerWidth - w - 8)),
    })
  }, [open])

  useEffect(() => {
    if (!open) return
    menuRef.current?.focus()
    const onDown = (e) => {
      if (menuRef.current?.contains(e.target) || btnRef.current?.contains(e.target)) return
      cerrar()
    }
    // Con scroll la lista fija quedaría flotando lejos de su fila: se cierra.
    const onScroll = (e) => { if (!menuRef.current?.contains(e.target)) cerrar() }
    document.addEventListener('mousedown', onDown)
    window.addEventListener('scroll', onScroll, true)
    window.addEventListener('resize', cerrar)
    return () => {
      document.removeEventListener('mousedown', onDown)
      window.removeEventListener('scroll', onScroll, true)
      window.removeEventListener('resize', cerrar)
    }
  }, [open])

  if (!numeros.length) return vacio
  const [primero, ...resto] = numeros

  return (
    <span className="vinc" onClick={(e) => e.stopPropagation()}>
      <span className="code vinc-num">{primero}</span>
      {resto.length > 0 && (
        <button
          ref={btnRef}
          className={`btn btn-xs vinc-mas${open ? ' is-open' : ''}`}
          title={`${resto.length} más`}
          aria-haspopup="true"
          aria-expanded={open}
          onClick={() => (open ? cerrar() : setOpen(true))}
        >+{resto.length} ▾</button>
      )}

      {open && createPortal(
        <div
          ref={menuRef}
          className="row-act-menu vinc-menu"
          tabIndex={-1}
          style={{ top: pos?.top ?? -9999, left: pos?.left ?? -9999 }}
          // preventDefault: useEscape ignora el ESC ya usado, así no cierra también un modal de abajo.
          onKeyDown={(e) => { if (e.key === 'Escape') { e.preventDefault(); cerrar(); btnRef.current?.focus() } }}
          onClick={(e) => e.stopPropagation()}
        >
          {resto.map(n => <div key={n} className="code vinc-num">{n}</div>)}
        </div>,
        document.body,
      )}
    </span>
  )
}
