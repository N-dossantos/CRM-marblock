// src/views/ContabilidadPlanCuentas/index.jsx
// ABM del plan de cuentas (Fase E). El árbol se ordena por `codigo` y se indenta por `nivel`;
// sólo las cuentas imputables pueden recibir líneas de asiento (lo valida crear_asiento).
import { useState, useEffect, useCallback } from 'react'
import { PlanCuentasAPI } from '../../api'
import { Modal, Loading, EmptyState } from '../../components/UI'
import toast from 'react-hot-toast'

const BLANK = {
  codigo: '', descripcion: '', tipo_cuenta: 'Activo',
  cuenta_padre_id: '', nivel: 1, imputable: true,
}
const TIPOS = ['Activo', 'Pasivo', 'Patrimonio', 'Ingreso', 'Egreso', 'Orden']

const TIPO_COLOR = {
  Activo:     'var(--blue-600)',
  Pasivo:     'var(--red-500)',
  Patrimonio: '#7c3aed',
  Ingreso:    'var(--green-600)',
  Egreso:     '#d97706',
  Orden:      'var(--gray-500)',
}

export default function ContabilidadPlanCuentas() {
  const [rows, setRows]       = useState([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch]   = useState('')
  const [modal, setModal]     = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    PlanCuentasAPI.list({ q: search }).then(setRows).finally(() => setLoading(false))
  }, [search])

  useEffect(() => { load() }, [load])

  const openNew  = () => setModal({ form: { ...BLANK }, isNew: true })
  const openEdit = (c) => setModal({
    form: { ...c, cuenta_padre_id: c.cuenta_padre_id ?? '' },
    isNew: false,
  })
  const upd = (field, val) => setModal(m => ({ ...m, form: { ...m.form, [field]: val } }))

  const save = async () => {
    const { form, isNew } = modal
    if (!form.codigo.trim())      { toast.error('Código obligatorio'); return }
    if (!form.descripcion.trim()) { toast.error('Descripción obligatoria'); return }
    try {
      if (isNew) await PlanCuentasAPI.create(form)
      else       await PlanCuentasAPI.update(form.id, form)
      toast.success(isNew ? 'Cuenta creada' : 'Cuenta actualizada')
      setModal(null); load()
    } catch {}
  }

  // Candidatas a padre: cualquier cuenta menos la que se está editando (evita el ciclo trivial).
  const padres = rows.filter(c => !modal || modal.isNew || c.id !== modal.form.id)

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar por código o descripción…" value={search} onChange={e => setSearch(e.target.value)} />
        </div>
        <button className="btn btn-primary" onClick={openNew}>+ Nueva cuenta</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th style={{ width: 180 }}>Código</th><th>Descripción</th>
                <th style={{ width: 120 }}>Tipo</th>
                <th style={{ width: 100 }}>Imputable</th>
                <th style={{ width: 80 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="📗" message="Sin cuentas — el plan se espeja de Tango o se carga a mano" /> : rows.map(c => (
                <tr key={c.id} style={{ opacity: c.activo ? 1 : 0.5 }}>
                  <td><span className="code" style={{ fontWeight: 700 }}>{c.codigo}</span></td>
                  <td
                    className={c.imputable ? '' : 'td-bold'}
                    style={{ paddingLeft: 12 + (Math.max(1, c.nivel) - 1) * 18 }}
                  >
                    {c.descripcion}
                  </td>
                  <td style={{ fontSize: 12, fontWeight: 600, color: TIPO_COLOR[c.tipo_cuenta] || 'var(--gray-500)' }}>
                    {c.tipo_cuenta}
                  </td>
                  <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>
                    {c.imputable ? '✓ Imputable' : 'Agrupación'}
                  </td>
                  <td><button className="btn btn-ghost btn-sm" onClick={() => openEdit(c)}>Editar</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {modal && (
        <Modal
          title={modal.isNew ? 'Nueva cuenta' : 'Editar cuenta'}
          size="md"
          onClose={() => setModal(null)}
          footer={
            <>
              <button className="btn btn-secondary" onClick={() => setModal(null)}>Cancelar</button>
              <button className="btn btn-primary" onClick={save}>✓ Guardar</button>
            </>
          }
        >
          <div className="form-row2">
            <div className="field">
              <label className="lbl">Código *</label>
              <input className="inp" placeholder="1.1.01.001" value={modal.form.codigo} onChange={e => upd('codigo', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Tipo de cuenta</label>
              <select className="sel" value={modal.form.tipo_cuenta} onChange={e => upd('tipo_cuenta', e.target.value)}>
                {TIPOS.map(t => <option key={t} value={t}>{t}</option>)}
              </select>
            </div>
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Descripción *</label>
              <input className="inp" value={modal.form.descripcion} onChange={e => upd('descripcion', e.target.value)} />
            </div>
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Cuenta padre (opcional)</label>
              <select className="sel" value={modal.form.cuenta_padre_id} onChange={e => upd('cuenta_padre_id', e.target.value)}>
                <option value="">— Sin padre (raíz) —</option>
                {padres.map(c => <option key={c.id} value={c.id}>{c.codigo} — {c.descripcion}</option>)}
              </select>
            </div>
            <div className="field">
              <label className="lbl">Nivel</label>
              <input type="number" className="inp inp-right" min="1" max="9" value={modal.form.nivel} onChange={e => upd('nivel', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Imputable</label>
              <select className="sel" value={modal.form.imputable ? 'true' : 'false'} onChange={e => upd('imputable', e.target.value === 'true')}>
                <option value="true">Sí — recibe asientos</option>
                <option value="false">No — sólo agrupación</option>
              </select>
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
        </Modal>
      )}
    </div>
  )
}
