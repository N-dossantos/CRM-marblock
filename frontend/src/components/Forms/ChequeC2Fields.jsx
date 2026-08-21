// src/components/Forms/ChequeC2Fields.jsx
// Bloque de cheque de Cuenta 2 (cuenta2.md §1.6), compartido por MovimientoC2Form y RemitoXForm.
// Vive aparte porque los dos caminos excluyentes —endosar uno de la cartera C2 o dar de alta uno
// nuevo— son ~70 líneas de campos y una validación que tiene que coincidir exactamente con la que
// hace registrar_movimiento_cuenta2 del lado del server; tenerlo duplicado garantizaba que una de
// las dos copias se fuera quedando atrás.
import { hoy, addDias, $ar } from '../../utils'

export const CHEQUE_C2_BASE = {
  numero: '', tipo: 'fisico', banco: '', titular: '', cuit_titular: '',
  fecha_emision: hoy(), fecha_vcto: addDias(hoy(), 30), monto: '',
}

// Espejo cliente de las validaciones del RPC: devuelve el mensaje de error o null si está bien.
// Sirve para no mandar un request que ya sabemos que va a rebotar.
export function validarChequeC2({ origen, chequeId, cheque }) {
  if (origen === 'cartera') {
    return chequeId ? null : 'Elegí un cheque de la cartera'
  }
  if (!cheque.banco.trim() || !cheque.numero.trim()) return 'El cheque necesita banco y número'
  if (!cheque.fecha_vcto)                            return 'El cheque necesita fecha de vencimiento'
  if (!parseFloat(cheque.monto))                     return 'Ingrese el monto del cheque'
  return null
}

export default function ChequeC2Fields({
  puedeEndosar = false,   // endosar sólo aplica pagando a un proveedor: en una venta el cheque entra
  origen,                 // 'cartera' | 'nuevo'
  onOrigen,
  cartera = [],
  chequeId,
  onSelCheque,
  cheque,
  onCheque,               // (patch) => void
}) {
  return (
    <div className="medio-card">
      {puedeEndosar && (
        <div style={{ display: 'flex', gap: 18, marginBottom: 12 }}>
          <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13, cursor: 'pointer' }}>
            <input type="radio" checked={origen === 'cartera'} onChange={() => onOrigen('cartera')} />
            Endosar de cartera C2
          </label>
          <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13, cursor: 'pointer' }}>
            <input type="radio" checked={origen === 'nuevo'} onChange={() => onOrigen('nuevo')} />
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
              <input className="inp inp-sm" value={cheque.banco} onChange={e => onCheque({ banco: e.target.value })} />
            </div>
            <div className="field">
              <label className="lbl">Número *</label>
              <input className="inp inp-sm" value={cheque.numero} onChange={e => onCheque({ numero: e.target.value })} />
            </div>
            <div className="field">
              <label className="lbl">Tipo</label>
              <select className="sel inp-sm" value={cheque.tipo} onChange={e => onCheque({ tipo: e.target.value })}>
                <option value="fisico">Físico</option>
                <option value="echeq">E-Cheq</option>
              </select>
            </div>
          </div>
          <div className="form-row3" style={{ marginBottom: 10 }}>
            <div className="field">
              <label className="lbl">Monto *</label>
              <input type="number" step="0.01" className="inp inp-sm inp-right" value={cheque.monto}
                     onChange={e => onCheque({ monto: e.target.value })} />
            </div>
            <div className="field">
              <label className="lbl">Emisión</label>
              <input type="date" className="inp inp-sm" value={cheque.fecha_emision}
                     onChange={e => onCheque({ fecha_emision: e.target.value })} />
            </div>
            <div className="field">
              <label className="lbl">Vencimiento *</label>
              <input type="date" className="inp inp-sm" value={cheque.fecha_vcto}
                     onChange={e => onCheque({ fecha_vcto: e.target.value })} />
            </div>
          </div>
          <div className="form-row2">
            <div className="field">
              <label className="lbl">Titular</label>
              <input className="inp inp-sm" value={cheque.titular} onChange={e => onCheque({ titular: e.target.value })} />
            </div>
            <div className="field">
              <label className="lbl">CUIT titular</label>
              <input className="inp inp-sm" value={cheque.cuit_titular} onChange={e => onCheque({ cuit_titular: e.target.value })} />
            </div>
          </div>
        </>
      )}
    </div>
  )
}
