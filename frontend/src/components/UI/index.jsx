// src/components/UI/index.jsx
import { useEffect, useId, useState } from 'react'
import { BADGE_COLORS, ESTADOS, $ar, calcTotales, calcTotalesC2, calcSubtotalItem } from '../../utils'

// ── BADGE ────────────────────────────────────────────────────────────
export function Badge({ estado }) {
  return (
    <span className={`badge ${BADGE_COLORS[estado] || ''}`}>
      {ESTADOS[estado] || estado}
    </span>
  )
}

// ── MODAL ────────────────────────────────────────────────────────────
export function Modal({ title, size = 'md', onClose, footer, children }) {
  return (
    <div className="overlay" onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`modal modal-${size}`}>
        <div className="modal-header">
          <h2>{title}</h2>
          <button className="btn-close" onClick={onClose}>×</button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-footer">{footer}</div>}
      </div>
    </div>
  )
}

// ── TOTALES BOX ──────────────────────────────────────────────────────
export function TotalesBox({ items = [], dtoGeneral = 0 }) {
  const t = calcTotales(items, dtoGeneral)
  return (
    <div className="totales-box">
      <div className="totales-row">
        <span>Subtotal s/IVA</span>
        <span>{$ar(t.subtotal)}</span>
      </div>
      {dtoGeneral > 0 && (
        <div className="totales-row">
          <span>Descuento {dtoGeneral}%</span>
          <span style={{ color: 'var(--red-500)' }}>— {$ar(t.descuento_monto)}</span>
        </div>
      )}
      <hr className="totales-divider" />
      <div className="totales-row">
        <span>Neto gravado</span>
        <span>{$ar(t.neto_gravado)}</span>
      </div>
      <div className="totales-row">
        <span>IVA 21%</span>
        <span>{$ar(t.iva_monto)}</span>
      </div>
      <div className="totales-row total">
        <span>TOTAL</span>
        <span className="val">{$ar(t.total)}</span>
      </div>
    </div>
  )
}

// ── TOTALES BOX CUENTA 2 (sin IVA) ──────────────────────────────────
// El circuito informal no liquida impuestos: los precios ya son netos, así que no hay
// neto gravado ni línea de IVA. Preview; la RPC recalcula (anti-tamper).
export function TotalesBoxC2({ items = [], dtoGeneral = 0 }) {
  const t = calcTotalesC2(items, dtoGeneral)
  return (
    <div className="totales-box">
      <div className="totales-row">
        <span>Subtotal</span>
        <span>{$ar(t.subtotal)}</span>
      </div>
      {dtoGeneral > 0 && (
        <div className="totales-row">
          <span>Descuento {dtoGeneral}%</span>
          <span style={{ color: 'var(--red-500)' }}>— {$ar(t.descuento_monto)}</span>
        </div>
      )}
      <hr className="totales-divider" />
      <div className="totales-row total">
        <span>TOTAL</span>
        <span className="val">{$ar(t.total)}</span>
      </div>
      <div className="totales-row" style={{ fontSize: 11, color: 'var(--gray-500)' }}>
        <span>Sin impuestos</span>
        <span />
      </div>
    </div>
  )
}

// ── TOTALES BOX MULTI-ALÍCUOTA (Compras) ────────────────────────────
// Recibe un objeto de totales ya calculado (calcTotalesMulti): general + `detalle`
// (una línea de IVA por alícuota). Preview; el servidor recalcula (anti-tamper).
export function TotalesBoxMulti({ totales }) {
  const t = totales || { subtotal: 0, descuento_monto: 0, neto_gravado: 0, iva_monto: 0, total: 0, detalle: [] }
  return (
    <div className="totales-box">
      <div className="totales-row">
        <span>Subtotal s/IVA</span>
        <span>{$ar(t.subtotal)}</span>
      </div>
      {t.descuento_monto > 0 && (
        <div className="totales-row">
          <span>Descuento</span>
          <span style={{ color: 'var(--red-500)' }}>— {$ar(t.descuento_monto)}</span>
        </div>
      )}
      <hr className="totales-divider" />
      <div className="totales-row">
        <span>Neto gravado</span>
        <span>{$ar(t.neto_gravado)}</span>
      </div>
      {(t.detalle || []).map((d) => (
        <div className="totales-row" key={d.alicuota_iva_id ?? d.porcentaje}>
          <span>IVA {d.porcentaje}% <span style={{ color: 'var(--gray-400)' }}>(neto {$ar(d.neto_gravado)})</span></span>
          <span>{$ar(d.iva_monto)}</span>
        </div>
      ))}
      <div className="totales-row">
        <span style={{ fontWeight: 600 }}>IVA total</span>
        <span style={{ fontWeight: 600 }}>{$ar(t.iva_monto)}</span>
      </div>
      <div className="totales-row total">
        <span>TOTAL</span>
        <span className="val">{$ar(t.total)}</span>
      </div>
    </div>
  )
}

