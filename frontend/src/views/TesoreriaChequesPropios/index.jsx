// src/views/TesoreriaChequesPropios/index.jsx
// Cheques que emitimos nosotros. Ciclo: emitido → entregado → pagado / rechazado / anulado.
// Sólo impactan el saldo bancario al pasar a 'pagado' (cuando el banco los debita).
import { useState, useEffect, useCallback } from 'react'
import { ChequesPropiosAPI, CuentasBancariasAPI, ProveedoresAPI } from '../../api'
import { $ar, fFecha, hoy, addDias } from '../../utils'
import { Modal, Loading, EmptyState } from '../../components/UI'
import toast from 'react-hot-toast'

const ESTADO_OPTS = [
  { v: '',          l: 'Todos' },
  { v: 'emitido',   l: 'Emitido' },
  { v: 'entregado', l: 'Entregado' },
  { v: 'pagado',    l: 'Pagado' },
  { v: 'rechazado', l: 'Rechazado' },
  { v: 'anulado',   l: 'Anulado' },
]

const ESTADO_BADGE = {
  emitido:   { bg: 'var(--blue-100)',  fg: 'var(--blue-600)' },
  entregado: { bg: '#ede9fe',          fg: '#5b21b6' },
  pagado:    { bg: 'var(--green-100)', fg: 'var(--green-700)' },
  rechazado: { bg: 'var(--red-100)',   fg: 'var(--red-600)' },
  anulado:   { bg: 'var(--gray-100)',  fg: 'var(--gray-500)' },
}

// Transiciones válidas (espejo de actualizar_estado_cheque_propio en el backend).
const ACCIONES = {
  emitido:   [{ to: 'entregado', l: 'Entregar' }, { to: 'anulado', l: 'Anular', danger: true }],
  entregado: [{ to: 'pagado', l: 'Marcar pagado' }, { to: 'rechazado', l: 'Rechazar', danger: true }, { to: 'anulado', l: 'Anular', danger: true }],
  pagado:    [{ to: 'rechazado', l: 'Rechazar', danger: true }],
  rechazado: [],
  anulado:   [],
}

const BLANK = {
  cuenta_bancaria_id: '', numero: '', tipo: 'fisico', beneficiario: '', proveedor_id: '',
  fecha_emision: hoy(), fecha_pago: addDias(hoy(), 30), monto: '', observaciones: '',
}

