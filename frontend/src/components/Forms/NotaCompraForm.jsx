// src/components/Forms/NotaCompraForm.jsx
// Nota de Crédito / Débito de COMPRA. Siempre ligada a una factura de compra existente
// (proveedor_id lo deriva el server desde la factura). Diferencias frente a NotaForm (Ventas):
//   * numeración DEL PROVEEDOR → punto_venta / número editables, no autogenerados;
//   * los ítems referencian `material_id` (no producto_id) y llevan alícuota IVA;
//   * IVA multi-alícuota: crear_nota_compra usa crm_calc_totales_multi_alicuota (sin alícuota
//     asume 21%). Preview con calcTotalesMulti + TotalesBoxMulti; el server recalcula;
//   * puede traer percepciones sufridas (§3.9): el proveedor las devuelve con signo contrario en
//     una NC, así que el monto se carga tal cual figura en el papel y no se recalcula.
import { useState } from 'react'
import { Modal, TotalesBoxMulti, PercepcionesTable } from '../UI'
import { calcTotalesMulti, calcSubtotalItem, $ar, fFecha, hoy } from '../../utils'
import toast from 'react-hot-toast'

const ITEM_BASE = { material_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0, alicuota_iva_id: '' }

export default function NotaCompraForm({ factura, materiales = [], alicuotas = [], onSave, onClose }) {
  const alic21 = alicuotas.find(a => +a.porcentaje === 21)
  const alicuotasById = Object.fromEntries(alicuotas.map(a => [a.id, a]))

  const [form, setForm] = useState({
    tipo:          'NC',
    tipo_letra:    factura.tipo || 'A',
    punto_venta:   '',
    numero_comp:   '',
    fecha:         hoy(),
    motivo:        '',
    observaciones: '',
    items:         [],
    percepciones:  [],
  })
  const [loading, setLoading] = useState(false)

  const setF = (patch) => setForm(f => ({ ...f, ...patch }))

  const addItem = () =>
    setForm(f => ({ ...f, items: [...f.items, { ...ITEM_BASE, alicuota_iva_id: alic21 ? alic21.id : '' }] }))

  const removeItem = (i) =>
    setForm(f => ({ ...f, items: f.items.filter((_, idx) => idx !== i) }))

  const updItem = (i, field, val) =>
    setForm(f => ({
      ...f,
      items: f.items.map((it, idx) => {
        if (idx !== i) return it
        const num = ['cantidad', 'precio_unitario', 'descuento_item'].includes(field)
        return { ...it, [field]: num ? (parseFloat(val) || 0) : val }
      }),
    }))

  const selMaterial = (i, matId) => {
    const m = materiales.find(x => x.id === +matId)
    setForm(f => ({
      ...f,
      items: f.items.map((it, idx) =>
        idx !== i ? it : {
          ...it,
          material_id: +matId || '',
          descripcion: m?.descripcion || it.descripcion,
          precio_unitario: m?.precio_referencia ?? it.precio_unitario,
        }),
    }))
  }

  const tot = calcTotalesMulti(form.items, 0, alicuotasById)

  const save = async () => {
    if (!form.punto_venta)   { toast.error('Ingrese el punto de venta del comprobante'); return }
    if (!form.numero_comp)   { toast.error('Ingrese el número del comprobante'); return }
    if (!form.items.length)  { toast.error('Agregue al menos un ítem'); return }
    if (!form.motivo.trim()) { toast.error('El motivo es obligatorio'); return }

    const items = form.items.map(it => ({
      material_id:     it.material_id || null,
      descripcion:     it.descripcion,
      cantidad:        it.cantidad,
      precio_unitario: it.precio_unitario,
      descuento_item:  it.descuento_item || 0,
      alicuota_iva_id: it.alicuota_iva_id || (alic21 ? alic21.id : null),
    }))

    setLoading(true)
    try {
      await onSave({
        factura_compra_id: factura.id,
        tipo:              form.tipo,
        tipo_letra:        form.tipo_letra,
        punto_venta:       form.punto_venta.trim(),
        numero_comp:       +form.numero_comp,
        fecha:             form.fecha,
        motivo:            form.motivo,
        items,
        observaciones:     form.observaciones || null,
        percepciones:      form.percepciones.length ? form.percepciones : null,
      })
    } finally { setLoading(false) }
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
        <strong>Factura de compra:</strong> {factura.numero} — {factura.razon_social} — {$ar(factura.total)} — {fFecha(factura.fecha)}
      </div>

      {/* Tipo de nota + letra + motivo */}
      <div className="form-row3" style={{ marginBottom: 14 }}>
        <div className="field">
          <label className="lbl">Tipo de nota</label>
          <select className="sel" value={form.tipo} onChange={e => setF({ tipo: e.target.value })}>
            <option value="NC">Nota de Crédito</option>
            <option value="ND">Nota de Débito</option>
          </select>
        </div>
        <div className="field">
          <label className="lbl">Letra</label>
          <select className="sel" value={form.tipo_letra} onChange={e => setF({ tipo_letra: e.target.value })}>
            <option value="A">A</option><option value="B">B</option>
            <option value="C">C</option><option value="M">M</option>
          </select>
        </div>
        <div className="field">
          <label className="lbl">Fecha *</label>
          <input type="date" className="inp" value={form.fecha} onChange={e => setF({ fecha: e.target.value })} />
        </div>
      </div>

      {/* Numeración del proveedor + motivo */}
      <div className="form-row3" style={{ marginBottom: 14 }}>
        <div className="field">
          <label className="lbl">Punto de venta *</label>
          <input className="inp" value={form.punto_venta} placeholder="0001" onChange={e => setF({ punto_venta: e.target.value })} />
        </div>
        <div className="field">
          <label className="lbl">Número *</label>
          <input type="number" className="inp" value={form.numero_comp} placeholder="12345" onChange={e => setF({ numero_comp: e.target.value })} />
        </div>
        <div className="field">
          <label className="lbl">Motivo *</label>
          <input className="inp" value={form.motivo} onChange={e => setF({ motivo: e.target.value })}
            placeholder={form.tipo === 'NC' ? 'Ej: Devolución / bonificación' : 'Ej: Diferencia de precio'} />
        </div>
      </div>

      {/* Ítems */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
        <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px' }}>Ítems</span>
        <button className="btn btn-secondary btn-sm" onClick={addItem}>+ Agregar ítem</button>
      </div>

      <div className="items-table-wrap">
        <table className="items-table">
          <thead>
            <tr>
              <th style={{ width: 150 }}>Material</th>
              <th>Descripción</th>
              <th className="th-right" style={{ width: 65 }}>Cant.</th>
              <th className="th-right" style={{ width: 110 }}>Precio</th>
              <th className="th-right" style={{ width: 58 }}>Dto%</th>
              <th style={{ width: 95 }}>IVA</th>
              <th className="th-right" style={{ width: 110 }}>Subtotal</th>
              <th style={{ width: 34 }}></th>
            </tr>
          </thead>
          <tbody>
            {form.items.length === 0 ? (
              <tr><td colSpan={8} className="empty-state">Sin ítems</td></tr>
            ) : form.items.map((it, i) => (
              <tr key={i}>
                <td>
                  <select className="inp inp-sm sel" value={it.material_id || ''} onChange={e => selMaterial(i, e.target.value)}>
                    <option value="">— Libre —</option>
                    {materiales.filter(m => m.activo).map(m => (
                      <option key={m.id} value={m.id}>{m.codigo} – {m.descripcion.substring(0, 32)}</option>
                    ))}
                  </select>
                </td>
                <td><input className="inp inp-sm" value={it.descripcion || ''} onChange={e => updItem(i, 'descripcion', e.target.value)} /></td>
                <td className="td-right"><input type="number" className="inp inp-sm inp-right" style={{ width: 60 }} value={it.cantidad} min="0.001" step="0.001" onChange={e => updItem(i, 'cantidad', e.target.value)} /></td>
                <td className="td-right"><input type="number" className="inp inp-sm inp-right" style={{ width: 105 }} value={it.precio_unitario} min="0" onChange={e => updItem(i, 'precio_unitario', e.target.value)} /></td>
                <td className="td-right"><input type="number" className="inp inp-sm inp-right" style={{ width: 52 }} value={it.descuento_item || 0} min="0" max="100" onChange={e => updItem(i, 'descuento_item', e.target.value)} /></td>
                <td>
                  <select className="inp inp-sm sel" value={it.alicuota_iva_id || ''} onChange={e => updItem(i, 'alicuota_iva_id', +e.target.value)}>
                    {alicuotas.map(a => <option key={a.id} value={a.id}>{a.porcentaje}%</option>)}
                  </select>
                </td>
                <td className="td-right td-bold">{$ar(calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item))}</td>
                <td style={{ textAlign: 'center' }}>
                  <button onClick={() => removeItem(i)} style={{ background: 'none', border: 'none', cursor: 'pointer', color: 'var(--red-500)', fontSize: 19, lineHeight: 1, padding: 0 }}>×</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <PercepcionesTable
        percepciones={form.percepciones}
        neto={tot.neto_gravado}
        onChange={(percepciones) => setF({ percepciones })}
      />

      <TotalesBoxMulti totales={tot} percepciones={form.percepciones} />

      <div className="field" style={{ marginTop: 12 }}>
        <label className="lbl">Observaciones</label>
        <input className="inp" value={form.observaciones} onChange={e => setF({ observaciones: e.target.value })} />
      </div>
    </Modal>
  )
}
