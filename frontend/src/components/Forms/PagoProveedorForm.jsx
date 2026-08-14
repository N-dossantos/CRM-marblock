// src/components/Forms/PagoProveedorForm.jsx
// "Ingreso de pago" a proveedor: dinero que SALE (espejo de ReciboForm en sentido contrario).
//   * medios multi-modales: efectivo / transferencia (cuenta) / cheque propio / cheque de cartera;
//   * imputa a N facturas de compra pendientes;
//   * retenciones (IVA/Ganancias/IIBB/SUSS) precargadas desde proveedor_alicuotas.
import { useState, useEffect } from 'react'
import { Modal } from '../UI'
import { $ar, hoy } from '../../utils'
import { ConfigAPI, FacturasCompraAPI, ProveedoresAPI, ChequesAPI } from '../../api'
import toast from 'react-hot-toast'

const MEDIO_BASE = { tipo: 'efectivo', detalle: '', cuenta_bancaria_id: '', cheque_id: '', monto: 0 }

export default function PagoProveedorForm({ proveedores = [], initial = {}, onSave, onClose }) {
  const [form, setForm] = useState({
    proveedor_id:  initial.provId || '',
    fecha:         hoy(),
    facturas:      [],
    selFacs:       initial.facIds || [],
    medios:        [{ ...MEDIO_BASE, monto: initial.totalSugerido || 0 }],
    retenciones:   [],
    observaciones: '',
  })
  const [cuentas, setCuentas]   = useState([])
  const [cartera, setCartera]   = useState([])   // cheques de terceros en cartera
  const [loading, setLoading]   = useState(false)

  useEffect(() => {
    ConfigAPI.cuentasBancarias().then(setCuentas).catch(() => {})
    ChequesAPI.list({ estado: 'en_cartera' }).then(setCartera).catch(() => {})
  }, [])

  // Al cambiar proveedor: facturas pendientes + prellenar retenciones desde sus alícuotas.
  useEffect(() => {
    if (!form.proveedor_id) { setForm(f => ({ ...f, facturas: [], retenciones: [] })); return }
    Promise.all([
      FacturasCompraAPI.list({ proveedor_id: form.proveedor_id, estado: 'pendiente' }),
      FacturasCompraAPI.list({ proveedor_id: form.proveedor_id, estado: 'parcial' }),
    ]).then(([pend, parc]) => {
      const ids = new Set(pend.map(f => f.id))
      setForm(f => ({ ...f, facturas: [...pend, ...parc.filter(x => !ids.has(x.id))] }))
    })
    ProveedoresAPI.alicuotas(form.proveedor_id).then(rows => {
      setForm(f => ({
        ...f,
        retenciones: rows.map(a => ({
          tipo_retencion: a.tipo_retencion, jurisdiccion: a.jurisdiccion || '',
          base_imponible: 0, alicuota: +a.alicuota, monto: 0,
        })),
      }))
    }).catch(() => {})
  }, [form.proveedor_id])

  const toggleFac = (id) =>
    setForm(f => ({ ...f, selFacs: f.selFacs.includes(id) ? f.selFacs.filter(x => x !== id) : [...f.selFacs, id] }))

  const addMedio    = () => setForm(f => ({ ...f, medios: [...f.medios, { ...MEDIO_BASE }] }))
  const removeMedio = (i) => setForm(f => ({ ...f, medios: f.medios.filter((_, idx) => idx !== i) }))
  const updMedio = (i, patch) =>
    setForm(f => ({ ...f, medios: f.medios.map((m, idx) => idx !== i ? m : { ...m, ...patch }) }))

  const onMedioTipo = (i, tipo) => updMedio(i, { tipo, detalle: '', cuenta_bancaria_id: '', cheque_id: '' })
  const onSelCheque = (i, chId) => {
    const ch = cartera.find(c => c.id === +chId)
    updMedio(i, { cheque_id: +chId || '', detalle: ch ? `${ch.banco} ${ch.numero}` : '', monto: ch ? +ch.monto : 0 })
  }

  const addRet    = () => setForm(f => ({ ...f, retenciones: [...f.retenciones, { tipo_retencion: 'IVA', jurisdiccion: '', base_imponible: 0, alicuota: 0, monto: 0 }] }))
  const removeRet = (i) => setForm(f => ({ ...f, retenciones: f.retenciones.filter((_, idx) => idx !== i) }))
  const updRet = (i, field, val) =>
    setForm(f => ({
      ...f,
      retenciones: f.retenciones.map((r, idx) => {
        if (idx !== i) return r
        const num = ['base_imponible', 'alicuota'].includes(field)
        const next = { ...r, [field]: num ? (parseFloat(val) || 0) : val }
        if (num) next.monto = Math.round(next.base_imponible * next.alicuota) / 100
        return next
      }),
    }))

  const totalMedios = form.medios.reduce((a, m) => a + (m.monto || 0), 0)
  const totalRet    = form.retenciones.reduce((a, r) => a + (r.monto || 0), 0)

  const save = async () => {
    if (!form.proveedor_id)  { toast.error('Seleccione un proveedor'); return }
    if (!form.medios.length) { toast.error('Agregue al menos un medio de pago'); return }
    if (totalMedios <= 0)    { toast.error('El total debe ser mayor a cero'); return }

    setLoading(true)
    try {
      await onSave({
        proveedor_id:  +form.proveedor_id,
        fecha:         form.fecha,
        factura_ids:   form.selFacs,
        medios: form.medios.map(m => ({
          tipo: m.tipo,
          detalle: m.detalle || null,
          cuenta_bancaria_id: m.cuenta_bancaria_id ? +m.cuenta_bancaria_id : null,
          cheque_id: m.cheque_id ? +m.cheque_id : null,
          monto: m.monto,
        })),
        retenciones: form.retenciones.filter(r => r.monto > 0),
        observaciones: form.observaciones || null,
      })
    } finally { setLoading(false) }
  }

  return (
    <Modal
      title="Nuevo Pago a Proveedor"
      size="lg"
      onClose={onClose}
      footer={
        <>
          <button className="btn btn-secondary" onClick={onClose} disabled={loading}>Cancelar</button>
          <button className="btn btn-primary" onClick={save} disabled={loading}>
            {loading ? 'Guardando…' : '✓ Registrar pago'}
          </button>
        </>
      }
    >
      <div className="form-row2">
        <div className="field">
          <label className="lbl">Proveedor *</label>
          <select className="sel" value={form.proveedor_id} onChange={e => setForm(f => ({ ...f, proveedor_id: e.target.value, selFacs: [] }))}>
            <option value="">— Seleccionar —</option>
            {proveedores.map(p => <option key={p.id} value={p.id}>{p.razon_social}</option>)}
          </select>
        </div>
        <div className="field">
          <label className="lbl">Fecha</label>
          <input type="date" className="inp" value={form.fecha} onChange={e => setForm(f => ({ ...f, fecha: e.target.value }))} />
        </div>
      </div>

      {/* Facturas a imputar */}
      {form.facturas.length > 0 && (
        <div className="field" style={{ marginTop: 12 }}>
          <label className="lbl">Facturas a imputar (opcional — puede ser pago a cuenta)</label>
          <div style={{ border: '1px solid var(--gray-200)', borderRadius: 8, overflow: 'hidden' }}>
            {form.facturas.map(f => (
              <label key={f.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 14px', borderBottom: '1px solid var(--gray-100)', cursor: 'pointer' }}>
                <input type="checkbox" checked={form.selFacs.includes(f.id)} onChange={() => toggleFac(f.id)} />
                <span className="code">{f.tipo} {f.numero}</span>
                <span style={{ marginLeft: 'auto', fontWeight: 700 }}>{$ar(f.total)}</span>
                <span className={`badge badge-${f.estado === 'parcial' ? 'parcial' : 'pendiente'}`}>{f.estado === 'parcial' ? 'Parcial' : 'Pendiente'}</span>
              </label>
            ))}
          </div>
        </div>
      )}
      {!form.proveedor_id && <div className="info-box">Seleccione un proveedor para ver sus facturas pendientes.</div>}
      {form.proveedor_id && form.facturas.length === 0 && (
        <div className="info-box">Este proveedor no tiene facturas pendientes. Se registrará como pago a cuenta.</div>
      )}

      {/* Medios de pago */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', margin: '16px 0 10px' }}>
        <span className="lbl" style={{ margin: 0 }}>Medios de pago</span>
        <button className="btn btn-secondary btn-sm" onClick={addMedio}>+ Agregar</button>
      </div>

      {form.medios.map((m, i) => (
        <div className="medio-card" key={i}>
          <div className="form-row3" style={{ marginBottom: 8 }}>
            <div className="field">
              <label className="lbl">Tipo</label>
              <select className="sel" value={m.tipo} onChange={e => onMedioTipo(i, e.target.value)}>
                <option value="efectivo">Efectivo (Caja)</option>
                <option value="transferencia">Transferencia</option>
                <option value="cheque_propio">Cheque propio</option>
                <option value="cheque_tercero">Cheque de cartera</option>
              </select>
            </div>

            {m.tipo === 'transferencia' && (
              <div className="field">
                <label className="lbl">Cuenta bancaria</label>
                <select className="sel" value={m.cuenta_bancaria_id || ''} onChange={e => updMedio(i, { cuenta_bancaria_id: e.target.value, detalle: (cuentas.find(c => c.id === +e.target.value)?.descripcion) || '' })}>
                  <option value="">— Seleccionar —</option>
                  {cuentas.map(c => <option key={c.id} value={c.id}>{c.descripcion}</option>)}
                </select>
              </div>
            )}

            {m.tipo === 'cheque_tercero' && (
              <div className="field">
                <label className="lbl">Cheque de cartera</label>
                <select className="sel" value={m.cheque_id || ''} onChange={e => onSelCheque(i, e.target.value)}>
                  <option value="">— Seleccionar —</option>
                  {cartera.map(ch => <option key={ch.id} value={ch.id}>{ch.banco} {ch.numero} — {$ar(ch.monto)}</option>)}
                </select>
              </div>
            )}

            {m.tipo === 'cheque_propio' && (
              <div className="field">
                <label className="lbl">Detalle (banco / nº)</label>
                <input className="inp" value={m.detalle || ''} onChange={e => updMedio(i, { detalle: e.target.value })} />
              </div>
            )}

            <div className="field">
              <label className="lbl">Monto $</label>
              <input type="number" className="inp inp-right" value={m.monto} min="0" step="0.01" disabled={m.tipo === 'cheque_tercero'} onChange={e => updMedio(i, { monto: parseFloat(e.target.value) || 0 })} />
            </div>
          </div>
          {i > 0 && <div style={{ textAlign: 'right' }}><button className="btn btn-danger btn-xs" onClick={() => removeMedio(i)}>Quitar</button></div>}
        </div>
      ))}

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 0', borderTop: '2px solid var(--gray-200)', marginTop: 4 }}>
        <span style={{ fontWeight: 700 }}>Total del pago:</span>
        <span style={{ fontSize: 20, fontWeight: 800, color: 'var(--blue-600)' }}>{$ar(totalMedios)}</span>
      </div>

      {/* Retenciones */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', margin: '16px 0 10px' }}>
        <span className="lbl" style={{ margin: 0 }}>Retenciones {totalRet > 0 && <span style={{ color: 'var(--gray-500)' }}>— total {$ar(totalRet)}</span>}</span>
        <button className="btn btn-secondary btn-sm" onClick={addRet}>+ Agregar</button>
      </div>
      {form.retenciones.length === 0 && <div className="info-box" style={{ marginBottom: 8 }}>Sin retenciones (se prellenan desde las alícuotas del proveedor).</div>}
      {form.retenciones.map((r, i) => (
        <div className="form-row3" key={i} style={{ marginBottom: 8, alignItems: 'end' }}>
          <div className="field">
            <label className="lbl">Tipo</label>
            <select className="sel" value={r.tipo_retencion} onChange={e => updRet(i, 'tipo_retencion', e.target.value)}>
              <option value="IVA">IVA</option>
              <option value="Ganancias">Ganancias</option>
              <option value="IIBB">IIBB</option>
              <option value="SUSS">SUSS</option>
            </select>
          </div>
          <div className="field">
            <label className="lbl">Base imponible</label>
            <input type="number" className="inp inp-right" value={r.base_imponible} min="0" onChange={e => updRet(i, 'base_imponible', e.target.value)} />
          </div>
          <div className="field">
            <label className="lbl">Alícuota %</label>
            <input type="number" className="inp inp-right" value={r.alicuota} min="0" step="0.01" onChange={e => updRet(i, 'alicuota', e.target.value)} />
          </div>
          <div className="field">
            <label className="lbl">Monto</label>
            <input className="inp inp-right" value={$ar(r.monto)} readOnly />
          </div>
          <div style={{ paddingBottom: 6 }}><button className="btn btn-danger btn-xs" onClick={() => removeRet(i)}>×</button></div>
        </div>
      ))}

      <div className="field" style={{ marginTop: 12 }}>
        <label className="lbl">Observaciones</label>
        <input className="inp" value={form.observaciones} onChange={e => setForm(f => ({ ...f, observaciones: e.target.value }))} />
      </div>
    </Modal>
  )
}
