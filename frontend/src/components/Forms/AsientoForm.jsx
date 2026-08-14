// src/components/Forms/AsientoForm.jsx
// Alta manual de un asiento contable (Fase E). El backend ya existe: crear_asiento valida
// server-side (≥2 líneas, cuenta imputable+activa, debe XOR haber, SUM(debe)=SUM(haber)≠0) y
// numera con siguiente_numero('asiento') — más un CONSTRAINT TRIGGER diferido de balanceo detrás.
// El chequeo de acá es PREVIEW, igual que calcTotales en ComprobanteForm: sólo evita el viaje.
// Se usa ItemsTable propia porque la línea contable (cuenta/debe/haber) no se parece a la de
// un comprobante (producto/cantidad/precio).
import { useState, useMemo } from 'react'
import { AsientosAPI } from '../../api'
import { $ar, hoy } from '../../utils'
import { Modal } from '../UI'
import toast from 'react-hot-toast'

const LINEA_BLANK = { cuenta_id: '', debe: '', haber: '', detalle: '' }

export default function AsientoForm({ cuentas = [], onClose, onSaved }) {
  const [fecha, setFecha]             = useState(hoy())
  const [descripcion, setDescripcion] = useState('')
  const [lineas, setLineas]           = useState([{ ...LINEA_BLANK }, { ...LINEA_BLANK }])
  const [saving, setSaving]           = useState(false)

  const updLinea = (i, campo, val) => setLineas(ls => ls.map((l, idx) => {
    if (idx !== i) return l
    // debe y haber son excluyentes por línea (chk_debe_xor_haber): cargar uno limpia el otro.
    if (campo === 'debe'  && val !== '') return { ...l, debe: val, haber: '' }
    if (campo === 'haber' && val !== '') return { ...l, haber: val, debe: '' }
    return { ...l, [campo]: val }
  }))

  const addLinea = ()  => setLineas(ls => [...ls, { ...LINEA_BLANK }])
  const delLinea = (i) => setLineas(ls => ls.length <= 2 ? ls : ls.filter((_, idx) => idx !== i))

  const { totalDebe, totalHaber, balancea } = useMemo(() => {
    const d = lineas.reduce((s, l) => s + (parseFloat(l.debe)  || 0), 0)
    const h = lineas.reduce((s, l) => s + (parseFloat(l.haber) || 0), 0)
    return {
      totalDebe: d,
      totalHaber: h,
      balancea: d > 0 && Math.round(d * 100) === Math.round(h * 100),
    }
  }, [lineas])

  const diferencia = totalDebe - totalHaber

  const save = async () => {
    if (!fecha)                 { toast.error('La fecha es obligatoria'); return }
    if (!descripcion.trim())    { toast.error('La descripción es obligatoria'); return }

    const payload = lineas
      .filter(l => l.cuenta_id && ((parseFloat(l.debe) || 0) > 0 || (parseFloat(l.haber) || 0) > 0))
      .map((l, i) => ({
        cuenta_id: Number(l.cuenta_id),
        debe:      parseFloat(l.debe)  || 0,
        haber:     parseFloat(l.haber) || 0,
        detalle:   l.detalle?.trim() || null,
        orden:     i,
      }))

    if (payload.length < 2) { toast.error('Un asiento requiere al menos dos líneas completas'); return }
    if (!balancea)          { toast.error(`El asiento no balancea: diferencia ${$ar(diferencia)}`); return }

    setSaving(true)
    try {
      await AsientosAPI.crear({ fecha, descripcion: descripcion.trim(), lineas: payload })
      toast.success('Asiento registrado')
      onSaved?.()
      onClose?.()
    } catch { /* fail() ya toasteó */ }
    finally { setSaving(false) }
  }

  return (
    <Modal
      title="Nuevo asiento contable"
      size="lg"
      onClose={onClose}
      footer={<>
        <button className="btn btn-secondary" onClick={onClose} disabled={saving}>Cancelar</button>
        <button className="btn btn-primary" onClick={save} disabled={saving || !balancea}>✓ Registrar asiento</button>
      </>}
    >
      <div className="form-row2">
        <div className="field">
          <label className="lbl">Fecha *</label>
          <input type="date" className="inp" value={fecha} onChange={e => setFecha(e.target.value)} />
        </div>
        <div className="field">
          <label className="lbl">Descripción *</label>
          <input className="inp" value={descripcion} onChange={e => setDescripcion(e.target.value)} placeholder="Concepto del asiento" />
        </div>
      </div>

      {cuentas.length === 0 && (
        <div style={{ marginTop: 14, fontSize: 12, color: '#92400e', background: '#fffbeb', border: '1px solid #fcd34d', borderRadius: 8, padding: '8px 12px' }}>
          ⚠ No hay cuentas imputables cargadas. Cargá el plan de cuentas antes de asentar.
        </div>
      )}

      <div className="tbl-wrap" style={{ marginTop: 16, boxShadow: 'none' }}>
        <table>
          <thead>
            <tr>
              <th>Cuenta</th><th>Detalle</th>
              <th className="th-right" style={{ width: 130 }}>Debe</th>
              <th className="th-right" style={{ width: 130 }}>Haber</th>
              <th style={{ width: 40 }}></th>
            </tr>
          </thead>
          <tbody>
            {lineas.map((l, i) => (
              <tr key={i}>
                <td>
                  <select className="sel" value={l.cuenta_id} onChange={e => updLinea(i, 'cuenta_id', e.target.value)}>
                    <option value="">— Seleccionar cuenta —</option>
                    {cuentas.map(c => <option key={c.id} value={c.id}>{c.codigo} — {c.descripcion}</option>)}
                  </select>
                </td>
                <td>
                  <input className="inp" value={l.detalle} onChange={e => updLinea(i, 'detalle', e.target.value)} placeholder="Opcional" />
                </td>
                <td>
                  <input type="number" className="inp inp-right" min="0" step="0.01" value={l.debe} onChange={e => updLinea(i, 'debe', e.target.value)} />
                </td>
                <td>
                  <input type="number" className="inp inp-right" min="0" step="0.01" value={l.haber} onChange={e => updLinea(i, 'haber', e.target.value)} />
                </td>
                <td>
                  <button
                    className="btn btn-ghost btn-sm"
                    onClick={() => delLinea(i)}
                    disabled={lineas.length <= 2}
                    title={lineas.length <= 2 ? 'Un asiento requiere al menos dos líneas' : 'Quitar línea'}
                  >
                    ✕
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <button className="btn btn-secondary btn-sm" style={{ marginTop: 10 }} onClick={addLinea}>+ Agregar línea</button>

      {/* Preview de balanceo — el servidor lo vuelve a validar igual */}
      <div style={{
        marginTop: 16, padding: '12px 16px', borderRadius: 10,
        background: balancea ? '#ecfdf5' : '#fef2f2',
        border: `1px solid ${balancea ? '#a7f3d0' : '#fecaca'}`,
        display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 16,
      }}>
        <div style={{ display: 'flex', gap: 24 }}>
          <div>
            <div className="kpi-label">Total debe</div>
            <div style={{ fontSize: 17, fontWeight: 800 }}>{$ar(totalDebe)}</div>
          </div>
          <div>
            <div className="kpi-label">Total haber</div>
            <div style={{ fontSize: 17, fontWeight: 800 }}>{$ar(totalHaber)}</div>
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          {balancea
            ? <span style={{ fontWeight: 700, color: '#065f46' }}>✓ Asiento balanceado</span>
            : <>
                <div style={{ fontWeight: 700, color: '#991b1b' }}>No balancea</div>
                <div style={{ fontSize: 12, color: '#991b1b' }}>Diferencia: {$ar(diferencia)}</div>
              </>
          }
        </div>
      </div>
    </Modal>
  )
}
