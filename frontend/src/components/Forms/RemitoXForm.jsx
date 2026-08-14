// src/components/Forms/RemitoXForm.jsx
// Remito X de Cuenta 2 — único comprobante del circuito informal (cuenta2.md §1.3).
// Un solo formulario sirve venta y compra vía `tipoSector`, igual que ComprobanteForm sirve
// presupuesto/remito/factura vía `tipo`. Dos diferencias con el circuito oficial:
//   * el número lo tipea el usuario (talonario de papel, sin punto de venta fiscal);
//   * no hay IVA — TotalesBoxC2 en lugar de TotalesBox, e ItemsTable sin `alicuotas`.
import { useState } from 'react'
import { ItemsTable, TotalesBoxC2, Modal } from '../UI'
import { hoy } from '../../utils'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0 }

export default function RemitoXForm({
  title,
  tipoSector,        // 'venta' | 'compra'
  initial = {},
  entidades = [],    // clientes_cuenta2 o proveedores_cuenta2 según el sector
  productos = [],
  onSave,
  onClose,
}) {
  const esVenta = tipoSector === 'venta'
  const [form, setForm] = useState({
    entidad_id:        initial.entidad_id || '',
    numero:            initial.numero || '',
    fecha:             initial.fecha || hoy(),
    descuento_general: initial.descuento_porcentaje ?? 0,
    items:             initial.items?.map(it => ({ ...it })) || [],
    observaciones:     initial.observaciones || '',
  })
  const [loading, setLoading] = useState(false)

  // Auto-aplicar el descuento de la entidad al seleccionarla (mismo criterio que onCliChange).
  const onEntidadChange = (id) => {
    const e = entidades.find(x => x.id === +id)
    setForm(f => ({
      ...f,
      entidad_id: id,
      descuento_general: e?.descuento_porcentaje ?? f.descuento_general,
    }))
  }

  const addItem = () => setForm(f => ({ ...f, items: [...f.items, { ...ITEM_BASE }] }))

  const save = async () => {
    if (!form.entidad_id)        { toast.error(esVenta ? 'Seleccione un cliente' : 'Seleccione un proveedor'); return }
    if (!form.numero.trim())     { toast.error('Ingrese el número de remito'); return }
    if (!form.items.length)      { toast.error('Agregue al menos un ítem'); return }
    setLoading(true)
    try {
      await onSave({
        tipo_sector:       tipoSector,
        entidad_id:        +form.entidad_id,
        numero:            form.numero.trim(),
        fecha:             form.fecha,
        descuento_general: +form.descuento_general || 0,
        items:             form.items,
        observaciones:     form.observaciones || null,
      })
    } catch {
      // El toast ya lo emitió la capa API; el modal queda abierto para corregir.
    } finally {
      setLoading(false)
    }
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
      <div className="form-row3" style={{ marginBottom: 14 }}>
        <div className="field">
          <label className="lbl">{esVenta ? 'Cliente *' : 'Proveedor *'}</label>
          <select className="sel" value={form.entidad_id} onChange={e => onEntidadChange(e.target.value)}>
            <option value="">— Seleccionar —</option>
            {entidades.filter(e => e.activo !== false).map(e => (
              <option key={e.id} value={e.id}>
                {e.nombre}{+e.descuento_porcentaje > 0 ? ` — ${e.descuento_porcentaje}%` : ''}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label className="lbl">Número de remito *</label>
          <input
            className="inp"
            value={form.numero}
            placeholder="12345"
            onChange={e => setForm(f => ({ ...f, numero: e.target.value }))}
          />
        </div>
        <div className="field">
          <label className="lbl">Fecha *</label>
          <input
            type="date"
            className="inp"
            value={form.fecha}
            onChange={e => setForm(f => ({ ...f, fecha: e.target.value }))}
          />
        </div>
      </div>

      <div className="form-row3" style={{ marginBottom: 14 }}>
        <div className="field">
          <label className="lbl">Descuento general (%)</label>
          <input
            type="number" min="0" max="100" step="0.01"
            className="inp inp-right"
            value={form.descuento_general}
            onChange={e => setForm(f => ({ ...f, descuento_general: e.target.value }))}
          />
        </div>
        <div className="field" style={{ gridColumn: '2 / 4' }}>
          <label className="lbl">Observaciones</label>
          <input
            className="inp"
            value={form.observaciones || ''}
            onChange={e => setForm(f => ({ ...f, observaciones: e.target.value }))}
          />
        </div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
        <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px' }}>
          Ítems — precios netos, sin impuestos
        </span>
        <button className="btn btn-secondary btn-sm" onClick={addItem}>+ Agregar ítem</button>
      </div>

      {/* Sin `alicuotas`: ItemsTable oculta la columna de IVA cuando el array viene vacío. */}
      <ItemsTable
        items={form.items}
        productos={productos}
        onChange={items => setForm(f => ({ ...f, items }))}
      />

      <TotalesBoxC2 items={form.items} dtoGeneral={form.descuento_general} />
    </Modal>
  )
}
