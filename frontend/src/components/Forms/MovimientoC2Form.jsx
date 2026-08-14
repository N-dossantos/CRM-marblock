// src/components/Forms/MovimientoC2Form.jsx
// Cobro / Pago / Ajuste de Cuenta 2 (cuenta2.md §1.5). No se emite comprobante: el movimiento
// impacta el saldo de cta. cte. directo. Un solo formulario para ambos sectores vía `tipoSector`.
// Con medio = cheque hay dos caminos excluyentes (§1.6):
//   * endosar un cheque que ya está en la cartera C2 (sólo en pagos a proveedor);
//   * dar de alta un cheque nuevo.
import { useEffect, useState } from 'react'
import { Modal } from '../UI'
import { ChequesC2API } from '../../api/cuenta2'
import { $ar, hoy, addDias } from '../../utils'
import toast from 'react-hot-toast'

const MEDIOS = [
  { v: 'efectivo',      l: '💵 Efectivo' },
  { v: 'transferencia', l: '🏦 Transferencia' },
  { v: 'cheque',        l: '🧾 Cheque' },
]

const CHEQUE_BASE = {
  numero: '', tipo: 'fisico', banco: '', titular: '', cuit_titular: '',
  fecha_emision: hoy(), fecha_vcto: addDias(hoy(), 30), monto: '',
}

