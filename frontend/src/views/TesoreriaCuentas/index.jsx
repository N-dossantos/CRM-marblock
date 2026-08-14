// src/views/TesoreriaCuentas/index.jsx
// ABM de la dimensión "cuenta" del ledger: cuentas_bancarias (banco/caja/valores) +
// agrupaciones + tipos de comprobante. Muestra el saldo actual por cuenta (informe_saldos)
// y permite fijar la caja default para los medios "efectivo".
import { useState, useEffect, useCallback } from 'react'
import { CuentasBancariasAPI, AgrupacionesTesoreriaAPI, TiposComprobanteTesoreriaAPI, ConfigAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Modal, Loading, EmptyState } from '../../components/UI'
import toast from 'react-hot-toast'

const CLASES = [
  { v: 'banco',   l: 'Banco' },
  { v: 'caja',    l: 'Caja (efectivo)' },
  { v: 'valores', l: 'Valores a depositar' },
]
const CLASE_LBL = Object.fromEntries(CLASES.map(c => [c.v, c.l]))

const SUBTABS = [
  { id: 'cuentas',      label: '🏦 Cuentas' },
  { id: 'agrupaciones', label: '🗂️ Agrupaciones' },
  { id: 'tipos',        label: '🏷️ Tipos de comprobante' },
]

const BLANK_CUENTA = {
  descripcion: '', clase: 'banco', banco: '', tipo_cuenta: '', numero: '', cbu: '', alias: '',
  agrupacion_id: '', saldo_inicial: 0, fecha_saldo_inicial: '',
}
const BLANK_AGRUP = { codigo: '', descripcion: '', orden: 0 }
const BLANK_TIPO  = { codigo: '', descripcion: '', signo: 0 }

export default function TesoreriaCuentas() {
  const [sub, setSub] = useState('cuentas')
  return (
    <div>
      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '2px solid var(--gray-200)' }}>
        {SUBTABS.map(t => (
          <button key={t.id} onClick={() => setSub(t.id)} style={tabStyle(sub === t.id)}>{t.label}</button>
        ))}
      </div>
      {sub === 'cuentas'      && <Cuentas />}
      {sub === 'agrupaciones' && <Agrupaciones />}
      {sub === 'tipos'        && <Tipos />}
    </div>
  )
}

function tabStyle(active) {
  return {
    padding: '10px 18px', background: 'transparent', border: 'none',
    borderBottom: active ? '2px solid var(--blue-600)' : '2px solid transparent', marginBottom: -2,
    color: active ? 'var(--blue-600)' : 'var(--gray-500)', fontWeight: active ? 700 : 400,
    fontSize: 13, cursor: 'pointer', fontFamily: 'inherit', whiteSpace: 'nowrap',
  }
}

