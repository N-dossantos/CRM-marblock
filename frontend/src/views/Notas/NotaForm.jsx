// src/views/Notas/NotaForm.jsx
import { useState } from 'react'
import { Modal, ItemsTable, TotalesBox, TotalesBoxMulti } from '../../components/UI'
import { $ar, fFecha, calcTotalesMulti } from '../../utils'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0, pallets: 1, unidades_por_pallet: 1 }

export default function NotaForm({ factura, productos = [], alicuotas = [], onSave, onClose }) {
  const multiIva = alicuotas.length > 0
  const alic21 = alicuotas.find(a => +a.porcentaje === 21)
  const alicuotasById = Object.fromEntries(alicuotas.map(a => [a.id, a]))
  const [form, setForm]   = useState({ tipo: 'NC', motivo: '', items: [], observaciones: '' })
  const [loading, setLoading] = useState(false)

  const addItem = () => setForm(f => ({ ...f, items: [...f.items, { ...ITEM_BASE, ...(multiIva && { alicuota_iva_id: alic21?.id }) }] }))

  // Ítems de la factura para copiar a la nota. crear_nota calcula con descuento general 0, así que
  // el descuento general de la factura se combina en el descuento de cada ítem —
  // 1 − (1 − ítem)(1 − general) — salvo pallets vacíos y transporte, que en la factura tampoco lo
  // llevaron (crm_calc_totales_multi_alicuota los excluye). Así la nota repite el precio neto que
  // se facturó.
  const dtoGeneral = +factura.descuento_general || 0
  const itemsFactura = factura.items || []
  const desdeFactura = (it) => {
    const excluido = it.es_pallet_vacio || it.es_transporte
    const di = +it.descuento_item || 0
    const combinado = excluido || !dtoGeneral ? di : 100 * (1 - (1 - di / 100) * (1 - dtoGeneral / 100))
    return {
      _fac_item_id:        it.id,
      producto_id:         it.producto_id ?? '',
      descripcion:         it.descripcion || '',
      cantidad:            +it.cantidad || 0,
      precio_unitario:     +it.precio_unitario || 0,
      descuento_item:      Math.round(combinado * 100) / 100,
      pallets:             it.pallets ?? 1,
      unidades_por_pallet: it.unidades_por_pallet ?? 1,
      es_pallet_vacio:     !!it.es_pallet_vacio,
      es_transporte:       !!it.es_transporte,
      ...(multiIva && { alicuota_iva_id: it.alicuota_iva_id ?? alic21?.id }),
    }
  }
  const marcado = (it) => form.items.some(x => x._fac_item_id === it.id)
  const toggleItemFactura = (it) => setForm(f => ({
    ...f,
    items: f.items.some(x => x._fac_item_id === it.id)
      ? f.items.filter(x => x._fac_item_id !== it.id)
      : [...f.items, desdeFactura(it)],
  }))

  const save = async () => {
    if (!form.items.length) { toast.error('Agregue al menos un ítem'); return }
    if (!form.motivo.trim()) { toast.error('El motivo es obligatorio'); return }
    setLoading(true)
    try {
      await onSave({
        factura_id:   factura.id,
        tipo:         form.tipo,
        motivo:       form.motivo,
        // `_fac_item_id` es sólo para saber qué renglón vino de qué ítem de la factura.
        items:        form.items.map(({ _fac_item_id, ...it }) => it),
        observaciones: form.observaciones,
      })
    } finally {
      setLoading(false)
    }
  }

  return (
    <Modal
      title={`Nueva Nota de ${form.tipo === 'NC' ? 'Crédito' : 'Débito'} — Fac. ${factura.numero}`}
      size="xl"
      onClose={onClose}
      footer={
        <>
          <button className="btn btn-secondary" onClick={onClose} disabled={loading}>Cancelar</button>
          <button className="btn btn-primary" onClick={save} disabled={loading}>
            {loading ? 'Guardando…' : '✓ Guardar nota'}
          </button>
        </>
      }
    >
      {/* Factura de referencia */}
      <div className="info-box" style={{ marginBottom: 16 }}>
        <strong>Factura de referencia:</strong> {factura.numero} — {factura.razon_social} — {$ar(factura.total)} — {fFecha(factura.fecha)}
      </div>

      <div className="form-row3" style={{ marginBottom: 14 }}>
        <div className="field">
          <label className="lbl">Tipo de nota</label>
          <select className="sel" value={form.tipo} onChange={e => setForm(f => ({ ...f, tipo: e.target.value }))}>
            <option value="NC">Nota de Crédito</option>
            <option value="ND">Nota de Débito</option>
          </select>
        </div>
        <div className="field" style={{ gridColumn: '2 / 4' }}>
          <label className="lbl">Motivo *</label>
          <input className="inp" value={form.motivo} onChange={e => setForm(f => ({ ...f, motivo: e.target.value }))}
            placeholder={form.tipo === 'NC' ? 'Ej: Devolución parcial de mercadería' : 'Ej: Diferencia de precio'} />
        </div>
      </div>

      {itemsFactura.length > 0 && (
        <div className="field" style={{ marginBottom: 14 }}>
          <label className="lbl">
            Ítems de la factura — marcá los que van en la nota (la cantidad se ajusta abajo)
            {dtoGeneral > 0 && ` · descuento general ${dtoGeneral}% incluido`}
          </label>
          <div style={{ border: '1px solid var(--gray-200)', borderRadius: 8, maxHeight: 220, overflowY: 'auto' }}>
            {itemsFactura.map(it => (
              <label key={it.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '7px 14px', borderBottom: '1px solid var(--gray-100)', cursor: 'pointer' }}>
                <input type="checkbox" checked={marcado(it)} onChange={() => toggleItemFactura(it)} />
                {it.codigo && <span className="code">{it.codigo}</span>}
                <span style={{ flex: 1 }}>{it.descripcion}</span>
                <span style={{ fontSize: 12, color: 'var(--gray-500)' }}>{+it.cantidad} × {$ar(it.precio_unitario)}{+it.descuento_item ? ` −${+it.descuento_item}%` : ''}</span>
                <span style={{ fontWeight: 700, minWidth: 100, textAlign: 'right' }}>{$ar(it.subtotal)}</span>
              </label>
            ))}
          </div>
        </div>
      )}

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
        <span className="lbl" style={{ margin: 0 }}>Ítems</span>
        <button className="btn btn-secondary btn-sm" onClick={addItem}>+ Agregar ítem</button>
      </div>

      <ItemsTable
        items={form.items}
        productos={productos}
        alicuotas={multiIva ? alicuotas : []}
        onChange={items => setForm(f => ({ ...f, items }))}
      />

      {multiIva
        ? <TotalesBoxMulti totales={calcTotalesMulti(form.items, 0, alicuotasById)} />
        : <TotalesBox items={form.items} dtoGeneral={0} />}

      <div className="field" style={{ marginTop: 14 }}>
        <label className="lbl">Observaciones</label>
        <input className="inp" value={form.observaciones} onChange={e => setForm(f => ({ ...f, observaciones: e.target.value }))} />
      </div>
    </Modal>
  )
}
