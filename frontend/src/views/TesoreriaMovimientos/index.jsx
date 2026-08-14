// src/views/TesoreriaMovimientos/index.jsx
// Ledger central: listado filtrable (cuenta/fecha/tipo/texto), alta manual de movimiento
// (depósito, extracción, gasto, ajuste…), transferencias entre cuentas (Fase D) y anulación.
// La transferencia usa la RPC crear_transferencia (par débito/crédito atómico) vía TransferenciaForm;
// sus dos patas aparecen en este mismo listado con el badge origen='transferencia'.
import { useState, useEffect, useCallback } from 'react'
import { MovimientosTesoreriaAPI, CuentasBancariasAPI, TiposComprobanteTesoreriaAPI } from '../../api'
import { $ar, fFecha, hoy } from '../../utils'
import { Modal, Loading, EmptyState } from '../../components/UI'
import TransferenciaForm from '../../components/Forms/TransferenciaForm'
import toast from 'react-hot-toast'

const primerDiaMes = () => { const d = new Date(); d.setDate(1); return d.toISOString().split('T')[0] }

const BLANK = { cuenta_bancaria_id: '', tipo_id: '', signo: -1, monto: '', fecha: hoy(), concepto: '' }

export default function TesoreriaMovimientos() {
  const [rows, setRows]     = useState([])
  const [cuentas, setCuentas] = useState([])
  const [tipos, setTipos]   = useState([])
  const [loading, setLoading] = useState(true)
  const [f, setF]           = useState({ cuenta_id: '', desde: primerDiaMes(), hasta: hoy(), tipo_id: '', q: '' })
  const [modal, setModal]   = useState(null)
  const [transfer, setTransfer] = useState(false)

  const load = useCallback(() => {
    setLoading(true)
    MovimientosTesoreriaAPI.list({
      cuenta_id: f.cuenta_id || undefined, desde: f.desde || undefined, hasta: f.hasta || undefined,
      tipo_id: f.tipo_id || undefined, q: f.q || undefined,
    }).then(setRows).finally(() => setLoading(false))
  }, [f])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    CuentasBancariasAPI.list({ activo: true }).then(setCuentas)
    TiposComprobanteTesoreriaAPI.list().then(ts => setTipos(ts.filter(t => t.activo)))
  }, [])

  const setFilt = (k, v) => setF(s => ({ ...s, [k]: v }))
  const upd = (k, v) => setModal(m => ({ ...m, form: { ...m.form, [k]: v } }))

  const selectTipo = (tipoId) => {
    const t = tipos.find(x => String(x.id) === String(tipoId))
    // El signo del tipo es sugerido; si es 0, se respeta lo elegido.
    setModal(m => ({ ...m, form: { ...m.form, tipo_id: tipoId, signo: t && t.signo !== 0 ? t.signo : m.form.signo } }))
  }

  const save = async () => {
    const { form } = modal
    if (!form.cuenta_bancaria_id) { toast.error('Elegí una cuenta'); return }
    if (!form.tipo_id)            { toast.error('Elegí un tipo'); return }
    if (!form.monto || parseFloat(form.monto) <= 0) { toast.error('El monto debe ser mayor a cero'); return }
    try {
      await MovimientosTesoreriaAPI.create({
        cuenta_bancaria_id: Number(form.cuenta_bancaria_id), tipo_id: Number(form.tipo_id),
        signo: Number(form.signo), monto: parseFloat(form.monto), fecha: form.fecha || null,
        concepto: form.concepto || null,
      })
      toast.success('Movimiento registrado'); setModal(null); load()
    } catch {}
  }

  const anular = async (id) => {
    if (!confirm('¿Anular este movimiento? No se puede si ya está conciliado.')) return
    try { await MovimientosTesoreriaAPI.anular(id); toast.success('Movimiento anulado'); load() } catch {}
  }

  const totalEntradas = rows.filter(r => !r.anulado && r.signo === 1).reduce((a, r) => a + parseFloat(r.monto || 0), 0)
  const totalSalidas  = rows.filter(r => !r.anulado && r.signo === -1).reduce((a, r) => a + parseFloat(r.monto || 0), 0)

  return (
    <div>
      {/* KPIs del filtro */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 14, marginBottom: 16 }}>
        {[
          { label: 'Entradas (período)', val: $ar(totalEntradas), color: 'var(--green-700)' },
          { label: 'Salidas (período)',  val: $ar(totalSalidas),  color: 'var(--red-500)' },
          { label: 'Neto',               val: $ar(totalEntradas - totalSalidas), color: 'var(--blue-600)' },
        ].map(k => (
          <div key={k.label} className="card" style={{ padding: '12px 16px' }}>
            <div className="kpi-label">{k.label}</div>
            <div className="kpi-value" style={{ color: k.color, fontSize: 18, margin: '5px 0 0' }}>{k.val}</div>
          </div>
        ))}
      </div>

      {/* Filtros */}
      <div className="page-toolbar" style={{ flexWrap: 'wrap', gap: 8 }}>
        <div className="toolbar-left" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <select className="sel" style={{ width: 190 }} value={f.cuenta_id} onChange={e => setFilt('cuenta_id', e.target.value)}>
            <option value="">Todas las cuentas</option>
            {cuentas.map(c => <option key={c.id} value={c.id}>{c.descripcion}</option>)}
          </select>
          <select className="sel" style={{ width: 170 }} value={f.tipo_id} onChange={e => setFilt('tipo_id', e.target.value)}>
            <option value="">Todos los tipos</option>
            {tipos.map(t => <option key={t.id} value={t.id}>{t.descripcion}</option>)}
          </select>
          <input type="date" className="inp" style={{ width: 140 }} value={f.desde} onChange={e => setFilt('desde', e.target.value)} />
          <input type="date" className="inp" style={{ width: 140 }} value={f.hasta} onChange={e => setFilt('hasta', e.target.value)} />
          <input className="search-inp" style={{ width: 180 }} placeholder="Buscar concepto…" value={f.q} onChange={e => setFilt('q', e.target.value)} />
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button className="btn btn-secondary" onClick={() => setTransfer(true)}>⇄ Transferencia</button>
          <button className="btn btn-primary" onClick={() => setModal({ form: { ...BLANK } })}>+ Nuevo movimiento</button>
        </div>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th style={{ width: 100 }}>Fecha</th><th>Tipo</th><th>Cuenta</th><th>Concepto</th>
                <th className="th-right">Entrada</th><th className="th-right">Salida</th>
                <th style={{ width: 90 }}>Estado</th><th style={{ width: 80 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="📒" message="Sin movimientos" /> : rows.map(m => (
                <tr key={m.id} style={{ opacity: m.anulado ? 0.5 : 1 }}>
                  <td style={{ fontSize: 12 }}>{fFecha(m.fecha)}</td>
                  <td style={{ fontSize: 12 }}>{m.tipo_descripcion}</td>
                  <td style={{ fontSize: 12 }}>{m.cuenta_descripcion}</td>
                  <td style={{ fontSize: 12, color: 'var(--gray-600)' }}>
                    {m.concepto || '—'}
                    {m.origen !== 'manual' && <span style={{ fontSize: 10, marginLeft: 6, background: 'var(--gray-100)', color: 'var(--gray-500)', padding: '1px 6px', borderRadius: 8 }}>{m.origen}</span>}
                  </td>
                  <td className="td-right td-bold" style={{ color: 'var(--green-700)' }}>{m.signo === 1 ? $ar(m.monto) : ''}</td>
                  <td className="td-right td-bold" style={{ color: 'var(--red-500)' }}>{m.signo === -1 ? $ar(m.monto) : ''}</td>
                  <td>
                    {m.anulado
                      ? <span className="badge badge-anulada">Anulado</span>
                      : m.conciliado ? <span className="badge badge-cobrada">Conciliado</span> : <span className="badge badge-pendiente">Vigente</span>}
                  </td>
                  <td>
                    {!m.anulado && !m.conciliado && <button className="btn btn-danger btn-xs" onClick={() => anular(m.id)}>Anular</button>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {modal && (
        <Modal title="Nuevo movimiento manual" size="md" onClose={() => setModal(null)}
          footer={<><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancelar</button><button className="btn btn-primary" onClick={save}>✓ Registrar</button></>}
        >
          <div className="form-row2">
            <div className="field">
              <label className="lbl">Cuenta *</label>
              <select className="sel" value={modal.form.cuenta_bancaria_id} onChange={e => upd('cuenta_bancaria_id', e.target.value)}>
                <option value="">— Seleccionar —</option>
                {cuentas.map(c => <option key={c.id} value={c.id}>{c.descripcion}</option>)}
              </select>
            </div>
            <div className="field">
              <label className="lbl">Tipo *</label>
              <select className="sel" value={modal.form.tipo_id} onChange={e => selectTipo(e.target.value)}>
                <option value="">— Seleccionar —</option>
                {tipos.map(t => <option key={t.id} value={t.id}>{t.descripcion}</option>)}
              </select>
            </div>
            <div className="field">
              <label className="lbl">Dirección *</label>
              <select className="sel" value={modal.form.signo} onChange={e => upd('signo', Number(e.target.value))}>
                <option value={1}>Entrada (+)</option>
                <option value={-1}>Salida (−)</option>
              </select>
            </div>
            <div className="field">
              <label className="lbl">Monto *</label>
              <input type="number" className="inp inp-right" value={modal.form.monto} min="0" step="0.01" onChange={e => upd('monto', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Fecha</label>
              <input type="date" className="inp" value={modal.form.fecha} onChange={e => upd('fecha', e.target.value)} />
            </div>
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Concepto</label>
              <input className="inp" value={modal.form.concepto} onChange={e => upd('concepto', e.target.value)} placeholder="Detalle del movimiento" />
            </div>
          </div>
        </Modal>
      )}

      {transfer && (
        <TransferenciaForm
          cuentas={cuentas}
          onClose={() => setTransfer(false)}
          onSaved={load}
        />
      )}
    </div>
  )
}
