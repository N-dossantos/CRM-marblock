// src/views/Cheques/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { ChequesAPI, ClientesAPI, CuentasBancariasAPI } from '../../api'
import { $ar, fFecha, hoy, addDias, isVencido } from '../../utils'
import { Badge, Loading, EmptyState, Modal } from '../../components/UI'
import toast from 'react-hot-toast'

const ESTADO_OPTS = [
  { v: '',               l: 'Todos' },
  { v: 'en_cartera',     l: 'En cartera' },
  { v: 'depositado',     l: 'Depositado' },
  { v: 'entregado',      l: 'Entregado' },
  { v: 'rechazado_banco',l: 'Rechazado' },
]

const BLANK = {
  numero: '', tipo: 'fisico', banco: '', titular: '', cuit_titular: '',
  fecha_emision: hoy(), fecha_vcto: addDias(hoy(), 30),
  monto: '', cliente_id: '', observaciones: '',
}

export default function Cheques() {
  const [rows, setRows]         = useState([])
  const [loading, setLoading]   = useState(true)
  const [clientes, setClientes] = useState([])
  const [filtroEst, setFiltroEst] = useState('')
  const [nuevo, setNuevo]       = useState(null)
  const [entregar, setEntregar] = useState(null) // { cheque, prov }
  const [depositar, setDepositar] = useState(null) // { cheque, cuenta_id, fecha }
  const [cuentas, setCuentas]   = useState([])

  const load = useCallback(() => {
    setLoading(true)
    ChequesAPI.list({ estado: filtroEst }).then(setRows).finally(() => setLoading(false))
  }, [filtroEst])

  useEffect(() => { load() }, [load])
  useEffect(() => { ClientesAPI.list().then(setClientes) }, [])
  // Cuentas de depósito (banco / valores; no efectivo). Fase C.
  useEffect(() => { CuentasBancariasAPI.list({ activo: true }).then(cs => setCuentas(cs.filter(c => c.clase !== 'caja'))) }, [])

  const cambiarEstado = async (id, estado, proveedor = undefined) => {
    await ChequesAPI.cambiarEstado(id, estado, proveedor)
    load()
  }

  // Fase C: depositar acredita en una cuenta (RPC que genera el movimiento +1).
  const confirmarDeposito = async () => {
    if (!depositar.cuenta_id) { toast.error('Elegí la cuenta de depósito'); return }
    try {
      await ChequesAPI.depositar(depositar.cheque.id, Number(depositar.cuenta_id), depositar.fecha || null)
      toast.success('Cheque depositado — acreditado en la cuenta')
      setDepositar(null); load()
    } catch {}
  }
  // Rechazar un cheque ya depositado revierte la acreditación (RPC -1).
  const rechazarDepositado = async (id) => {
    if (!confirm('¿Rechazar el cheque? Revierte la acreditación en el banco.')) return
    try { await ChequesAPI.rechazar(id); toast.success('Cheque rechazado'); load() } catch {}
  }

  const guardarNuevo = async () => {
    const f = nuevo
    if (!f.numero.trim() || !f.banco.trim()) { toast.error('Número y banco obligatorios'); return }
    if (!f.monto || parseFloat(f.monto) <= 0) { toast.error('El monto debe ser mayor a cero'); return }
    if (!f.fecha_vcto) { toast.error('Fecha de vencimiento obligatoria'); return }
    await ChequesAPI.create({ ...f, monto: parseFloat(f.monto), cliente_id: f.cliente_id || null })
    toast.success('Cheque registrado en cartera')
    setNuevo(null)
    load()
  }

  const upd = (f, v) => setNuevo(n => ({ ...n, [f]: v }))

  // Resumen por estado
  const enCartera = rows.filter(c => c.estado === 'en_cartera')
  const totalCartera = enCartera.reduce((a, c) => a + parseFloat(c.monto || 0), 0)
  const vencidos = enCartera.filter(c => isVencido(c.fecha_vcto)).length

  return (
    <div>
      {/* KPIs rápidos */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14, marginBottom: 18 }}>
        {[
          { label: 'Cheques en cartera', val: enCartera.length, color: 'var(--blue-600)', sub: 'unidades' },
          { label: 'Total en cartera',   val: $ar(totalCartera), color: '#10b981', sub: 'monto total' },
          { label: 'Vencidos en cartera', val: vencidos, color: vencidos > 0 ? 'var(--red-500)' : 'var(--gray-400)', sub: vencidos > 0 ? '⚠ Requieren atención' : 'Sin vencidos' },
        ].map(k => (
          <div key={k.label} className="card" style={{ padding: '14px 18px', borderLeft: `4px solid ${k.color}` }}>
            <div className="kpi-label">{k.label}</div>
            <div className="kpi-value" style={{ color: k.color, fontSize: 20, margin: '6px 0 2px' }}>{k.val}</div>
            <div className="kpi-sub">{k.sub}</div>
          </div>
        ))}
      </div>

      <div className="page-toolbar">
        <div className="toolbar-left">
          <select className="sel" style={{ width: 170 }} value={filtroEst} onChange={e => setFiltroEst(e.target.value)}>
            {ESTADO_OPTS.map(o => <option key={o.v} value={o.v}>{o.l}</option>)}
          </select>
        </div>
        <button className="btn btn-primary" onClick={() => setNuevo({ ...BLANK })}>+ Registrar cheque</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Nro. cheque</th><th>Tipo</th><th>Banco</th><th>Titular</th>
                <th>Cliente origen</th><th className="th-right">Monto</th>
                <th>F. Emisión</th><th>Vencimiento</th>
                <th>Destino (proveedor)</th><th>Estado</th><th style={{ width: 160 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🏦" message="Sin cheques en cartera" /> : rows.map(ch => (
                <tr key={ch.id}>
                  <td><span className="code" style={{ fontWeight: 700 }}>{ch.numero}</span></td>
                  <td><span style={{ fontSize: 11, background: ch.tipo === 'echeq' ? '#ede9fe' : 'var(--gray-100)', color: ch.tipo === 'echeq' ? '#5b21b6' : 'var(--gray-600)', padding: '2px 7px', borderRadius: 10, fontWeight: 700 }}>{ch.tipo === 'echeq' ? 'E-Cheq' : 'Físico'}</span></td>
                  <td style={{ fontSize: 12 }}>{ch.banco}</td>
                  <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{ch.titular || <span style={{ color: 'var(--gray-300)' }}>—</span>}</td>
                  <td style={{ fontSize: 12 }}>{ch.cliente_razon_social || '—'}</td>
                  <td className="td-right td-bold">{$ar(ch.monto)}</td>
                  <td style={{ fontSize: 12 }}>{fFecha(ch.fecha_emision)}</td>
                  <td style={{ fontSize: 12, color: isVencido(ch.fecha_vcto) && ch.estado === 'en_cartera' ? 'var(--red-500)' : 'inherit', fontWeight: isVencido(ch.fecha_vcto) && ch.estado === 'en_cartera' ? 700 : 400 }}>
                    {fFecha(ch.fecha_vcto)}
                    {isVencido(ch.fecha_vcto) && ch.estado === 'en_cartera' && <span style={{ fontSize: 10, marginLeft: 4, color: 'var(--red-500)' }}>VENCIDO</span>}
                  </td>
                  <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{ch.proveedor_destino || '—'}</td>
                  <td><Badge estado={ch.estado} /></td>
                  <td>
                    <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                      {ch.estado === 'en_cartera' && <>
                        <button className="btn btn-secondary btn-xs" style={{ background: 'var(--green-50)', color: 'var(--green-700)', borderColor: 'var(--green-100)' }}
                          onClick={() => { if (confirm('¿Marcar como depositado?')) cambiarEstado(ch.id, 'depositado') }}>
                          ✓ Depositar
                        </button>
                        <button className="btn btn-secondary btn-xs" style={{ background: 'var(--purple-50)', color: '#5b21b6', borderColor: '#ede9fe' }}
                          onClick={() => setEntregar({ cheque: ch, prov: '' })}>
                          → Entregar
                        </button>
                      </>}
                      {(ch.estado === 'depositado' || ch.estado === 'entregado') && (
                        <button className="btn btn-danger btn-xs"
                          onClick={() => { if (confirm('¿Marcar como rechazado por el banco?')) cambiarEstado(ch.id, 'rechazado_banco') }}>
                          Rechazado
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* Modal nuevo cheque */}
      {nuevo && (
        <Modal title="Registrar cheque en cartera" size="md" onClose={() => setNuevo(null)}
          footer={<><button className="btn btn-secondary" onClick={() => setNuevo(null)}>Cancelar</button><button className="btn btn-primary" onClick={guardarNuevo}>✓ Guardar</button></>}
        >
          <div className="form-row2">
            <div className="field">
              <label className="lbl">Tipo</label>
              <select className="sel" value={nuevo.tipo} onChange={e => upd('tipo', e.target.value)}>
                <option value="fisico">Cheque físico</option>
                <option value="echeq">E-Cheq</option>
              </select>
            </div>
            <div className="field">
              <label className="lbl">Nro. cheque *</label>
              <input className="inp" value={nuevo.numero} onChange={e => upd('numero', e.target.value)} />
            </div>
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Banco *</label>
              <input className="inp" value={nuevo.banco} onChange={e => upd('banco', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Titular (opcional)</label>
              <input className="inp" value={nuevo.titular} onChange={e => upd('titular', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">CUIT titular (opcional)</label>
              <input className="inp" value={nuevo.cuit_titular} onChange={e => upd('cuit_titular', e.target.value)} placeholder="20-XXXXXXXX-X" />
            </div>
            <div className="field">
              <label className="lbl">Fecha de emisión</label>
              <input type="date" className="inp" value={nuevo.fecha_emision} onChange={e => upd('fecha_emision', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Fecha de vencimiento *</label>
              <input type="date" className="inp" value={nuevo.fecha_vcto} onChange={e => upd('fecha_vcto', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Monto *</label>
              <input type="number" className="inp inp-right" value={nuevo.monto} min="0" step="0.01" onChange={e => upd('monto', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Cliente que lo entregó (opcional)</label>
              <select className="sel" value={nuevo.cliente_id} onChange={e => upd('cliente_id', e.target.value)}>
                <option value="">— Sin cliente —</option>
                {clientes.map(c => <option key={c.id} value={c.id}>{c.razon_social}</option>)}
              </select>
            </div>
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Observaciones</label>
              <input className="inp" value={nuevo.observaciones} onChange={e => upd('observaciones', e.target.value)} />
            </div>
          </div>
        </Modal>
      )}

      {/* Modal entregar a proveedor */}
      {entregar && (
        <Modal title={`Entregar cheque ${entregar.cheque.numero}`} size="sm" onClose={() => setEntregar(null)}
          footer={
            <>
              <button className="btn btn-secondary" onClick={() => setEntregar(null)}>Cancelar</button>
              <button className="btn btn-primary" onClick={() => { cambiarEstado(entregar.cheque.id, 'entregado', entregar.prov || null); setEntregar(null) }}>
                Confirmar entrega
              </button>
            </>
          }
        >
          <div className="info-box">
            Monto: <strong>{$ar(entregar.cheque.monto)}</strong> — Vence: {fFecha(entregar.cheque.fecha_vcto)}
          </div>
          <div className="field">
            <label className="lbl">Proveedor / destinatario (opcional)</label>
            <input className="inp" placeholder="Ej: Distribuidora ABC" value={entregar.prov}
              onChange={e => setEntregar(d => ({ ...d, prov: e.target.value }))} />
          </div>
          <p style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 4 }}>
            Si no se completa, quedará registrado como entregado sin destinatario.
          </p>
        </Modal>
      )}
    </div>
  )
}
