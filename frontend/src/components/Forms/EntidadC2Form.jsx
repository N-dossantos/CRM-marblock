// src/components/Forms/EntidadC2Form.jsx
// ABM de cliente / proveedor de Cuenta 2 (cuenta2.md §1.1). Ambas entidades tienen la misma
// forma simplificada — nombre, descuento, teléfono, notas — así que un solo form las cubre.
// Sin CUIT ni condición de IVA: el circuito es informal.
import { useState } from 'react'
import { Modal } from '../UI'
import toast from 'react-hot-toast'

export default function EntidadC2Form({
  tipoSector,       // 'venta' | 'compra' — sólo cambia los textos
  initial = {},
  onSave,
  onClose,
}) {
  const esVenta = tipoSector === 'venta'
  const [form, setForm] = useState({
    nombre:               initial.nombre || '',
    descuento_porcentaje: initial.descuento_porcentaje ?? 0,
    telefono:             initial.telefono || '',
    notas:                initial.notas || '',
    ...(initial.activo !== undefined ? { activo: initial.activo } : {}),
  })
  const [loading, setLoading] = useState(false)

  const setF = (patch) => setForm(f => ({ ...f, ...patch }))

  const save = async () => {
    if (!form.nombre.trim()) { toast.error('Ingrese el nombre'); return }
    const dto = parseFloat(form.descuento_porcentaje) || 0
    if (dto < 0 || dto > 100) { toast.error('El descuento debe estar entre 0 y 100'); return }
    setLoading(true)
    try {
      await onSave({ ...form, nombre: form.nombre.trim(), descuento_porcentaje: dto })
    } catch {
      // El toast ya lo emitió la capa API; el modal queda abierto para corregir.
    } finally {
      setLoading(false)
    }
  }

  return (
    <Modal
      title={initial.id
        ? `Editar ${esVenta ? 'cliente' : 'proveedor'} — ${initial.nombre}`
        : `Nuevo ${esVenta ? 'cliente' : 'proveedor'} Cuenta 2`}
      size="md"
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
      <div className="field" style={{ marginBottom: 14 }}>
        <label className="lbl">Nombre *</label>
        <input className="inp" value={form.nombre} onChange={e => setF({ nombre: e.target.value })} />
      </div>

      <div className="form-row2" style={{ marginBottom: 14 }}>
        <div className="field">
          <label className="lbl">Descuento por defecto (%)</label>
          <input
            type="number" min="0" max="100" step="0.01"
            className="inp inp-right"
            value={form.descuento_porcentaje}
            onChange={e => setF({ descuento_porcentaje: e.target.value })}
          />
        </div>
        <div className="field">
          <label className="lbl">Teléfono</label>
          <input className="inp" value={form.telefono} onChange={e => setF({ telefono: e.target.value })} />
        </div>
      </div>

      <div className="field">
        <label className="lbl">Notas</label>
        <textarea className="textarea" rows={3} value={form.notas || ''}
                  onChange={e => setF({ notas: e.target.value })} />
      </div>
    </Modal>
  )
}