// ── PRODUCTO BUSCADOR (autocompletar por ID corto o texto) ─────────
// <input list> + <datalist>: usa el desplegable nativo del navegador en vez de uno propio con
// position:absolute, que quedaría recortado por .items-table-wrap (overflow:hidden) y
// .modal-body (overflow-y:auto). Cada <option> vale la etiqueta completa "[ID] Descripción — X
// un/pallet"; al elegirla el navegador ya deja ese texto en el input, así que sólo hace falta
// resolverla contra el catálogo. Tipear sólo el ID (sin abrir el desplegable) también funciona: se
// resuelve por código exacto al perder el foco o con Enter — productos.md §3.2.1.
const productoLabel = (p) =>
  `[${p.codigo}] ${p.descripcion}${p.unidades_por_pallet > 1 ? ` — ${p.unidades_por_pallet} un/pallet` : ''}`

function ProductoBuscador({ value, productos, onSelect }) {
  const activos = productos.filter(p => p.activo)
  // El desplegable sólo ofrece activos, pero la etiqueta se resuelve contra el catálogo completo:
  // un comprobante viejo puede referenciar un producto dado de baja y el combo quedaría en blanco.
  const selected = productos.find(p => p.id === value)
  const [text, setText] = useState(selected ? productoLabel(selected) : '')

  useEffect(() => {
    setText(selected ? productoLabel(selected) : '')
  }, [selected])

  const byLabel  = new Map(activos.map(p => [productoLabel(p), p]))
  const byCodigo = new Map(activos.map(p => [p.codigo, p]))

  const commit = (raw) => {
    const picked = byLabel.get(raw) || byCodigo.get(raw.trim())
    if (picked) { onSelect(picked); setText(productoLabel(picked)); return }
    setText(selected ? productoLabel(selected) : '')
  }

  // useId: el id debe ser único en todo el documento, no sólo dentro de la grilla — dos ItemsTable
  // montadas a la vez (o dos filas con el mismo índice) colisionarían con un id por número de fila.
  const listId = `productos-dl-${useId()}`

  return (
    <>
      <input
        className="inp inp-sm"
        list={listId}
        value={text}
        placeholder="ID o descripción…"
        onChange={(e) => {
          const raw = e.target.value
          setText(raw)
          const exact = byLabel.get(raw)
          if (exact) onSelect(exact)
        }}
        onBlur={(e) => commit(e.target.value)}
        onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); commit(e.target.value) } }}
      />
      <datalist id={listId}>
        {activos.map(p => <option key={p.id} value={productoLabel(p)} />)}
      </datalist>
    </>
  )
}