export default function TesoreriaChequesPropios() {
  const [rows, setRows]       = useState([])
  const [cuentas, setCuentas] = useState([])
  const [proveedores, setProveedores] = useState([])
  const [loading, setLoading] = useState(true)
  const [filtro, setFiltro]   = useState('')
  const [modal, setModal]     = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    ChequesPropiosAPI.list({ estado: filtro }).then(setRows).finally(() => setLoading(false))
  }, [filtro])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    CuentasBancariasAPI.list({ activo: true }).then(cs => setCuentas(cs.filter(c => c.clase === 'banco')))
    ProveedoresAPI.list({ activo: true }).then(setProveedores)
  }, [])

  const upd = (k, v) => setModal(m => ({ ...m, [k]: v }))

  const save = async () => {
    const f = modal
    if (!f.cuenta_bancaria_id) { toast.error('Elegí el banco emisor'); return }
    if (!f.numero.trim())      { toast.error('Número obligatorio'); return }
    if (!f.monto || parseFloat(f.monto) <= 0) { toast.error('El monto debe ser mayor a cero'); return }
    if (!f.fecha_pago)         { toast.error('Fecha de pago obligatoria'); return }
    try {
      await ChequesPropiosAPI.create({
        ...f, cuenta_bancaria_id: Number(f.cuenta_bancaria_id),
        proveedor_id: f.proveedor_id || null,
      })
      toast.success('Cheque propio emitido'); setModal(null); load()
    } catch {}
  }

  const transicion = async (ch, to) => {
    const label = ACCIONES[ch.estado]?.find(a => a.to === to)?.l || to
    if (!confirm(`${label} — cheque ${ch.numero}?`)) return
    try {
      await ChequesPropiosAPI.cambiarEstado(ch.id, to)
      toast.success(`Cheque ${to}`)
      load()
    } catch {}
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <select className="sel" style={{ width: 170 }} value={filtro} onChange={e => setFiltro(e.target.value)}>
            {ESTADO_OPTS.map(o => <option key={o.v} value={o.v}>{o.l}</option>)}
          </select>
        </div>
        <button className="btn btn-primary" onClick={() => setModal({ ...BLANK })}>+ Emitir cheque propio</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Nro.</th><th>Tipo</th><th>Banco emisor</th><th>Beneficiario</th>
                <th className="th-right">Monto</th><th>F. emisión</th><th>F. pago</th>
                <th>Estado</th><th style={{ width: 220 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🧾" message="Sin cheques propios" /> : rows.map(ch => {
                const b = ESTADO_BADGE[ch.estado] || ESTADO_BADGE.emitido
                return (
                  <tr key={ch.id} style={{ opacity: ch.estado === 'anulado' ? 0.5 : 1 }}>
                    <td><span className="code" style={{ fontWeight: 700 }}>{ch.numero}</span></td>
                    <td><span style={{ fontSize: 11, background: ch.tipo === 'echeq' ? '#ede9fe' : 'var(--gray-100)', color: ch.tipo === 'echeq' ? '#5b21b6' : 'var(--gray-600)', padding: '2px 7px', borderRadius: 10, fontWeight: 700 }}>{ch.tipo === 'echeq' ? 'E-Cheq' : 'Físico'}</span></td>
                    <td style={{ fontSize: 12 }}>{ch.cuenta_descripcion}</td>
                    <td style={{ fontSize: 12 }}>{ch.proveedor_razon_social || ch.beneficiario || '—'}</td>
                    <td className="td-right td-bold">{$ar(ch.monto)}</td>
                    <td style={{ fontSize: 12 }}>{fFecha(ch.fecha_emision)}</td>
                    <td style={{ fontSize: 12 }}>{fFecha(ch.fecha_pago)}</td>
                    <td><span style={{ fontSize: 11, background: b.bg, color: b.fg, padding: '2px 8px', borderRadius: 10, fontWeight: 700 }}>{ch.estado}</span></td>
                    <td>
                      <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                        {(ACCIONES[ch.estado] || []).map(a => (
                          <button key={a.to} className={`btn btn-xs ${a.danger ? 'btn-danger' : 'btn-secondary'}`} onClick={() => transicion(ch, a.to)}>{a.l}</button>
                        ))}
                      </div>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>

      {modal && (
        <Modal title="Emitir cheque propio" size="md" onClose={() => setModal(null)}
          footer={<><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancelar</button><button className="btn btn-primary" onClick={save}>✓ Emitir</button></>}
        >
          <div className="form-row2">
            <div className="field">
              <label className="lbl">Banco emisor *</label>
              <select className="sel" value={modal.cuenta_bancaria_id} onChange={e => upd('cuenta_bancaria_id', e.target.value)}>
                <option value="">— Seleccionar —</option>
                {cuentas.map(c => <option key={c.id} value={c.id}>{c.descripcion}</option>)}
              </select>
            </div>
            <div className="field">
              <label className="lbl">Tipo</label>
              <select className="sel" value={modal.tipo} onChange={e => upd('tipo', e.target.value)}>
                <option value="fisico">Cheque físico</option>
                <option value="echeq">E-Cheq</option>
              </select>
            </div>
            <div className="field">
              <label className="lbl">Nro. cheque *</label>
              <input className="inp" value={modal.numero} onChange={e => upd('numero', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Monto *</label>
              <input type="number" className="inp inp-right" value={modal.monto} min="0" step="0.01" onChange={e => upd('monto', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Fecha de emisión</label>
              <input type="date" className="inp" value={modal.fecha_emision} onChange={e => upd('fecha_emision', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Fecha de pago *</label>
              <input type="date" className="inp" value={modal.fecha_pago} onChange={e => upd('fecha_pago', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Proveedor (opcional)</label>
              <select className="sel" value={modal.proveedor_id} onChange={e => upd('proveedor_id', e.target.value)}>
                <option value="">— Sin proveedor —</option>
                {proveedores.map(p => <option key={p.id} value={p.id}>{p.razon_social}</option>)}
              </select>
            </div>
            <div className="field">
              <label className="lbl">Beneficiario (texto libre)</label>
              <input className="inp" value={modal.beneficiario} onChange={e => upd('beneficiario', e.target.value)} placeholder="Si no es un proveedor" />
            </div>
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Observaciones</label>
              <input className="inp" value={modal.observaciones} onChange={e => upd('observaciones', e.target.value)} />
            </div>
          </div>
          <p style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 10 }}>
            El cheque no afecta el saldo del banco hasta que se marque «pagado» (débito real del banco).
          </p>
        </Modal>
      )}
    </div>
  )
}
