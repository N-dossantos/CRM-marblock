// src/components/Forms/TransferenciaForm.jsx
// Alta de una TRANSFERENCIA entre cuentas de tesorería (Fase D). El backend ya existe: la RPC
// crear_transferencia (Fase C) inserta el par débito/crédito atómico. Acá sólo se le pone pantalla:
// cuenta origen, cuenta destino (≠ origen), monto, fecha, concepto, con preview del efecto en ambos
// saldos. Los saldos actuales salen de informe_saldos_tesoreria (CuentasBancariasAPI.saldos), sin
// backend nuevo. Llama MovimientosTesoreriaAPI.transferencia.
import { useState, useEffect, useMemo } from 'react'
import { MovimientosTesoreriaAPI, CuentasBancariasAPI } from '../../api'
import { $ar, hoy } from '../../utils'
import { Modal } from '../UI'
import toast from 'react-hot-toast'

const BLANK = { cuenta_origen_id: '', cuenta_destino_id: '', monto: '', fecha: hoy(), concepto: '' }

export default function TransferenciaForm({ cuentas = [], onClose, onSaved }) {
  const [form, setForm]     = useState({ ...BLANK })
  const [saldos, setSaldos] = useState({})  // id -> saldo_actual
  const [saving, setSaving] = useState(false)

  // Saldos actuales por cuenta para el preview (informe_saldos_tesoreria).
  useEffect(() => {
    CuentasBancariasAPI.saldos().then(res => {
      const map = {}
      for (const g of (res?.agrupaciones || [])) {
        for (const c of (g.cuentas || [])) map[c.id] = Number(c.saldo_actual)
      }
      setSaldos(map)
    }).catch(() => {})
  }, [])

  const upd = (k, v) => setForm(f => ({ ...f, [k]: v }))

  const monto  = parseFloat(form.monto) || 0
  const oId    = form.cuenta_origen_id ? Number(form.cuenta_origen_id) : null
  const dId    = form.cuenta_destino_id ? Number(form.cuenta_destino_id) : null

  const preview = useMemo(() => {
    if (!oId || !dId || oId === dId || monto <= 0) return null
    const so = saldos[oId] ?? 0
    const sd = saldos[dId] ?? 0
    return { so, sd, soNew: so - monto, sdNew: sd + monto }
  }, [oId, dId, monto, saldos])

  // El destino no puede ser la cuenta origen.
  const destinos = cuentas.filter(c => String(c.id) !== String(form.cuenta_origen_id))

  const save = async () => {
    if (!oId)                  { toast.error('Elegí la cuenta origen'); return }
    if (!dId)                  { toast.error('Elegí la cuenta destino'); return }
    if (oId === dId)           { toast.error('Origen y destino deben ser distintas'); return }
    if (monto <= 0)            { toast.error('El monto debe ser mayor a cero'); return }
    setSaving(true)
    try {
      await MovimientosTesoreriaAPI.transferencia({
        cuenta_origen_id:  oId,
        cuenta_destino_id: dId,
        monto,
        fecha:    form.fecha || null,
        concepto: form.concepto || null,
      })
      toast.success('Transferencia registrada')
      onSaved?.()
      onClose?.()
    } catch { /* fail() ya toasteó */ }
    finally { setSaving(false) }
  }

  const nombre = (id) => cuentas.find(c => String(c.id) === String(id))?.descripcion || '—'

  return (
    <Modal
      title="Nueva transferencia entre cuentas"
      size="md"
      onClose={onClose}
      footer={<>
        <button className="btn btn-secondary" onClick={onClose} disabled={saving}>Cancelar</button>
        <button className="btn btn-primary" onClick={save} disabled={saving}>✓ Transferir</button>
      </>}
    >
      <div className="form-row2">
        <div className="field">
          <label className="lbl">Cuenta origen *</label>
          <select className="sel" value={form.cuenta_origen_id} onChange={e => {
            const v = e.target.value
            setForm(f => ({ ...f, cuenta_origen_id: v, cuenta_destino_id: f.cuenta_destino_id === v ? '' : f.cuenta_destino_id }))
          }}>
            <option value="">— Seleccionar —</option>
            {cuentas.map(c => <option key={c.id} value={c.id}>{c.descripcion}</option>)}
          </select>
        </div>
        <div className="field">
          <label className="lbl">Cuenta destino *</label>
          <select className="sel" value={form.cuenta_destino_id} onChange={e => upd('cuenta_destino_id', e.target.value)}>
            <option value="">— Seleccionar —</option>
            {destinos.map(c => <option key={c.id} value={c.id}>{c.descripcion}</option>)}
          </select>
        </div>
        <div className="field">
          <label className="lbl">Monto *</label>
          <input type="number" className="inp inp-right" value={form.monto} min="0" step="0.01" onChange={e => upd('monto', e.target.value)} />
        </div>
        <div className="field">
          <label className="lbl">Fecha</label>
          <input type="date" className="inp" value={form.fecha} onChange={e => upd('fecha', e.target.value)} />
        </div>
        <div className="field" style={{ gridColumn: '1 / 3' }}>
          <label className="lbl">Concepto</label>
          <input className="inp" value={form.concepto} onChange={e => upd('concepto', e.target.value)} placeholder="Detalle de la transferencia" />
        </div>
      </div>

      {/* Preview del efecto en ambos saldos */}
      {preview && (
        <div style={{ marginTop: 16, display: 'grid', gridTemplateColumns: '1fr auto 1fr', gap: 12, alignItems: 'center' }}>
          <div style={{ background: '#fef2f2', border: '1px solid #fecaca', borderRadius: 10, padding: '12px 14px' }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: '#991b1b', textTransform: 'uppercase' }}>Origen · {nombre(oId)}</div>
            <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 4 }}>Actual: {$ar(preview.so)}</div>
            <div style={{ fontSize: 17, fontWeight: 800, color: preview.soNew < 0 ? 'var(--red-500)' : 'var(--gray-800)', marginTop: 2 }}>→ {$ar(preview.soNew)}</div>
          </div>
          <div style={{ fontSize: 22, color: 'var(--blue-600)' }}>⇄</div>
          <div style={{ background: '#ecfdf5', border: '1px solid #a7f3d0', borderRadius: 10, padding: '12px 14px' }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: '#065f46', textTransform: 'uppercase' }}>Destino · {nombre(dId)}</div>
            <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 4 }}>Actual: {$ar(preview.sd)}</div>
            <div style={{ fontSize: 17, fontWeight: 800, color: '#10b981', marginTop: 2 }}>→ {$ar(preview.sdNew)}</div>
          </div>
        </div>
      )}
      {preview && preview.soNew < 0 && (
        <div style={{ marginTop: 10, fontSize: 12, color: '#92400e', background: '#fffbeb', border: '1px solid #fcd34d', borderRadius: 8, padding: '8px 12px' }}>
          ⚠ La cuenta origen quedará con saldo negativo.
        </div>
      )}
    </Modal>
  )
}