// ── ITEMS TABLE (editable o readonly) ───────────────────────────────
export function ItemsTable({ items, productos = [], alicuotas = [], readonly = false, onChange }) {
  const showIva = alicuotas.length > 0

  const update = (i, field, val) => {
    if (!onChange) return
    const next = items.map((it, idx) => {
      if (idx !== i) return it
      if (field === 'pallets') {
        const pallets = Math.max(0, Math.trunc(parseFloat(val)) || 0)
        const upp = it.unidades_por_pallet || 1
        return { ...it, pallets, cantidad: pallets * upp, ...(it.es_pallet_vacio && { pallets_auto: false }) }
      }
      // Unidades editable independiente de Pallets: venta parcial de un pallet (ej. 80 de 105).
      // Pallets sigue representando cuántos pallets físicos se usan (no cambia solo), así que no se
      // toca acá — sólo vuelve a recalcularse si el usuario edita Pallets de nuevo.
      if (field === 'cantidad') {
        return { ...it, cantidad: Math.max(0, Math.trunc(parseFloat(val)) || 0) }
      }
      const updated = { ...it, [field]: ['precio_unitario','descuento_item'].includes(field) ? parseFloat(val) || 0 : val }
      return updated
    })
    onChange(next)
  }

  const selectProd = (i, p) => {
    if (!onChange) return
    const upp = Number(p.unidades_por_pallet) || 1
    let next = items.map((it, idx) => idx !== i ? it : {
      ...it,
      producto_id:         p.id,
      descripcion:         p.descripcion || '',
      precio_unitario:     p.precio_sin_iva || 0,
      unidades_por_pallet: upp,
      es_pallet_vacio:     !!p.es_pallet_vacio,
      es_transporte:       !!p.es_transporte,
      pallets:             1,
      cantidad:            upp,
      // Elegir el pallet vacío a mano = línea del usuario, fuera del auto-sync (productos.md §1.2:
      // la línea es editable). Sin esto usePalletsVacios la trata como suya y la borra al instante
      // si no hay otros pallets en la grilla (su total daría 0). Se escribe siempre, también al
      // cambiar la fila a otro producto, para no arrastrar la marca de una elección anterior.
      pallets_auto:        p.es_pallet_vacio ? false : undefined,
    })
    // Una sola línea de pallets vacíos: la elección manual reemplaza a la automática. Si no, quedan
    // las dos en la grilla y el comprobante factura los pallets por duplicado.
    if (p.es_pallet_vacio) {
      next = next.filter((it, idx) => idx === i || !(it.es_pallet_vacio && it.pallets_auto !== false))
    }
    onChange(next)
  }

  const selectAlic = (i, val) => {
    if (!onChange) return
    onChange(items.map((it, idx) => idx !== i ? it : { ...it, alicuota_iva_id: +val || '' }))
  }

  const remove = (i) => onChange && onChange(items.filter((_, idx) => idx !== i))

  return (
    <div className="items-table-wrap">
      <table className="items-table">
        <thead>
          <tr>
            <th style={{ width: 170 }}>Producto</th>
            <th>Descripción</th>
            <th className="th-right" style={{ width: 65 }}>Pallets</th>
            <th className="th-right" style={{ width: 80 }}>Unidades</th>
            <th className="th-right" style={{ width: 120 }}>Precio s/IVA</th>
            <th className="th-right" style={{ width: 65 }}>Dto%</th>
            {showIva && <th style={{ width: 90 }}>IVA</th>}
            <th className="th-right" style={{ width: 110 }}>Subtotal</th>
            {!readonly && <th style={{ width: 36 }}></th>}
          </tr>
        </thead>
        <tbody>
          {items.length === 0 ? (
            <tr><td colSpan={7 + (showIva ? 1 : 0) + (readonly ? 0 : 1)} className="empty-state">Sin ítems</td></tr>
          ) : items.map((it, i) => (
            <tr key={i}>
              <td>
                {readonly
                  ? <span className="code">{it.codigo || '—'}</span>
                  : <ProductoBuscador value={it.producto_id} productos={productos} onSelect={(p) => selectProd(i, p)} />
                }
              </td>
              <td>
                {readonly
                  ? it.descripcion
                  : <input className="inp inp-sm" value={it.descripcion || ''} onChange={(e) => update(i, 'descripcion', e.target.value)} />
                }
              </td>
              <td className="td-right">
                {readonly
                  ? (it.pallets ?? '—')
                  : <input type="number" className="inp inp-sm inp-right" style={{ width: 60 }} value={it.pallets ?? ''} min="0" step="1" onChange={(e) => update(i, 'pallets', e.target.value)} />
                }
              </td>
              <td className="td-right">
                {readonly
                  ? Number(it.cantidad || 0).toLocaleString('es-AR')
                  : <input type="number" className="inp inp-sm inp-right" style={{ width: 70 }} value={it.cantidad ?? ''} min="0" step="1" onChange={(e) => update(i, 'cantidad', e.target.value)} />
                }
              </td>
              <td className="td-right">
                {readonly
                  ? $ar(it.precio_unitario)
                  : <input type="number" className="inp inp-sm inp-right" style={{ width: 110 }} value={it.precio_unitario} min="0" onChange={(e) => update(i, 'precio_unitario', e.target.value)} />
                }
              </td>
              <td className="td-right">
                {readonly
                  ? `${it.descuento_item || 0}%`
                  : <input type="number" className="inp inp-sm inp-right" style={{ width: 58 }} value={it.descuento_item || 0} min="0" max="100" onChange={(e) => update(i, 'descuento_item', e.target.value)} />
                }
              </td>
              {showIva && (
                <td>
                  {readonly
                    ? `${it.iva_porcentaje ?? 21}%`
                    : (
                      <select className="inp inp-sm sel" value={it.alicuota_iva_id || ''} onChange={(e) => selectAlic(i, e.target.value)}>
                        {alicuotas.map(a => <option key={a.id} value={a.id}>{a.porcentaje}%</option>)}
                      </select>
                    )
                  }
                </td>
              )}
              <td className="td-right td-bold">{$ar(calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item))}</td>
              {!readonly && (
                <td style={{ textAlign: 'center' }}>
                  <button onClick={() => remove(i)} style={{ background: 'none', border: 'none', cursor: 'pointer', color: 'var(--red-500)', fontSize: 19, lineHeight: 1, padding: 0 }}>×</button>
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

// ── EMPTY STATE ──────────────────────────────────────────────────────
export function EmptyState({ icon = '📋', message = 'Sin resultados' }) {
  return (
    <tr>
      <td colSpan={20}>
        <div className="empty-state">
          <div className="icon">{icon}</div>
          <p>{message}</p>
        </div>
      </td>
    </tr>
  )
}

// ── LOADING ──────────────────────────────────────────────────────────
export function Loading() {
  return <div className="loading-wrap">Cargando…</div>
}
