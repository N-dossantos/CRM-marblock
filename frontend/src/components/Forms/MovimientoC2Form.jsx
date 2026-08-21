// src/components/Forms/MovimientoC2Form.jsx
// Cobro / Pago / Ajuste de Cuenta 2 (cuenta2.md §1.5). No se emite comprobante: el movimiento
// impacta el saldo de cta. cte. directo. Un solo formulario para ambos sectores vía `tipoSector`.
// Con medio = cheque hay dos caminos excluyentes (§1.6):
//   * endosar un cheque que ya está en la cartera C2 (sólo en pagos a proveedor);
//   * dar de alta un cheque nuevo.
import { useEffect, useState } from 'react'
import { Modal } from '../UI'
import { ChequesC2API } from '../../api/cuenta2'
import { $ar, hoy } from '../../utils'
import ChequeC2Fields, { CHEQUE_C2_BASE, validarChequeC2 } from './ChequeC2Fields'
import toast from 'react-hot-toast'

const MEDIOS = [
  { v: 'efectivo',      l: '💵 Efectivo' },
  { v: 'transferencia', l: '🏦 Transferencia' },
  { v: 'cheque',        l: '🧾 Cheque' },
]

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
  const [cheque, setCheque]   = useState({ ...CHEQUE_C2_BASE })
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
      const err = validarChequeC2({ origen, chequeId, cheque })
      if (err) { toast.error(err); return }
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
        <ChequeC2Fields
          puedeEndosar={puedeEndosar}
          origen={origen}
          onOrigen={setOrigen}
          cartera={cartera}
          chequeId={chequeId}
          onSelCheque={onSelCheque}
          cheque={cheque}
          onCheque={setC}
        />
      )}

      <div className="field" style={{ marginTop: 14 }}>
        <label className="lbl">Concepto</label>
        <input className="inp" value={form.concepto} placeholder="Opcional"
               onChange={e => setF({ concepto: e.target.value })} />
      </div>
    </Modal>
  )
}
