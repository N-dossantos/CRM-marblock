// src/views/Notas/NotaForm.jsx
import { useState } from 'react'
import { Modal, ItemsTable, TotalesBox, TotalesBoxMulti } from '../../components/UI'
import { $ar, fFecha, calcTotalesMulti } from '../../utils'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0 }

export default function NotaForm({ factura, productos = [], alicuotas = [], onSave, onClose }) {
  const multiIva = alicuotas.length > 0
  const alic21 = alicuotas.find(a => +a.porcentaje === 21)
  const alicuotasById = Object.fromEntries(alicuotas.map(a => [a.id, a]))
  const [form, setForm]   = useState({ tipo: 'NC', motivo: '', items: [], observaciones: '' })
  const [loading, setLoading] = useState(false)

  const addItem = () => setForm(f => ({ ...f, items: [...f.items, { ...ITEM_BASE, ...(multiIva && { alicuota_iva_id: alic21?.id }) }] }))

  const save = async () => {
    if (!form.items.length) { toast.error('Agregue al menos un ítem'); return }
    if (!form.motivo.trim()) { toast.error('El motivo es obligatorio'); return }
    setLoading(true)
    try {
      await onSave({
        factura_id:   factura.id,
        tipo:         form.tipo,
        motivo:       form.motivo,
        items:        form.items,
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