export default function MovimientoC2Form({
  tipoSector,        // 'venta' | 'compra'
  entidad,           // { id, nombre }
  saldo = 0,
  onSave,
  onClose,
}) {
  const esVenta = tipoSector === 'venta'
  const tipoDefault = esVenta ? 'COBRO' : 'PAGO'

  const [form, setForm] = useState({
    tipo:      tipoDefault,
    monto:     saldo > 0 ? String(saldo) : '',
    fecha:     hoy(),
    medio:     'efectivo',
    concepto:  '',
  })
  // origen del cheque: 'cartera' (endoso) | 'nuevo'
  const [origen, setOrigen]   = useState('nuevo')
  const [chequeId, setChequeId] = useState('')
  const [cheque, setCheque]   = useState({ ...CHEQUE_BASE })
  const [cartera, setCartera] = useState([])
  const [loading, setLoading] = useState(false)

  const esAjuste  = form.tipo === 'AJUSTE'
  // Endosar sólo tiene sentido pagando a un proveedor: en una venta el cheque entra, no sale.
  const puedeEndosar = !esVenta && form.tipo === 'PAGO'

  useEffect(() => {
    if (!puedeEndosar) { setOrigen('nuevo'); return }
    ChequesC2API.list({ estado: 'en_cartera' }).then(setCartera).catch(() => {})
  }, [puedeEndosar])

  const setF = (patch) => setForm(f => ({ ...f, ...patch }))
  const setC = (patch) => setCheque(c => ({ ...c, ...patch }))

  // Al elegir un cheque de cartera, el monto del movimiento lo fija el cheque.
  const onSelCheque = (id) => {
    setChequeId(id)
    const ch = cartera.find(c => c.id === +id)
    if (ch) setF({ monto: String(ch.monto) })
  }

  const save = async () => {
    const monto = parseFloat(form.monto)
    if (!monto)                    { toast.error('Ingrese un monto'); return }
    if (!esAjuste && monto <= 0)   { toast.error('El monto debe ser mayor a cero'); return }
    if (form.medio === 'cheque' && !esAjuste) {
      if (origen === 'cartera' && !chequeId) { toast.error('Elegí un cheque de la cartera'); return }
      if (origen === 'nuevo') {
        if (!cheque.banco.trim() || !cheque.numero.trim()) { toast.error('El cheque necesita banco y número'); return }
        if (!cheque.fecha_vcto)                            { toast.error('El cheque necesita fecha de vencimiento'); return }
        if (!parseFloat(cheque.monto))                     { toast.error('Ingrese el monto del cheque'); return }
      }
    }

    setLoading(true)
    try {
      await onSave({
        tipo_sector: tipoSector,
        entidad_id:  entidad.id,
        tipo:        form.tipo,
        monto,
        fecha:       form.fecha,
        medio:       esAjuste ? null : form.medio,
        concepto:    form.concepto || null,
        cheque:      (!esAjuste && form.medio === 'cheque' && origen === 'nuevo')
                       ? { ...cheque, monto: parseFloat(cheque.monto) } : null,
        cheque_id:   (!esAjuste && form.medio === 'cheque' && origen === 'cartera')
                       ? +chequeId : null,
      })
    } catch {
      // El toast ya lo emitió la capa API; el modal queda abierto para corregir.
    } finally {
      setLoading(false)
    }
  }

  return (
    <Modal
      title={`${esVenta ? 'Cobro' : 'Pago'} — ${entidad.nombre}`}
      size="md"
      onClose={onClose}
      footer={
        <>
          <button className="btn btn-secondary" onClick={onClose} disabled={loading}>Cancelar</button>
          <button className="btn btn-primary" onClick={save} disabled={loading}>
            {loading ? 'Guardando…' : '✓ Registrar'}
          </button>
        </>
      }
    >
      <div className="info-box" style={{ marginBottom: 14 }}>
        <span>Saldo actual: <strong>{$ar(saldo)}</strong></span>
      </div>

      <div className="form-row3" style={{ marginBottom: 14 }}>
        <div className="field">
          <label className="lbl">Tipo</label>
          <select className="sel" value={form.tipo} onChange={e => setF({ tipo: e.target.value })}>
            <option value={tipoDefault}>{esVenta ? 'Cobro' : 'Pago'}</option>
            <option value="AJUSTE">Ajuste</option>
          </select>
        </div>
        <div className="field">
          <label className="lbl">Fecha</label>
          <input type="date" className="inp" value={form.fecha} onChange={e => setF({ fecha: e.target.value })} />
        </div>
        <div className="field">
          <label className="lbl">Monto *</label>
          <input
            type="number" step="0.01"
            className="inp inp-right"
            value={form.monto}
            disabled={form.medio === 'cheque' && origen === 'cartera' && !esAjuste}
            onChange={e => setF({ monto: e.target.value })}
          />
        </div>
      </div>

      {esAjuste ? (
        <div className="info-box" style={{ marginBottom: 14 }}>
          <span>
            Monto <strong>positivo</strong> aumenta la deuda (Debe); <strong>negativo</strong> la reduce (Haber).
            Sirve para cargar el saldo inicial.
          </span>
        </div>
      ) : (
        <div className="field" style={{ marginBottom: 14 }}>
          <label className="lbl">Medio de pago</label>
          <select className="sel" value={form.medio} onChange={e => setF({ medio: e.target.value })}>
            {MEDIOS.map(m => <option key={m.v} value={m.v}>{m.l}</option>)}
          </select>
        </div>
      )}

      {!esAjuste && form.medio === 'cheque' && (
        <div className="medio-card">
          {puedeEndosar && (
            <div style={{ display: 'flex', gap: 18, marginBottom: 12 }}>
              <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13, cursor: 'pointer' }}>
                <input type="radio" checked={origen === 'cartera'} onChange={() => setOrigen('cartera')} />
                Endosar de cartera C2
              </label>
              <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13, cursor: 'pointer' }}>
                <input type="radio" checked={origen === 'nuevo'} onChange={() => setOrigen('nuevo')} />
                Cargar cheque nuevo
              </label>
            </div>
          )}

          {origen === 'cartera' ? (
            <div className="field">
              <label className="lbl">Cheque en cartera Cuenta 2</label>
              <select className="sel" value={chequeId} onChange={e => onSelCheque(e.target.value)}>
                <option value="">— Seleccionar cheque —</option>
                {cartera.map(c => (
                  <option key={c.id} value={c.id}>
                    {c.banco} {c.numero} — {$ar(c.monto)} — vto. {c.fecha_vcto}
                  </option>
                ))}
              </select>
              {cartera.length === 0 && (
                <span style={{ fontSize: 11, color: 'var(--gray-500)' }}>No hay cheques en la cartera Cuenta 2.</span>
              )}
            </div>
          ) : (
            <>
              <div className="form-row3" style={{ marginBottom: 10 }}>
                <div className="field">
                  <label className="lbl">Banco *</label>
                  <input className="inp inp-sm" value={cheque.banco} onChange={e => setC({ banco: e.target.value })} />
                </div>
                <div className="field">
                  <label className="lbl">Número *</label>
                  <input className="inp inp-sm" value={cheque.numero} onChange={e => setC({ numero: e.target.value })} />
                </div>
                <div className="field">
                  <label className="lbl">Tipo</label>
                  <select className="sel inp-sm" value={cheque.tipo} onChange={e => setC({ tipo: e.target.value })}>
                    <option value="fisico">Físico</option>
                    <option value="echeq">E-Cheq</option>
                  </select>
                </div>
              </div>
              <div className="form-row3" style={{ marginBottom: 10 }}>
                <div className="field">
                  <label className="lbl">Monto *</label>
                  <input type="number" step="0.01" className="inp inp-sm inp-right" value={cheque.monto}
                         onChange={e => setC({ monto: e.target.value })} />
                </div>
                <div className="field">
                  <label className="lbl">Emisión</label>
                  <input type="date" className="inp inp-sm" value={cheque.fecha_emision}
                         onChange={e => setC({ fecha_emision: e.target.value })} />
                </div>
                <div className="field">
                  <label className="lbl">Vencimiento *</label>
                  <input type="date" className="inp inp-sm" value={cheque.fecha_vcto}
                         onChange={e => setC({ fecha_vcto: e.target.value })} />
                </div>
              </div>
              <div className="form-row2">
                <div className="field">
                  <label className="lbl">Titular</label>
                  <input className="inp inp-sm" value={cheque.titular} onChange={e => setC({ titular: e.target.value })} />
                </div>
                <div className="field">
                  <label className="lbl">CUIT titular</label>
                  <input className="inp inp-sm" value={cheque.cuit_titular} onChange={e => setC({ cuit_titular: e.target.value })} />
                </div>
              </div>
            </>
          )}
        </div>
      )}

      <div className="field" style={{ marginTop: 14 }}>
        <label className="lbl">Concepto</label>
        <input className="inp" value={form.concepto} placeholder="Opcional"
               onChange={e => setF({ concepto: e.target.value })} />
      </div>
    </Modal>
  )
}
