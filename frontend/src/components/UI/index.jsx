// src/components/UI/index.jsx
import { BADGE_COLORS, ESTADOS, $ar, calcTotales, calcSubtotalItem } from '../../utils'

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

// ── ITEMS TABLE (editable o readonly) ───────────────────────────────
export function ItemsTable({ items, productos = [], alicuotas = [], readonly = false, onChange }) {
  const showIva = alicuotas.length > 0
  const update = (i, field, val) => {
    if (!onChange) return
    const next = items.map((it, idx) => {
      if (idx !== i) return it
      const updated = { ...it, [field]: ['cantidad','precio_unitario','descuento_item'].includes(field) ? parseFloat(val) || 0 : val }
      return updated
    })
    onChange(next)
  }

  const selectProd = (i, prodId) => {
    if (!onChange) return
    const p = productos.find(p => p.id === +prodId)
    const next = items.map((it, idx) =>
      idx !== i ? it : { ...it, producto_id: +prodId, descripcion: p?.descripcion || '', precio_unitario: p?.precio_sin_iva || 0 }
    )
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
            <th className="th-right" style={{ width: 70 }}>Cant.</th>
            <th className="th-right" style={{ width: 120 }}>Precio s/IVA</th>
            <th className="th-right" style={{ width: 65 }}>Dto%</th>
            {showIva && <th style={{ width: 90 }}>IVA</th>}
            <th className="th-right" style={{ width: 110 }}>Subtotal</th>
            {!readonly && <th style={{ width: 36 }}></th>}
          </tr>
        </thead>
        <tbody>
          {items.length === 0 ? (
            <tr><td colSpan={6 + (showIva ? 1 : 0) + (readonly ? 0 : 1)} className="empty-state">Sin ítems</td></tr>
          ) : items.map((it, i) => (
            <tr key={i}>
              <td>
                {readonly
                  ? <span className="code">{it.codigo || '—'}</span>
                  : (
                    <select
                      className="inp inp-sm sel"
                      value={it.producto_id || ''}
                      onChange={(e) => selectProd(i, e.target.value)}
                    >
                      <option value="">— Seleccionar —</option>
                      {productos.filter(p => p.activo).map(p => (
                        <option key={p.id} value={p.id}>{p.codigo} – {p.descripcion.substring(0,40)}</option>
                      ))}
                    </select>
                  )
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
                  ? it.cantidad
                  : <input type="number" className="inp inp-sm inp-right" style={{ width: 65 }} value={it.cantidad} min="0.01" step="0.01" onChange={(e) => update(i, 'cantidad', e.target.value)} />
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