// ══════════════════════ CUENTAS ══════════════════════
function Cuentas() {
  const [rows, setRows]       = useState([])
  const [saldos, setSaldos]   = useState({})   // id -> saldo_actual
  const [agrup, setAgrup]     = useState([])
  const [cajaDefault, setCajaDefault] = useState('')
  const [loading, setLoading] = useState(true)
  const [modal, setModal]     = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    Promise.all([
      CuentasBancariasAPI.list(),
      CuentasBancariasAPI.saldos(),
      AgrupacionesTesoreriaAPI.list(),
      ConfigAPI.empresa(),
    ]).then(([cuentas, sal, ags, cfg]) => {
      setRows(cuentas)
      setAgrup(ags)
      setCajaDefault(cfg?.tesoreria_caja_default_id || '')
      const map = {}
      ;(sal?.agrupaciones || []).forEach(g => (g.cuentas || []).forEach(c => { map[c.id] = c.saldo_actual }))
      setSaldos(map)
    }).finally(() => setLoading(false))
  }, [])

  useEffect(() => { load() }, [load])

  const openNew  = () => setModal({ form: { ...BLANK_CUENTA }, isNew: true })
  const openEdit = (c) => setModal({ form: { ...c, agrupacion_id: c.agrupacion_id ?? '', fecha_saldo_inicial: c.fecha_saldo_inicial || '' }, isNew: false })
  const upd = (f, v) => setModal(m => ({ ...m, form: { ...m.form, [f]: v } }))

  const save = async () => {
    const { form, isNew } = modal
    if (!form.descripcion?.trim()) { toast.error('Descripción obligatoria'); return }
    try {
      if (isNew) await CuentasBancariasAPI.create(form)
      else       await CuentasBancariasAPI.update(form.id, form)
      toast.success(isNew ? 'Cuenta creada' : 'Cuenta actualizada')
      setModal(null); load()
    } catch {}
  }

  const fijarCajaDefault = async (id) => {
    await ConfigAPI.set('tesoreria_caja_default_id', String(id))
    toast.success('Caja default actualizada')
    setCajaDefault(String(id))
  }

  const agrupName = (id) => agrup.find(a => a.id === id)?.descripcion || '—'

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left" style={{ fontSize: 13, color: 'var(--gray-500)' }}>
          Caja default (medios «efectivo»): <strong>{cajaDefault ? (rows.find(r => String(r.id) === String(cajaDefault))?.descripcion || `#${cajaDefault}`) : 'sin definir'}</strong>
        </div>
        <button className="btn btn-primary" onClick={openNew}>+ Nueva cuenta</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Descripción</th><th>Clase</th><th>Agrupación</th><th>Banco</th>
                <th className="th-right">Saldo inicial</th><th className="th-right">Saldo actual</th>
                <th style={{ width: 200 }}>Acciones</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🏦" message="Sin cuentas" /> : rows.map(c => (
                <tr key={c.id} style={{ opacity: c.activo ? 1 : 0.5 }}>
                  <td className="td-bold">
                    {c.descripcion}
                    {String(c.id) === String(cajaDefault) && <span style={{ fontSize: 10, marginLeft: 6, background: 'var(--green-100)', color: 'var(--green-700)', padding: '1px 6px', borderRadius: 8, fontWeight: 700 }}>CAJA DEFAULT</span>}
                  </td>
                  <td style={{ fontSize: 12 }}>{CLASE_LBL[c.clase] || c.clase}</td>
                  <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{agrupName(c.agrupacion_id)}</td>
                  <td style={{ fontSize: 12 }}>{c.banco || '—'}</td>
                  <td className="td-right">{$ar(c.saldo_inicial)}</td>
                  <td className="td-right td-bold" style={{ color: (saldos[c.id] ?? 0) < 0 ? 'var(--red-500)' : 'inherit' }}>{$ar(saldos[c.id] ?? c.saldo_inicial)}</td>
                  <td>
                    <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                      <button className="btn btn-ghost btn-sm" onClick={() => openEdit(c)}>Editar</button>
                      {c.clase === 'caja' && String(c.id) !== String(cajaDefault) && (
                        <button className="btn btn-secondary btn-xs" onClick={() => fijarCajaDefault(c.id)}>Fijar default</button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {modal && (
        <Modal title={modal.isNew ? 'Nueva cuenta' : 'Editar cuenta'} size="md" onClose={() => setModal(null)}
          footer={<><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancelar</button><button className="btn btn-primary" onClick={save}>✓ Guardar</button></>}
        >
          <div className="form-row2">
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Descripción *</label>
              <input className="inp" value={modal.form.descripcion} onChange={e => upd('descripcion', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Clase</label>
              <select className="sel" value={modal.form.clase} onChange={e => upd('clase', e.target.value)}>
                {CLASES.map(c => <option key={c.v} value={c.v}>{c.l}</option>)}
              </select>
            </div>
            <div className="field">
              <label className="lbl">Agrupación</label>
              <select className="sel" value={modal.form.agrupacion_id} onChange={e => upd('agrupacion_id', e.target.value)}>
                <option value="">— Sin agrupación —</option>
                {agrup.map(a => <option key={a.id} value={a.id}>{a.descripcion}</option>)}
              </select>
            </div>
            <div className="field">
              <label className="lbl">Banco</label>
              <input className="inp" value={modal.form.banco || ''} onChange={e => upd('banco', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Tipo de cuenta</label>
              <input className="inp" value={modal.form.tipo_cuenta || ''} onChange={e => upd('tipo_cuenta', e.target.value)} placeholder="Cta. Cte. / Caja de ahorro" />
            </div>
            <div className="field">
              <label className="lbl">Número</label>
              <input className="inp" value={modal.form.numero || ''} onChange={e => upd('numero', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">CBU</label>
              <input className="inp" value={modal.form.cbu || ''} onChange={e => upd('cbu', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Alias</label>
              <input className="inp" value={modal.form.alias || ''} onChange={e => upd('alias', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Saldo inicial</label>
              <input type="number" className="inp inp-right" value={modal.form.saldo_inicial} step="0.01" onChange={e => upd('saldo_inicial', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Fecha saldo inicial</label>
              <input type="date" className="inp" value={modal.form.fecha_saldo_inicial || ''} onChange={e => upd('fecha_saldo_inicial', e.target.value)} />
            </div>
            {!modal.isNew && (
              <div className="field">
                <label className="lbl">Estado</label>
                <select className="sel" value={modal.form.activo ? 'true' : 'false'} onChange={e => upd('activo', e.target.value === 'true')}>
                  <option value="true">Activa</option><option value="false">Inactiva</option>
                </select>
              </div>
            )}
          </div>
          <p style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 10 }}>
            El saldo inicial se carga del cutover (Tango); el ledger sólo guarda los deltas desde esa fecha.
          </p>
        </Modal>
      )}
    </div>
  )
}

// ══════════════════════ AGRUPACIONES ══════════════════════
function Agrupaciones() {
  const [rows, setRows]       = useState([])
  const [loading, setLoading] = useState(true)
  const [modal, setModal]     = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    AgrupacionesTesoreriaAPI.list().then(setRows).finally(() => setLoading(false))
  }, [])
  useEffect(() => { load() }, [load])

  const upd = (f, v) => setModal(m => ({ ...m, form: { ...m.form, [f]: v } }))
  const save = async () => {
    const { form, isNew } = modal
    if (!form.codigo?.trim() || !form.descripcion?.trim()) { toast.error('Código y descripción obligatorios'); return }
    try {
      if (isNew) await AgrupacionesTesoreriaAPI.create(form)
      else       await AgrupacionesTesoreriaAPI.update(form.id, form)
      toast.success('Guardado'); setModal(null); load()
    } catch {}
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left" />
        <button className="btn btn-primary" onClick={() => setModal({ form: { ...BLANK_AGRUP }, isNew: true })}>+ Nueva agrupación</button>
      </div>
      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead><tr><th>Código</th><th>Descripción</th><th className="th-right">Orden</th><th style={{ width: 80 }}></th></tr></thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🗂️" message="Sin agrupaciones" /> : rows.map(a => (
                <tr key={a.id} style={{ opacity: a.activo ? 1 : 0.5 }}>
                  <td><span className="code" style={{ fontWeight: 700 }}>{a.codigo}</span></td>
                  <td className="td-bold">{a.descripcion}</td>
                  <td className="td-right">{a.orden}</td>
                  <td><button className="btn btn-ghost btn-sm" onClick={() => setModal({ form: { ...a }, isNew: false })}>Editar</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      {modal && (
        <Modal title={modal.isNew ? 'Nueva agrupación' : 'Editar agrupación'} size="sm" onClose={() => setModal(null)}
          footer={<><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancelar</button><button className="btn btn-primary" onClick={save}>✓ Guardar</button></>}
        >
          <div className="field"><label className="lbl">Código *</label><input className="inp" value={modal.form.codigo} onChange={e => upd('codigo', e.target.value)} /></div>
          <div className="field"><label className="lbl">Descripción *</label><input className="inp" value={modal.form.descripcion} onChange={e => upd('descripcion', e.target.value)} /></div>
          <div className="field"><label className="lbl">Orden</label><input type="number" className="inp inp-right" value={modal.form.orden} onChange={e => upd('orden', e.target.value)} /></div>
          {!modal.isNew && (
            <div className="field"><label className="lbl">Estado</label>
              <select className="sel" value={modal.form.activo ? 'true' : 'false'} onChange={e => upd('activo', e.target.value === 'true')}>
                <option value="true">Activa</option><option value="false">Inactiva</option>
              </select>
            </div>
          )}
        </Modal>
      )}
    </div>
  )
}

// ══════════════════════ TIPOS DE COMPROBANTE ══════════════════════
function Tipos() {
  const [rows, setRows]       = useState([])
  const [loading, setLoading] = useState(true)
  const [modal, setModal]     = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    TiposComprobanteTesoreriaAPI.list().then(setRows).finally(() => setLoading(false))
  }, [])
  useEffect(() => { load() }, [load])

  const upd = (f, v) => setModal(m => ({ ...m, form: { ...m.form, [f]: v } }))
  const save = async () => {
    const { form, isNew } = modal
    if (!form.codigo?.trim() || !form.descripcion?.trim()) { toast.error('Código y descripción obligatorios'); return }
    try {
      if (isNew) await TiposComprobanteTesoreriaAPI.create(form)
      else       await TiposComprobanteTesoreriaAPI.update(form.id, form)
      toast.success('Guardado'); setModal(null); load()
    } catch {}
  }

  const signoLbl = (s) => s === 1 ? 'Entrada (+1)' : s === -1 ? 'Salida (−1)' : 'Depende (0)'

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left" style={{ fontSize: 12, color: 'var(--gray-400)' }}>El signo del movimiento manda; el del tipo es sólo sugerido (0 = lo define el movimiento).</div>
        <button className="btn btn-primary" onClick={() => setModal({ form: { ...BLANK_TIPO }, isNew: true })}>+ Nuevo tipo</button>
      </div>
      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead><tr><th>Código</th><th>Descripción</th><th>Signo sugerido</th><th style={{ width: 80 }}></th></tr></thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🏷️" message="Sin tipos" /> : rows.map(t => (
                <tr key={t.id} style={{ opacity: t.activo ? 1 : 0.5 }}>
                  <td><span className="code" style={{ fontWeight: 700 }}>{t.codigo}</span></td>
                  <td className="td-bold">{t.descripcion}</td>
                  <td style={{ fontSize: 12 }}>{signoLbl(t.signo)}</td>
                  <td><button className="btn btn-ghost btn-sm" onClick={() => setModal({ form: { ...t }, isNew: false })}>Editar</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      {modal && (
        <Modal title={modal.isNew ? 'Nuevo tipo' : 'Editar tipo'} size="sm" onClose={() => setModal(null)}
          footer={<><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancelar</button><button className="btn btn-primary" onClick={save}>✓ Guardar</button></>}
        >
          <div className="field"><label className="lbl">Código *</label><input className="inp" value={modal.form.codigo} onChange={e => upd('codigo', e.target.value)} /></div>
          <div className="field"><label className="lbl">Descripción *</label><input className="inp" value={modal.form.descripcion} onChange={e => upd('descripcion', e.target.value)} /></div>
          <div className="field"><label className="lbl">Signo sugerido</label>
            <select className="sel" value={modal.form.signo} onChange={e => upd('signo', Number(e.target.value))}>
              <option value={0}>Depende del movimiento (0)</option>
              <option value={1}>Entrada (+1)</option>
              <option value={-1}>Salida (−1)</option>
            </select>
          </div>
          {!modal.isNew && (
            <div className="field"><label className="lbl">Estado</label>
              <select className="sel" value={modal.form.activo ? 'true' : 'false'} onChange={e => upd('activo', e.target.value === 'true')}>
                <option value="true">Activo</option><option value="false">Inactivo</option>
              </select>
            </div>
          )}
        </Modal>
      )}
    </div>
  )
}
