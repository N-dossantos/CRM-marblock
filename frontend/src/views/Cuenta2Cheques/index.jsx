// src/views/Cuenta2Cheques/index.jsx
// Cartera de cheques de Cuenta 2 (cuenta2.md §1.6). No toca cajas ni cuentas bancarias
// oficiales. Su función distintiva es el botón "Transferir a Cuenta 1": el único puente
// hacia el circuito oficial, con edición previa de los datos del cheque.
// Estructura de views/Cheques (KPIs → filtro → tabla → modales) y tabla de transiciones
// declarativa como views/TesoreriaChequesPropios.
import { useState, useEffect, useCallback } from 'react'
import { ChequesC2API } from '../../api/cuenta2'
import { $ar, fFecha, hoy } from '../../utils'
import { Badge, Modal, Loading, EmptyState } from '../../components/UI'
import toast from 'react-hot-toast'

const ESTADO_OPTS = [
  { v: '',               l: 'Todos' },
  { v: 'en_cartera',     l: 'En cartera' },
  { v: 'entregado',      l: 'Entregado' },
  { v: 'transferido_c1', l: 'Transferido a Cta. 1' },
  { v: 'anulado',        l: 'Anulado' },
]

// Acciones válidas por estado (espeja las validaciones de las RPC del servidor).
const ACCIONES = {
  en_cartera:     ['transferir', 'anular'],
  entregado:      ['anular'],
  transferido_c1: [],
  anulado:        [],
}

