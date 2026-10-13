// src/components/UI/RowActions.jsx
// Acciones de un renglón de lista: un botón principal (la acción obvia según el estado, si hay),
// un botón chico de PDF y un menú ⋯ con el resto. Reemplaza a la fila de 4–5 botones sueltos
// que no entraba en la columna y saltaba al renglón de abajo.
//
//   <RowActions
//     primary={{ label: 'Cobrar', icon: '💵', tone: 'success', onClick }}   // o null
//     onPdf={() => …}                                                      // opcional
//     items={[{ label, icon, onClick, danger, hidden }, …]}               // menú ⋯
//   />
//
// Los clics no se propagan: el <tr> puede tener su propio onClick (abrir el detalle) sin que tocar
// un botón lo dispare. El menú va por portal con position:fixed porque .tbl-wrap tiene
// overflow:hidden y lo recortaría.
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'

const MENU_W = 200

export default function RowActions({ primary = null, onPdf = null, pdfTitle = 'Ver PDF', items = [] }) {
  const visibles = items.filter(it => it && !it.hidden)
  // Las destructivas van al final, separadas — y el orden del resto lo decide la pantalla.
  const normales = visibles.filter(it => !it.danger)
  const peligro  = visibles.filter(it => it.danger)
  const menu     = [...normales, ...peligro]

  const [open, setOpen] = useState(false)
  const [pos, setPos]   = useState(null)
  const [hi, setHi]     = useState(0)
  const btnRef  = useRef(null)
  const menuRef = useRef(null)

  const cerrar = () => { setOpen(false); setPos(null) }

  // Ubicación: debajo del ⋯, alineado a su borde derecho; si no entra abajo, hacia arriba.
  useLayoutEffect(() => {
    if (!open || !btnRef.current || !menuRef.current) return
    const r = btnRef.current.getBoundingClientRect()
    const h = menuRef.current.offsetHeight
    const abajo = r.bottom + 4 + h <= window.innerHeight - 8
    setPos({
      top:  abajo ? r.bottom + 4 : Math.max(8, r.top - 4 - h),
      left: Math.max(8, Math.min(r.right - MENU_W, window.innerWidth - MENU_W - 8)),
    })
  }, [open])

  useEffect(() => {
    if (!open) return
    setHi(0)
    menuRef.current?.focus()
    const onDown = (e) => {
      if (menuRef.current?.contains(e.target) || btnRef.current?.contains(e.target)) return
      cerrar()
    }
    // Con scroll el menú fijo quedaría flotando lejos de su fila: se cierra.
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

  const ejecutar = (it) => { cerrar(); it.onClick() }

  const onKeyDownMenu = (e) => {
    const n = menu.length
    if (e.key === 'ArrowDown') { e.preventDefault(); setHi(h => (h + 1) % n) }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setHi(h => (h - 1 + n) % n) }
    else if (e.key === 'Enter') { e.preventDefault(); if (menu[hi]) ejecutar(menu[hi]) }
    // preventDefault: useEscape ignora el ESC ya usado, así no cierra también un modal de abajo.
    else if (e.key === 'Escape') { e.preventDefault(); cerrar(); btnRef.current?.focus() }
    else if (e.key === 'Tab') cerrar()
  }

  return (
    <div className="row-actions" onClick={(e) => e.stopPropagation()}>
      {primary && (
        <button className={`btn btn-xs row-act-primary row-act-${primary.tone || 'primary'}`} onClick={primary.onClick}>
          {primary.icon && <span aria-hidden>{primary.icon}</span>}{primary.label}
        </button>
      )}
      {onPdf && (
        <button className="btn btn-xs row-act-icon row-act-pdf" title={pdfTitle} onClick={onPdf}>PDF</button>
      )}
      {menu.length > 0 && (
        <button
          ref={btnRef}
          className={`btn btn-xs row-act-icon row-act-more${open ? ' is-open' : ''}`}
          title="Más acciones"
          aria-label="Más acciones"
          aria-haspopup="menu"
          aria-expanded={open}
          onClick={() => (open ? cerrar() : setOpen(true))}
        >⋯</button>
      )}

      {open && createPortal(
        <div
          ref={menuRef}
          className="row-act-menu"
          role="menu"
          tabIndex={-1}
          style={{ width: MENU_W, top: pos?.top ?? -9999, left: pos?.left ?? -9999 }}
          onKeyDown={onKeyDownMenu}
          onClick={(e) => e.stopPropagation()}
        >
          {menu.map((it, i) => (
            <div key={it.label}>
              {it.danger && i === normales.length && normales.length > 0 && <div className="row-act-sep" />}
              <button
                role="menuitem"
                className={`row-act-item${it.danger ? ' is-danger' : ''}${i === hi ? ' is-hi' : ''}`}
                onMouseEnter={() => setHi(i)}
                onClick={() => ejecutar(it)}
              >
                <span className="row-act-ico" aria-hidden>{it.icon}</span>
                {it.label}
              </button>
            </div>
          ))}
        </div>,
        document.body,
      )}
    </div>
  )
}
