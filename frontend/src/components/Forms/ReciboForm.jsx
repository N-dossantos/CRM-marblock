// src/components/Forms/ReciboForm.jsx
import { useState, useEffect } from 'react'
import { Modal, ClienteSearch } from '../UI'
import { $ar } from '../../utils'
import { FacturasAPI, ConfigAPI } from '../../api'
import toast from 'react-hot-toast'

const MEDIO_BASE = { tipo: 'efectivo', detalle: '', monto: 0, cuenta_bancaria_id: '' }

export default function ReciboForm({ clientes = [], initial = {}, onSave, onClose }) {
  const [form, setForm]            = useState({
    cliente_id: initial.cliId || '',
    facturas:   [],
    selFacs:    initial.facIds || [],
    medios:     [{ ...MEDIO_BASE, monto: initial.totalSugerido || 0 }],
    observaciones: '',
  })
  const [cuentas, setCuentas]  = useState([])
  const [loading, setLoading]  = useState(false)

  useEffect(() => {
    ConfigAPI.cuentasBancarias().then(setCuentas)
  }, [])

  // Cuando cambia el cliente, traer sus facturas pendientes + parciales.
  // Las dos listas se resuelven juntas y se mergean en un solo setForm: dos .then() sueltos
  // se pisan entre sí (gana el último en llegar) y no hay forma de mergear sin un updater,
  // que acá no aplica porque `facturas` es una clave del objeto, no el estado entero.
  useEffect(() => {
    if (!form.cliente_id) { setForm(f => ({ ...f, facturas: [] })); return }
    Promise.all([
      FacturasAPI.list({ cliente_id: form.cliente_id, estado: 'pendiente' }),
      FacturasAPI.list({ cliente_id: form.cliente_id, estado: 'parcial' }),
    ]).then(([pend, parc]) => {
      const ids = new Set(pend.map(r => r.id))
      setForm(f => ({ ...f, facturas: [...pend, ...parc.filter(r => !ids.has(r.id))] }))
    })
  }, [form.cliente_id])

  const toggleFac = (id) => {
    const next = form.selFacs.includes(id)
      ? form.selFacs.filter(x => x !== id)
      : [...form.selFacs, id]
    setForm(f => ({ ...f, selFacs: next }))
  }

  const addMedio = () =>
    setForm(f => ({ ...f, medios: [...f.medios, { ...MEDIO_BASE }] }))

  const removeMedio = (i) =>
    setForm(f => ({ ...f, medios: f.medios.filter((_, idx) => idx !== i) }))

  const updateMedio = (i, field, val) =>
    setForm(f => ({
      ...f,
      medios: f.medios.map((m, idx) => {
        if (idx !== i) return m
        const next = { ...m, [field]: field === 'monto' ? parseFloat(val) || 0 : val }
        // Al pasar a cheque/echeq, la cuenta no aplica (esos van a cartera).
        if (field === 'tipo' && (val === 'cheque' || val === 'echeq')) {
          next.cuenta_bancaria_id = ''
          next.detalle = ''
        }
        return next
      }),
    }))

  // Selecciona la cuenta del ledger para un medio efectivo/transferencia.
  // Guarda cuenta_bancaria_id (lo que crear_recibo lee para emitir la COBRANZA en tesorería)
  // y refleja la descripción en detalle para el listado/detalle del recibo.
  const setMedioCuenta = (i, cuentaId) =>
    setForm(f => ({
      ...f,
      medios: f.medios.map((m, idx) => {
        if (idx !== i) return m
        const cta = cuentas.find(c => String(c.id) === String(cuentaId))
        return { ...m, cuenta_bancaria_id: cuentaId || '', detalle: cta ? cta.descripcion : '' }
      }),
    }))

  const totalMedios = form.medios.reduce((a, m) => a + (m.monto || 0), 0)

  const save = async () => {
    if (!form.cliente_id)    { toast.error('Seleccione un cliente'); return }
    if (!form.medios.length) { toast.error('Agregue al menos un medio de pago'); return }
    if (totalMedios <= 0)    { toast.error('El total debe ser mayor a cero'); return }

    setLoading(true)
    try {
      await onSave({
        cliente_id:   +form.cliente_id,
        factura_ids:  form.selFacs,
        medios:       form.medios,
        observaciones: form.observaciones,
      })
    } finally {
      setLoading(false)
    }
  }

  return (
    <Modal
      title="Nuevo Recibo de Cobro"
      size="lg"
      onClose={onClose}
      footer={
        <>
          <button className="btn btn-secondary" onClick={onClose} disabled={loading}>Cancelar</button>
          <button className="btn btn-success" onClick={save} disabled={loading}>
            {loading ? 'Guardando…' : '✓ Registrar cobro'}
          </button>
        </>
      }
    >
      {/* Cliente */}
      <div className="field">
        <label className="lbl">Cliente *</label>
        <ClienteSearch
          clientes={clientes}
          value={form.cliente_id}
          onChange={cliId => setForm(f => ({ ...f, cliente_id: cliId, selFacs: [], facturas: [] }))}
        />
      </div>

      {/* Facturas a imputar */}
      {form.facturas.length > 0 && (
        <div className="field">
          <label className="lbl">Facturas a imputar (opcional — puede ser pago a cuenta)</label>
          <div style={{ border: '1px solid var(--gray-200)', borderRadius: 8, overflow: 'hidden' }}>
            {form.facturas.map(f => (
              <label key={f.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 14px', borderBottom: '1px solid var(--gray-100)', cursor: 'pointer' }}>
                <input type="checkbox" checked={form.selFacs.includes(f.id)} onChange={() => toggleFac(f.id)} />
                <span className="code">{f.numero}</span>
                <span style={{ color: 'var(--gray-500)', fontSize: 12 }}>{new Date(f.fecha + 'T12:00:00').toLocaleDateString('es-AR')}</span>
                <span style={{ marginLeft: 'auto', fontWeight: 700 }}>{$ar(f.total)}</span>
                <span className={`badge badge-${f.estado}`}>{f.estado === 'parcial' ? 'Parcial' : 'Pendiente'}</span>
              </label>
            ))}
          </div>
        </div>
      )}

      {!form.cliente_id && (
        <div className="info-box">Seleccione un cliente para ver sus facturas pendientes.</div>
      )}
      {form.cliente_id && form.facturas.length === 0 && (
        <div className="info-box">Este cliente no tiene facturas pendientes. Se registrará como pago a cuenta.</div>
      )}

      {/* Medios de pago */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', margin: '16px 0 10px' }}>
        <span className="lbl" style={{ margin: 0 }}>Medios de pago</span>
        <button className="btn btn-secondary btn-sm" onClick={addMedio}>+ Agregar</button>
      </div>

      {form.medios.map((m, i) => (
        <MedioCard key={i} medio={m} index={i} cuentas={cuentas} onChange={updateMedio} onCuenta={setMedioCuenta} onRemove={removeMedio} />
      ))}

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 0', borderTop: '2px solid var(--gray-200)', marginTop: 4 }}>
        <span style={{ fontWeight: 700 }}>Total cobrado:</span>
        <span style={{ fontSize: 20, fontWeight: 800, color: 'var(--blue-600)' }}>{$ar(totalMedios)}</span>
      </div>

      <div className="field" style={{ marginTop: 12 }}>
        <label className="lbl">Observaciones</label>
        <input className="inp" value={form.observaciones} onChange={e => setForm(f => ({ ...f, observaciones: e.target.value }))} />
      </div>
    </Modal>
  )
}

function MedioCard({ medio, index, cuentas, onChange, onCuenta, onRemove }) {
  const esCuenta = medio.tipo === 'efectivo' || medio.tipo === 'transferencia'
  return (
    <div className="medio-card">
      <div className="form-row3" style={{ marginBottom: 10 }}>
        <div className="field">
          <label className="lbl">Tipo</label>
          <select className="sel" value={medio.tipo} onChange={e => onChange(index, 'tipo', e.target.value)}>
            <option value="efectivo">Efectivo (Caja)</option>
            <option value="transferencia">Transferencia</option>
            <option value="cheque">Cheque físico</option>
            <option value="echeq">E-Cheq</option>
          </select>
        </div>

        {esCuenta && (
          <div className="field">
            <label className="lbl">{medio.tipo === 'efectivo' ? 'Caja (opcional)' : 'Cuenta bancaria'}</label>
            <select className="sel" value={medio.cuenta_bancaria_id || ''} onChange={e => onCuenta(index, e.target.value)}>
              <option value="">{medio.tipo === 'efectivo' ? '— Sin impacto en tesorería —' : '— Seleccionar —'}</option>
              {cuentas.map(c => <option key={c.id} value={c.id}>{c.descripcion}</option>)}
            </select>
            <div style={{ fontSize: 11, color: medio.cuenta_bancaria_id ? '#10b981' : 'var(--gray-500)', marginTop: 3 }}>
              {medio.cuenta_bancaria_id ? '✓ Registra el cobro en tesorería' : 'Sin cuenta: no impacta el saldo de tesorería'}
            </div>
          </div>
        )}

        {(medio.tipo === 'cheque' || medio.tipo === 'echeq') && (
          <div className="field">
            <label className="lbl">Nro. cheque</label>
            <input className="inp" value={medio.numero_cheque || ''} onChange={e => onChange(index, 'numero_cheque', e.target.value)} />
          </div>
        )}

        <div className="field">
          <label className="lbl">Monto $</label>
          <input type="number" className="inp inp-right" value={medio.monto} min="0" step="0.01" onChange={e => onChange(index, 'monto', e.target.value)} />
        </div>
      </div>

      {(medio.tipo === 'cheque' || medio.tipo === 'echeq') && (
        <div className="form-row3">
          <div className="field">
            <label className="lbl">Banco</label>
            <input className="inp" value={medio.banco || ''} onChange={e => onChange(index, 'banco', e.target.value)} />
          </div>
          <div className="field">
            <label className="lbl">Titular (opcional)</label>
            <input className="inp" value={medio.titular || ''} onChange={e => onChange(index, 'titular', e.target.value)} />
          </div>
          <div className="field">
            <label className="lbl">Vencimiento</label>
            <input type="date" className="inp" value={medio.fecha_vcto || ''} onChange={e => onChange(index, 'fecha_vcto', e.target.value)} />
          </div>
        </div>
      )}

      {index > 0 && (
        <div style={{ textAlign: 'right' }}>
          <button className="btn btn-danger btn-xs" onClick={() => onRemove(index)}>Quitar</button>
        </div>
      )}
    </div>
  )
}
