// src/views/TesoreriaConciliacion/index.jsx
// Conciliación bancaria por tildado manual: abrir un extracto (rango + saldo del banco),
// tildar los movimientos del sistema que figuran en el extracto, y cerrar (snapshot de
// saldo del sistema + diferencia). La importación automática del extracto es backlog.
import { useState, useEffect, useCallback } from 'react'
import { ConciliacionAPI, CuentasBancariasAPI, MovimientosTesoreriaAPI } from '../../api'
import { $ar, fFecha, hoy } from '../../utils'
import { Modal, Loading, EmptyState } from '../../components/UI'
import toast from 'react-hot-toast'

const primerDiaMes = () => { const d = new Date(); d.setDate(1); return d.toISOString().split('T')[0] }
const BLANK = { fecha_desde: primerDiaMes(), fecha_hasta: hoy(), saldo_extracto: '' }

export default function TesoreriaConciliacion() {
  const [cuentas, setCuentas]   = useState([])
  const [cuentaId, setCuentaId] = useState('')
  const [concils, setConcils]   = useState([])
  const [active, setActive]     = useState(null)
  const [movs, setMovs]         = useState([])
  const [selected, setSelected] = useState(() => new Set())
  const [loading, setLoading]   = useState(false)
  const [modal, setModal]       = useState(null)

  useEffect(() => {
    CuentasBancariasAPI.list({ activo: true }).then(cs => {
      const banc = cs.filter(c => c.clase !== 'caja')
      setCuentas(banc)
      if (banc.length && !cuentaId) setCuentaId(String(banc[0].id))
    })
  }, [])   // eslint-disable-line

  const loadConcils = useCallback(() => {
    if (!cuentaId) return
    ConciliacionAPI.list(Number(cuentaId)).then(setConcils)
  }, [cuentaId])
  useEffect(() => { loadConcils(); setActive(null); setMovs([]) }, [loadConcils])

  const cuenta = cuentas.find(c => String(c.id) === String(cuentaId))

  const openConcil = async (c) => {
    setActive(c)
    if (c.estado !== 'abierta') { setMovs([]); return }
    setLoading(true)
    try {
      const list = await MovimientosTesoreriaAPI.list({ cuenta_id: c.cuenta_bancaria_id, desde: c.fecha_desde, hasta: c.fecha_hasta })
      const vigentes = list.filter(m => !m.anulado)
      setMovs(vigentes)
      setSelected(new Set(vigentes.filter(m => m.conciliacion_id === c.id).map(m => m.id)))
    } finally { setLoading(false) }
  }

  const toggle = (id) => setSelected(s => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n })

  const abrir = async () => {
    const f = modal
    if (!f.fecha_desde || !f.fecha_hasta) { toast.error('Rango de fechas obligatorio'); return }
    try {
      const c = await ConciliacionAPI.abrir({
        cuenta_bancaria_id: Number(cuentaId), desde: f.fecha_desde, hasta: f.fecha_hasta,
        saldo_extracto: parseFloat(f.saldo_extracto) || 0,
      })
      toast.success('Conciliación abierta'); setModal(null); loadConcils(); openConcil(c)
    } catch {}
  }

  const guardarSeleccion = async () => {
    try { await ConciliacionAPI.marcar(active.id, [...selected]); toast.success('Selección guardada'); openConcil(active) } catch {}
  }

  const cerrar = async () => {
    if (!confirm('¿Cerrar la conciliación? Los movimientos tildados no se podrán anular.')) return
    try {
      await ConciliacionAPI.marcar(active.id, [...selected])   // persistir antes de cerrar
      const cerrada = await ConciliacionAPI.cerrar(active.id)
      toast.success(`Cerrada — diferencia ${$ar(cerrada.diferencia)}`)
      loadConcils(); setActive(cerrada); setMovs([])
    } catch {}
  }

  // Preview en vivo del saldo del sistema = saldo_inicial + Σ(monto_con_signo de marcados).
  const sumSel = movs.filter(m => selected.has(m.id)).reduce((a, m) => a + parseFloat(m.monto_con_signo || 0), 0)
  const sistemaPreview = (parseFloat(cuenta?.saldo_inicial) || 0) + sumSel
  const difPreview = (parseFloat(active?.saldo_extracto) || 0) - sistemaPreview

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <select className="sel" style={{ width: 220 }} value={cuentaId} onChange={e => setCuentaId(e.target.value)}>
            <option value="">— Elegí una cuenta —</option>
            {cuentas.map(c => <option key={c.id} value={c.id}>{c.descripcion}</option>)}
          </select>
        </div>
        <button className="btn btn-primary" disabled={!cuentaId} onClick={() => setModal({ ...BLANK })}>+ Abrir conciliación</button>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '320px 1fr', gap: 18 }}>
        {/* Lista de conciliaciones */}
        <div className="tbl-wrap" style={{ alignSelf: 'start' }}>
          <table>
            <thead><tr><th>Período</th><th>Estado</th><th className="th-right">Dif.</th></tr></thead>
            <tbody>
              {concils.length === 0 ? <EmptyState icon="📄" message="Sin conciliaciones" /> : concils.map(c => (
                <tr key={c.id} onClick={() => openConcil(c)} style={{ cursor: 'pointer', background: active?.id === c.id ? 'var(--blue-50)' : 'transparent' }}>
                  <td style={{ fontSize: 12 }}>{fFecha(c.fecha_desde)} → {fFecha(c.fecha_hasta)}</td>
                  <td><span className={`badge ${c.estado === 'cerrada' ? 'badge-cobrada' : 'badge-pendiente'}`}>{c.estado}</span></td>
                  <td className="td-right" style={{ fontSize: 12, color: c.diferencia && parseFloat(c.diferencia) !== 0 ? 'var(--red-500)' : 'var(--green-600)' }}>
                    {c.estado === 'cerrada' ? $ar(c.diferencia) : '—'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Panel de trabajo */}
        <div>
          {!active ? (
            <div className="card" style={{ textAlign: 'center', padding: '50px 20px', color: 'var(--gray-400)' }}>
              Elegí o abrí una conciliación para trabajar.
            </div>
          ) : (
            <>
              <div className="card" style={{ marginBottom: 14, display: 'flex', gap: 22, flexWrap: 'wrap' }}>
                <Stat label="Saldo extracto (banco)" val={$ar(active.saldo_extracto)} />
                <Stat label="Saldo sistema (est.)" val={$ar(active.estado === 'cerrada' ? active.saldo_sistema : sistemaPreview)} />
                <Stat label="Diferencia" val={$ar(active.estado === 'cerrada' ? active.diferencia : difPreview)}
                  color={(active.estado === 'cerrada' ? parseFloat(active.diferencia) : difPreview) !== 0 ? 'var(--red-500)' : 'var(--green-600)'} />
                {active.estado === 'abierta' && (
                  <div style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'center' }}>
                    <button className="btn btn-secondary btn-sm" onClick={guardarSeleccion}>Guardar selección</button>
                    <button className="btn btn-primary btn-sm" onClick={cerrar}>✓ Cerrar conciliación</button>
                  </div>
                )}
              </div>

              {active.estado === 'cerrada' ? (
                <div className="info-box">Conciliación cerrada el período {fFecha(active.fecha_desde)} → {fFecha(active.fecha_hasta)}. Snapshot inmutable.</div>
              ) : loading ? <Loading /> : (
                <div className="tbl-wrap">
                  <table>
                    <thead>
                      <tr>
                        <th style={{ width: 36 }}></th><th style={{ width: 100 }}>Fecha</th><th>Tipo</th><th>Concepto</th>
                        <th className="th-right">Entrada</th><th className="th-right">Salida</th>
                      </tr>
                    </thead>
                    <tbody>
                      {movs.length === 0 ? <EmptyState icon="📒" message="Sin movimientos en el período" /> : movs.map(m => (
                        <tr key={m.id} style={{ background: selected.has(m.id) ? 'var(--green-50)' : 'transparent' }}>
                          <td style={{ textAlign: 'center' }}>
                            <input type="checkbox" checked={selected.has(m.id)} onChange={() => toggle(m.id)} />
                          </td>
                          <td style={{ fontSize: 12 }}>{fFecha(m.fecha)}</td>
                          <td style={{ fontSize: 12 }}>{m.tipo_descripcion}</td>
                          <td style={{ fontSize: 12, color: 'var(--gray-600)' }}>{m.concepto || '—'}</td>
                          <td className="td-right td-bold" style={{ color: 'var(--green-700)' }}>{m.signo === 1 ? $ar(m.monto) : ''}</td>
                          <td className="td-right td-bold" style={{ color: 'var(--red-500)' }}>{m.signo === -1 ? $ar(m.monto) : ''}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </>
          )}
        </div>
      </div>

      {modal && (
        <Modal title="Abrir conciliación" size="sm" onClose={() => setModal(null)}
          footer={<><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancelar</button><button className="btn btn-primary" onClick={abrir}>Abrir</button></>}
        >
          <div className="info-box" style={{ marginBottom: 10 }}>Cuenta: <strong>{cuenta?.descripcion}</strong></div>
          <div className="form-row2">
            <div className="field"><label className="lbl">Desde *</label><input type="date" className="inp" value={modal.fecha_desde} onChange={e => setModal(m => ({ ...m, fecha_desde: e.target.value }))} /></div>
            <div className="field"><label className="lbl">Hasta *</label><input type="date" className="inp" value={modal.fecha_hasta} onChange={e => setModal(m => ({ ...m, fecha_hasta: e.target.value }))} /></div>
            <div className="field" style={{ gridColumn: '1 / 3' }}><label className="lbl">Saldo final según el banco</label><input type="number" className="inp inp-right" value={modal.saldo_extracto} step="0.01" onChange={e => setModal(m => ({ ...m, saldo_extracto: e.target.value }))} /></div>
          </div>
        </Modal>
      )}
    </div>
  )
}

function Stat({ label, val, color }) {
  return (
    <div>
      <div className="kpi-label">{label}</div>
      <div className="kpi-value" style={{ color: color || 'var(--gray-700)', fontSize: 18, margin: '4px 0 0' }}>{val}</div>
    </div>
  )
}