export default function Cuenta2Cheques() {
  const [rows, setRows]         = useState([])
  const [loading, setLoading]   = useState(true)
  const [filtroEst, setFiltro]  = useState('')
  const [transferir, setTransf] = useState(null)   // { cheque, datos }

  const load = useCallback(() => {
    setLoading(true)
    ChequesC2API.list({ estado: filtroEst }).then(setRows).finally(() => setLoading(false))
  }, [filtroEst])

  useEffect(() => { load() }, [load])

  const enCartera = rows.filter(c => c.estado === 'en_cartera')
  const kpis = [
    { label: 'En cartera',        value: $ar(enCartera.reduce((a, c) => a + (+c.monto || 0), 0)), sub: `${enCartera.length} cheque(s)` },
    { label: 'Entregados',        value: rows.filter(c => c.estado === 'entregado').length,      sub: 'endosados a proveedores C2' },
    { label: 'Transferidos a C1', value: rows.filter(c => c.estado === 'transferido_c1').length, sub: 'ya en la cartera oficial' },
  ]

  const abrirTransferencia = (ch) => setTransf({
    cheque: ch,
    datos: {
      numero: ch.numero, tipo: ch.tipo, banco: ch.banco,
      titular: ch.titular || '', cuit_titular: ch.cuit_titular || '',
      fecha_emision: ch.fecha_emision || hoy(), fecha_vcto: ch.fecha_vcto,
      monto: String(ch.monto),
    },
  })

  const confirmarTransferencia = async () => {
    const { cheque, datos } = transferir
    if (!datos.banco.trim() || !datos.numero.trim()) { toast.error('Banco y número son obligatorios'); return }
    if (!parseFloat(datos.monto))                     { toast.error('Ingrese el monto'); return }
    try {
      await ChequesC2API.transferir(cheque.id, datos)
      toast.success('Cheque transferido a la cartera de Cuenta 1')
      setTransf(null); load()
    } catch { /* el toast ya lo emitió la capa API */ }
  }

  const anular = async (ch) => {
    if (!confirm(`¿Anular el cheque ${ch.banco} ${ch.numero}?`)) return
    try {
      await ChequesC2API.anular(ch.id)
      toast.success('Cheque anulado')
      load()
    } catch { /* el toast ya lo emitió la capa API */ }
  }

  return (
    <div>
      <div className="info-box" style={{ marginBottom: 16 }}>
        <span>
          Cartera de <strong>Cuenta 2</strong>. Para depositar un cheque hay que transferirlo primero
          a Cuenta 1: el depósito acredita en una cuenta bancaria oficial y se gestiona desde la
          cartera del circuito oficial.
        </span>
      </div>

      <div className="kpi-grid">
        {kpis.map(k => (
          <div className="kpi-card" key={k.label}>
            <div className="kpi-label">{k.label}</div>
            <div className="kpi-value">{k.value}</div>
            <div className="kpi-sub">{k.sub}</div>
          </div>
        ))}
      </div>

      <div className="page-toolbar">
        <div className="toolbar-left">
          <select className="sel" style={{ width: 200 }} value={filtroEst} onChange={e => setFiltro(e.target.value)}>
            {ESTADO_OPTS.map(o => <option key={o.v} value={o.v}>{o.l}</option>)}
          </select>
        </div>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Banco</th>
                <th>Número</th>
                <th>Tipo</th>
                <th>Vencimiento</th>
                <th>Origen / Destino</th>
                <th className="th-right">Monto ($)</th>
                <th>Estado</th>
                <th style={{ width: 220 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🏦" message="Sin cheques en la cartera Cuenta 2" /> : rows.map(ch => {
                const acciones = ACCIONES[ch.estado] || []
                return (
                  <tr key={ch.id}>
                    <td className="td-bold">{ch.banco}</td>
                    <td><span className="code">{ch.numero}</span></td>
                    <td>{ch.tipo === 'echeq' ? 'E-Cheq' : 'Físico'}</td>
                    <td>{fFecha(ch.fecha_vcto)}</td>
                    <td style={{ fontSize: 12 }}>
                      {ch.cliente_nombre && <>de {ch.cliente_nombre}</>}
                      {ch.proveedor_nombre && <> → {ch.proveedor_nombre}</>}
                      {!ch.cliente_nombre && !ch.proveedor_nombre && '—'}
                    </td>
                    <td className="td-right td-bold">{$ar(ch.monto)}</td>
                    <td><Badge estado={ch.estado} /></td>
                    <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                      {acciones.includes('transferir') && (
                        <button
                          className="btn btn-secondary btn-xs"
                          style={{ background: '#ffedd5', color: '#9a3412', borderColor: '#fed7aa' }}
                          onClick={() => abrirTransferencia(ch)}
                        >
                          → Transferir a Cuenta 1
                        </button>
                      )}
                      {acciones.includes('anular') && (
                        <> <button className="btn btn-danger btn-xs" onClick={() => anular(ch)}>Anular</button></>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>

      {transferir && (
        <Modal
          title="Transferir cheque a Cuenta 1"
          size="md"
          onClose={() => setTransf(null)}
          footer={
            <>
              <button className="btn btn-secondary" onClick={() => setTransf(null)}>Cancelar</button>
              <button className="btn btn-primary" onClick={confirmarTransferencia}>→ Transferir</button>
            </>
          }
        >
          <div className="warn-box" style={{ marginBottom: 14 }}>
            <span>⚠️</span>
            <div>
              El cheque pasa a la <strong>cartera oficial de Cuenta 1</strong> en estado “en cartera”,
              y acá queda marcado como transferido. La operación no se puede deshacer.
              Podés corregir los datos antes de transferirlo.
            </div>
          </div>

          <div className="form-row3" style={{ marginBottom: 12 }}>
            <div className="field">
              <label className="lbl">Banco *</label>
              <input className="inp inp-sm" value={transferir.datos.banco}
                     onChange={e => setTransf(t => ({ ...t, datos: { ...t.datos, banco: e.target.value } }))} />
            </div>
            <div className="field">
              <label className="lbl">Número *</label>
              <input className="inp inp-sm" value={transferir.datos.numero}
                     onChange={e => setTransf(t => ({ ...t, datos: { ...t.datos, numero: e.target.value } }))} />
            </div>
            <div className="field">
              <label className="lbl">Tipo</label>
              <select className="sel inp-sm" value={transferir.datos.tipo}
                      onChange={e => setTransf(t => ({ ...t, datos: { ...t.datos, tipo: e.target.value } }))}>
                <option value="fisico">Físico</option>
                <option value="echeq">E-Cheq</option>
              </select>
            </div>
          </div>

          <div className="form-row3" style={{ marginBottom: 12 }}>
            <div className="field">
              <label className="lbl">Monto *</label>
              <input type="number" step="0.01" className="inp inp-sm inp-right" value={transferir.datos.monto}
                     onChange={e => setTransf(t => ({ ...t, datos: { ...t.datos, monto: e.target.value } }))} />
            </div>
            <div className="field">
              <label className="lbl">Emisión</label>
              <input type="date" className="inp inp-sm" value={transferir.datos.fecha_emision}
                     onChange={e => setTransf(t => ({ ...t, datos: { ...t.datos, fecha_emision: e.target.value } }))} />
            </div>
            <div className="field">
              <label className="lbl">Vencimiento *</label>
              <input type="date" className="inp inp-sm" value={transferir.datos.fecha_vcto}
                     onChange={e => setTransf(t => ({ ...t, datos: { ...t.datos, fecha_vcto: e.target.value } }))} />
            </div>
          </div>

          <div className="form-row2">
            <div className="field">
              <label className="lbl">Titular</label>
              <input className="inp inp-sm" value={transferir.datos.titular}
                     onChange={e => setTransf(t => ({ ...t, datos: { ...t.datos, titular: e.target.value } }))} />
            </div>
            <div className="field">
              <label className="lbl">CUIT titular</label>
              <input className="inp inp-sm" value={transferir.datos.cuit_titular}
                     onChange={e => setTransf(t => ({ ...t, datos: { ...t.datos, cuit_titular: e.target.value } }))} />
            </div>
          </div>
        </Modal>
      )}
    </div>
  )
}
