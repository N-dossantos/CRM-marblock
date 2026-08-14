// src/components/Forms/CompraComprobanteForm.jsx
// Formulario reutilizable para Factura y Remito de COMPRA.
// Diferencias clave frente a ComprobanteForm (Ventas):
//   * punto_venta / número son DEL PROVEEDOR → campos editables, no autogenerados;
//   * los ítems referencian `material_id` (no producto_id) y, en factura, llevan alícuota IVA;
//   * IVA multi-alícuota (preview con calcTotalesMulti; el servidor recalcula).
import { useState, useEffect } from 'react'
import { Modal, TotalesBoxMulti } from '../UI'
import { calcTotalesMulti, calcSubtotalItem, $ar, hoy } from '../../utils'
import { RemitosCompraAPI } from '../../api'
import toast from 'react-hot-toast'

const ITEM_BASE = { material_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0, alicuota_iva_id: '' }

export default function CompraComprobanteForm({
  title,
  tipo,               // 'factura' | 'remito'
  initial = {},
  proveedores = [],
  materiales = [],
  alicuotas = [],     // [{ id, porcentaje, descripcion }]
  onSave,
  onClose,
}) {
  const esFactura = tipo === 'factura'
  const alic21 = alicuotas.find(a => +a.porcentaje === 21)
  const alicuotasById = Object.fromEntries(alicuotas.map(a => [a.id, a]))

  const [form, setForm] = useState({
    proveedor_id:      initial.proveedor_id || '',
    tipo_fac:          initial.tipo || 'A',
    punto_venta:       initial.punto_venta?.trim() || '',
    numero_comp:       initial.numero_comp || '',
    fecha:             initial.fecha || hoy(),
    fecha_recepcion:   initial.fecha_recepcion || hoy(),
    cae:               initial.cae || '',
    descuento_general: initial.descuento_general || 0,
    remito_compra_id:  initial.remito_compra_id || '',
    observaciones:     initial.observaciones || '',
    items: (initial.items || []).map(it => ({
      material_id:     it.material_id || '',
      descripcion:     it.descripcion || '',
      cantidad:        it.cantidad ?? 1,
      precio_unitario: it.precio_unitario ?? 0,
      descuento_item:  it.descuento_item ?? 0,
      alicuota_iva_id: it.alicuota_iva_id || (alic21 ? alic21.id : ''),
    })),
  })
  const [remitos, setRemitos] = useState([])
  const [loading, setLoading] = useState(false)

  // Remitos pendientes del proveedor (solo factura, para vincular).
  useEffect(() => {
    if (!esFactura || !form.proveedor_id) { setRemitos([]); return }
    RemitosCompraAPI.pendientes(form.proveedor_id).then(setRemitos).catch(() => setRemitos([]))
  }, [esFactura, form.proveedor_id])

  const setF = (patch) => setForm(f => ({ ...f, ...patch }))

  const addItem = () =>
    setForm(f => ({ ...f, items: [...f.items, { ...ITEM_BASE, alicuota_iva_id: alic21 ? alic21.id : '' }] }))

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

  const removeItem = (i) =>
    setForm(f => ({ ...f, items: f.items.filter((_, idx) => idx !== i) }))

  const onRemitoChange = (remId) => {
    const rem = remitos.find(r => r.id === +remId)
    if (rem) {
      setForm(f => ({
        ...f,
        remito_compra_id: remId,
        items: (rem.items || []).map(it => ({
          material_id: it.material_id || '', descripcion: it.descripcion || '',
          cantidad: it.cantidad ?? 1, precio_unitario: it.precio_unitario ?? 0,
          descuento_item: it.descuento_item ?? 0, alicuota_iva_id: alic21 ? alic21.id : '',
        })),
      }))
    } else {
      setForm(f => ({ ...f, remito_compra_id: '' }))
    }
  }

  const tot = calcTotalesMulti(form.items, form.descuento_general, alicuotasById)

  const save = async () => {
    if (!form.proveedor_id)  { toast.error('Seleccione un proveedor'); return }
    if (!form.punto_venta)   { toast.error('Ingrese el punto de venta del comprobante'); return }
    if (!form.numero_comp)   { toast.error('Ingrese el número del comprobante'); return }
    if (!form.items.length)  { toast.error('Agregue al menos un ítem'); return }

    const items = form.items.map(it => ({
      material_id:     it.material_id || null,
      descripcion:     it.descripcion,
      cantidad:        it.cantidad,
      precio_unitario: it.precio_unitario,
      descuento_item:  it.descuento_item || 0,
      ...(esFactura && { alicuota_iva_id: it.alicuota_iva_id || (alic21 ? alic21.id : null) }),
    }))

    const payload = esFactura ? {
      proveedor_id:      +form.proveedor_id,
      tipo:              form.tipo_fac,
      punto_venta:       form.punto_venta.trim(),
      numero_comp:       +form.numero_comp,
      fecha:             form.fecha,
      fecha_recepcion:   form.fecha_recepcion || null,
      cae:               form.cae || null,
      descuento_general: +form.descuento_general || 0,
      remito_compra_id:  form.remito_compra_id ? +form.remito_compra_id : null,
      observaciones:     form.observaciones || null,
      items,
    } : {
      proveedor_id:  +form.proveedor_id,
      punto_venta:   form.punto_venta.trim(),
      numero_comp:   +form.numero_comp,
      fecha:         form.fecha,
      observaciones: form.observaciones || null,
      items,
    }

    setLoading(true)
    try { await onSave(payload) }
    catch (err) { /* toast lo maneja la capa API */ }
    finally { setLoading(false) }
  }

  return (
    <Modal
      title={title}
      size="xl"
      onClose={onClose}
      footer={
        <>
          <button className="btn btn-secondary" onClick={onClose} disabled={loading}>Cancelar</button>
          <button className="btn btn-primary" onClick={save} disabled={loading}>
            {loading ? 'Guardando…' : '✓ Guardar'}
          </button>
        </>
      }
    >
      {/* Proveedor + tipo/letra */}
      <div className="form-row3" style={{ marginBottom: 14 }}>
        <div className="field" style={{ gridColumn: '1 / 3' }}>
          <label className="lbl">Proveedor *</label>
          <select className="sel" value={form.proveedor_id} onChange={e => setF({ proveedor_id: e.target.value, remito_compra_id: '' })}>
            <option value="">— Seleccionar proveedor —</option>
            {proveedores.filter(p => p.activo !== false).map(p => (
              <option key={p.id} value={p.id}>{p.razon_social} — {p.cuit}</option>
            ))}
          </select>
        </div>
        {esFactura && (
          <div className="field">
            <label className="lbl">Tipo</label>
            <select className="sel" value={form.tipo_fac} onChange={e => setF({ tipo_fac: e.target.value })}>
              <option value="A">Factura A</option>
              <option value="B">Factura B</option>
              <option value="C">Factura C</option>
              <option value="M">Factura M</option>
            </select>
          </div>
        )}
      </div>

      {/* Numeración del proveedor + fechas */}
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
          <label className="lbl">Fecha emisión *</label>
          <input type="date" className="inp" value={form.fecha} onChange={e => setF({ fecha: e.target.value })} />
        </div>
      </div>

      {esFactura && (
        <div className="form-row3" style={{ marginBottom: 14 }}>
          <div className="field">
            <label className="lbl">Fecha recepción</label>
            <input type="date" className="inp" value={form.fecha_recepcion} onChange={e => setF({ fecha_recepcion: e.target.value })} />
          </div>
          <div className="field">
            <label className="lbl">CAE (del proveedor)</label>
            <input className="inp" value={form.cae} onChange={e => setF({ cae: e.target.value })} />
          </div>
          <div className="field">
            <label className="lbl">Descuento general (%)</label>
            <input type="number" className="inp inp-right" min="0" max="100" value={form.descuento_general} onChange={e => setF({ descuento_general: +e.target.value || 0 })} />
          </div>
        </div>
      )}

      {/* Remito vinculado (solo factura) */}
      {esFactura && remitos.length > 0 && (
        <div className="field" style={{ marginBottom: 14 }}>
          <label className="lbl">Remito de compra pendiente (opcional)</label>
          <select className="sel" value={form.remito_compra_id || ''} onChange={e => onRemitoChange(e.target.value)}>
            <option value="">— Sin remito vinculado —</option>
            {remitos.map(r => (
              <option key={r.id} value={r.id}>{r.numero} — {r.items?.length || 0} ítem(s)</option>
            ))}
          </select>
        </div>
      )}

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
              {esFactura && <th style={{ width: 95 }}>IVA</th>}
              <th className="th-right" style={{ width: 110 }}>Subtotal</th>
              <th style={{ width: 34 }}></th>
            </tr>
          </thead>
          <tbody>
            {form.items.length === 0 ? (
              <tr><td colSpan={esFactura ? 8 : 7} className="empty-state">Sin ítems</td></tr>
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
                {esFactura && (
                  <td>
                    <select className="inp inp-sm sel" value={it.alicuota_iva_id || ''} onChange={e => updItem(i, 'alicuota_iva_id', +e.target.value)}>
                      {alicuotas.map(a => <option key={a.id} value={a.id}>{a.porcentaje}%</option>)}
                    </select>
                  </td>
                )}
                <td className="td-right td-bold">{$ar(calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item))}</td>
                <td style={{ textAlign: 'center' }}>
                  <button onClick={() => removeItem(i)} style={{ background: 'none', border: 'none', cursor: 'pointer', color: 'var(--red-500)', fontSize: 19, lineHeight: 1, padding: 0 }}>×</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="field" style={{ marginTop: 12 }}>
        <label className="lbl">Observaciones</label>
        <input className="inp" value={form.observaciones || ''} onChange={e => setF({ observaciones: e.target.value })} />
      </div>

      {esFactura && <TotalesBoxMulti totales={tot} />}
    </Modal>
  )
}
