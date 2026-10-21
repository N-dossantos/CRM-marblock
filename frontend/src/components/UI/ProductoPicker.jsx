// src/components/UI/ProductoPicker.jsx
// Ventana de selección de productos: el catálogo entero en una tabla, con filtro por código o
// descripción y carga de pallets/unidades en varias filas a la vez. Confirma todo junto y el
// formulario lo vuelca a la grilla con agregarProductos (en ./index.jsx).
//
// Convive con el ProductoBuscador de cada renglón (tipear el código directo sigue andando); esto es
// para cargar un comprobante de varios productos sin abrir un renglón por producto.
import { useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { $ar } from '../../utils'
import { Modal } from './index'

// Sin acentos ni mayúsculas: "adoquín" tiene que encontrar "Adoquin".
const norm = (s) => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()

// El catálogo no tiene rubro: la primera palabra de la descripción ya lo dice (Bloque, Adoquin,
// Plaqueta, Cubremuros…).
const tipoDe = (p) => {
  const w = norm(p.descripcion).split(/\s+/)[0] || ''
  return w ? w[0].toUpperCase() + w.slice(1) : ''
}

const round3 = (n) => Math.round(n * 1000) / 1000

const ATAJO_CONFIRMAR = /Mac|iPhone|iPad/.test(navigator.platform) ? '⌘↵' : 'Ctrl+↵'

// Botón "Elegir productos" + la ventana + el atajo F2. Es lo único que montan los formularios.
export function ElegirProductosBtn({ productos = [], cantidadDecimal = false, onConfirm }) {
  const [open, setOpen] = useState(false)

  useEffect(() => {
    const onKey = (e) => {
      if (e.key !== 'F2') return
      e.preventDefault()
      setOpen(true)
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])

  return (
    <>
      <button className="btn btn-primary btn-sm" onClick={() => setOpen(true)} title="Atajo: F2">
        📦 Elegir productos
      </button>
      {open && (
        <ProductoPicker
          productos={productos}
          cantidadDecimal={cantidadDecimal}
          onClose={() => setOpen(false)}
          onConfirm={(sel) => { onConfirm(sel); setOpen(false) }}
        />
      )}
    </>
  )
}

export default function ProductoPicker({ productos = [], cantidadDecimal = false, onConfirm, onClose }) {
  // El pallet vacío no se ofrece: lo mantiene usePalletsVacios según los pallets del resto. Elegirlo
  // acá lo pasaría a manual y dejaría de seguir el total. Quien lo quiera a mano lo elige en el renglón.
  const catalogo = useMemo(() => productos.filter(p => p.activo !== false && !p.es_pallet_vacio), [productos])
  // Materiales de Compras llegan con unidades_por_pallet=1: ahí "pallets" no significa nada y se
  // carga sólo la cantidad.
  const conPallets = useMemo(() => catalogo.some(p => (Number(p.unidades_por_pallet) || 1) > 1), [catalogo])

  const tipos = useMemo(() => {
    const t = [...new Set(catalogo.map(tipoDe).filter(Boolean))].sort((a, b) => a.localeCompare(b))
    return t.length >= 2 && t.length <= 12 ? t : []
  }, [catalogo])

  const [query, setQuery] = useState('')
  const [tipo, setTipo]   = useState('')
  const [hi, setHi]       = useState(0)
  // { [producto_id]: { pallets, cantidad } } — sobrevive a cambiar el filtro.
  const [sel, setSel]     = useState({})

  const searchRef = useRef(null)
  const listRef   = useRef(null)
  const inputRefs = useRef({})
  // Recorriendo la lista sin escribir (↑↓ o un chip): ahí Enter en el buscador vacío carga la fila
  // marcada en vez de confirmar.
  const recorriendoRef = useRef(false)

  useEffect(() => { searchRef.current?.focus() }, [])

  const filas = useMemo(() => {
    const term = norm(query.trim())
    let base = tipo ? catalogo.filter(p => tipoDe(p) === tipo) : catalogo
    if (!term) return base
    // Sólo dígitos = un código, y trae ese código y nada más: "2" no trae el 20–25 ni "4" los
    // "14x19x39" de la descripción. Se compara como número para que "3" encuentre el material "003".
    if (/^\d+$/.test(term)) {
      return base.filter(p => {
        const c = norm(p.codigo)
        return c === term || (/^\d+$/.test(c) && Number(c) === Number(term))
      })
    }
    // Texto: cada palabra filtra por su lado, contra código + descripción — "adoq 6" encuentra
    // "Adoquin Holanda de 10x20x6".
    const palabras = term.split(/\s+/)
    return base.filter(p => {
      const texto = `${norm(p.codigo)} ${norm(p.descripcion)}`
      return palabras.every(w => texto.includes(w))
    })
  }, [catalogo, query, tipo])

  useEffect(() => { setHi(0) }, [query, tipo])

  useEffect(() => {
    listRef.current?.querySelector('[data-hi="1"]')?.scrollIntoView({ block: 'nearest' })
  }, [hi])

  const elegidos = catalogo.filter(p => (sel[p.id]?.cantidad || 0) > 0)
  const totalPallets = elegidos.reduce((a, p) => a + (sel[p.id].pallets || 0), 0)

  const setPallets = (p, val) => {
    const pallets = Math.max(0, Math.trunc(parseFloat(val)) || 0)
    const upp = Number(p.unidades_por_pallet) || 1
    setSel(s => ({ ...s, [p.id]: { pallets, cantidad: pallets * upp } }))
  }

  // Unidades independiente de Pallets, igual que en la grilla: venta parcial de un pallet (80 de 105).
  // Si todavía no había pallets cargados se proponen los que hacen falta para esas unidades — sin
  // eso la línea entraría con 0 pallets y no sumaría a los pallets vacíos.
  const setCantidad = (p, val) => {
    const n = Math.max(0, parseFloat(val) || 0)
    const cantidad = cantidadDecimal ? round3(n) : Math.trunc(n)
    const upp = Number(p.unidades_por_pallet) || 1
    setSel(s => {
      const previos = s[p.id]?.pallets || 0
      const pallets = !conPallets ? (cantidad > 0 ? 1 : 0)
        : cantidad === 0 ? 0
        : previos || Math.ceil(cantidad / upp)
      return { ...s, [p.id]: { pallets, cantidad } }
    })
  }

  // Ir a la fila: si todavía no tiene nada, arranca en 1 pallet (o 1 unidad) para que Enter-Enter
  // alcance para sumar un producto.
  const enfocarFila = (p) => {
    if (!(sel[p.id]?.cantidad > 0)) {
      if (conPallets) setPallets(p, 1)
      else setCantidad(p, 1)
    }
    setTimeout(() => { const el = inputRefs.current[p.id]; el?.focus(); el?.select() }, 0)
  }

  // Vuelve con el buscador vacío: el próximo código se tipea de cero y, si no hay otro, Enter agrega.
  const volverAlBuscador = () => {
    recorriendoRef.current = false
    setQuery('')
    searchRef.current?.focus()
  }

  const confirmar = () => {
    if (!elegidos.length) return
    onConfirm(elegidos.map(p => ({ producto: p, pallets: sel[p.id].pallets, cantidad: sel[p.id].cantidad })))
  }

  // Ctrl/Cmd+Enter confirma desde cualquier campo de la ventana.
  const onKeyDownVentana = (e) => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); confirmar() }
  }

  const onKeyDownBuscador = (e) => {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault()
      const n = filas.length
      if (!n) return
      recorriendoRef.current = true
      setHi(h => (e.key === 'ArrowDown' ? (h + 1) % n : (h - 1 + n) % n))
    } else if (e.key === 'Enter' && !e.ctrlKey && !e.metaKey) {
      e.preventDefault()
      // Código → Enter → pallets → Enter → … → Enter con el buscador vacío: agrega lo elegido.
      if (!query.trim() && elegidos.length && !recorriendoRef.current) confirmar()
      else if (filas[hi]) enfocarFila(filas[hi])
    }
  }

  const onKeyDownCampo = (e) => {
    if (e.key === 'Enter' && !e.ctrlKey && !e.metaKey) { e.preventDefault(); volverAlBuscador() }
  }

  const footer = (
    <>
      <span className="prod-pick-resumen">
        {elegidos.length === 0
          ? (conPallets ? 'Cargá pallets o unidades en los productos que quieras agregar' : 'Cargá la cantidad en los ítems que quieras agregar')
          : <>
              <b>{elegidos.length}</b> {elegidos.length === 1 ? 'producto' : 'productos'}
              {conPallets && <> · <b>{totalPallets}</b> {totalPallets === 1 ? 'pallet' : 'pallets'}</>}
              <button className="prod-pick-limpiar" onClick={() => setSel({})}>limpiar</button>
            </>}
      </span>
      <button className="btn btn-secondary" onClick={onClose}>Cancelar</button>
      <button className="btn btn-primary" disabled={!elegidos.length} onClick={confirmar}
        title="Enter con el buscador vacío, o Ctrl/⌘+Enter desde cualquier campo">
        Agregar {elegidos.length || ''} {elegidos.length === 1 ? 'producto' : 'productos'}
        <span className="prod-pick-atajo">{ATAJO_CONFIRMAR}</span>
      </button>
    </>
  )

  // Portal al body: la ventana se abre desde adentro del modal del comprobante y no tiene que
  // quedar contenida (ni recortada) por su .modal-body con scroll.
  return createPortal(
    <div onKeyDown={onKeyDownVentana}>
      <Modal almanaque={false} title="Elegir productos" size="lg" onClose={onClose} footer={footer}>
        <input
          ref={searchRef}
          className="inp"
          value={query}
          placeholder={elegidos.length
            ? `Otro código…  o Enter para agregar ${elegidos.length === 1 ? 'el producto' : `los ${elegidos.length} productos`}`
            : 'Código o descripción…  (↑↓ para moverte, Enter para cargar)'}
          onChange={(e) => { recorriendoRef.current = false; setQuery(e.target.value) }}
          onKeyDown={onKeyDownBuscador}
        />

        {tipos.length > 0 && (
          <div className="prod-pick-chips">
            {['', ...tipos].map(t => (
              <button
                key={t || '_todos'}
                className={`prod-pick-chip${tipo === t ? ' is-on' : ''}`}
                onClick={() => { recorriendoRef.current = true; setTipo(t); searchRef.current?.focus() }}
              >
                {t || 'Todos'}
              </button>
            ))}
          </div>
        )}

        <div className="prod-pick-list" ref={listRef}>
          <table className="items-table">
            <thead>
              <tr>
                <th style={{ width: 64 }}>Código</th>
                <th>Descripción</th>
                {conPallets && <th className="th-right" style={{ width: 80 }}>Un/pallet</th>}
                <th className="th-right" style={{ width: 110 }}>Precio s/IVA</th>
                {conPallets && <th className="th-right" style={{ width: 76 }}>Pallets</th>}
                <th className="th-right" style={{ width: 90 }}>{conPallets ? 'Unidades' : 'Cantidad'}</th>
              </tr>
            </thead>
            <tbody>
              {filas.length === 0 ? (
                <tr><td colSpan={6} className="empty-state">Sin resultados para “{query}”</td></tr>
              ) : filas.map((p, i) => {
                const s = sel[p.id]
                const elegido = (s?.cantidad || 0) > 0
                return (
                  <tr
                    key={p.id}
                    data-hi={i === hi ? '1' : '0'}
                    className={`prod-pick-row${i === hi ? ' is-hi' : ''}${elegido ? ' is-sel' : ''}`}
                    onMouseEnter={() => setHi(i)}
                    onClick={(e) => { if (e.target.tagName !== 'INPUT') enfocarFila(p) }}
                  >
                    <td><span className="code">{p.codigo}</span></td>
                    <td>{p.descripcion}</td>
                    {conPallets && <td className="td-right">{Number(p.unidades_por_pallet) || 1}</td>}
                    <td className="td-right">{$ar(p.precio_sin_iva)}</td>
                    {conPallets && (
                      <td className="td-right">
                        <input
                          ref={el => { inputRefs.current[p.id] = el }}
                          type="number" min="0" step="1"
                          className="inp inp-sm inp-right" style={{ width: 64 }}
                          value={s?.pallets || ''}
                          placeholder="0"
                          onChange={(e) => setPallets(p, e.target.value)}
                          onFocus={() => setHi(i)}
                          onKeyDown={onKeyDownCampo}
                        />
                      </td>
                    )}
                    <td className="td-right">
                      <input
                        ref={conPallets ? undefined : el => { inputRefs.current[p.id] = el }}
                        type="number" min="0" step={cantidadDecimal ? '0.001' : '1'}
                        className="inp inp-sm inp-right" style={{ width: 80 }}
                        value={s?.cantidad || ''}
                        placeholder="0"
                        onChange={(e) => setCantidad(p, e.target.value)}
                        onFocus={() => setHi(i)}
                        onKeyDown={onKeyDownCampo}
                      />
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </Modal>
    </div>,
    document.body,
  )
}
