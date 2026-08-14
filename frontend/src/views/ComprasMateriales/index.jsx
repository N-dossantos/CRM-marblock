// src/views/ComprasMateriales/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { MaterialesAPI } from '../../api'
import { $ar } from '../../utils'
import { Modal, Loading, EmptyState } from '../../components/UI'
import toast from 'react-hot-toast'

const BLANK = { codigo: '', descripcion: '', unidad_medida: 'unidad', precio_referencia: 0 }
const UNIDADES = ['unidad', 'kg', 'm3', 'm2', 'metro', 'litro', 'bolsa', 'pallet', 'caja']

export default function ComprasMateriales() {
  const [rows, setRows]       = useState([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch]   = useState('')
  const [modal, setModal]     = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    MaterialesAPI.list({ q: search }).then(setRows).finally(() => setLoading(false))
  }, [search])

  useEffect(() => { load() }, [load])

  const openNew  = () => setModal({ form: { ...BLANK }, isNew: true })
  const openEdit = (m) => setModal({ form: { ...m }, isNew: false })
  const upd = (field, val) => setModal(m => ({ ...m, form: { ...m.form, [field]: val } }))

  const save = async () => {
    const { form, isNew } = modal
    if (!form.codigo.trim())      { toast.error('Código obligatorio'); return }
    if (!form.descripcion.trim()) { toast.error('Descripción obligatoria'); return }
    try {
      if (isNew) await MaterialesAPI.create(form)
      else       await MaterialesAPI.update(form.id, form)
      toast.success(isNew ? 'Material creado' : 'Material actualizado')
      setModal(null); load()
    } catch {}
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar por código o descripción…" value={search} onChange={e => setSearch(e.target.value)} />
        </div>
        <button className="btn btn-primary" onClick={openNew}>+ Nuevo material</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th style={{ width: 120 }}>Código</th><th>Descripción</th>
                <th>Unidad</th><th className="th-right">Precio ref.</th>
                <th style={{ width: 80 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🧱" message="Sin materiales" /> : rows.map(m => (
                <tr key={m.id} style={{ opacity: m.activo ? 1 : 0.5 }}>
                  <td><span className="code" style={{ fontWeight: 700 }}>{m.codigo}</span></td>
                  <td className="td-bold">{m.descripcion}</td>
                  <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{m.unidad_medida}</td>
                  <td className="td-right">{$ar(m.precio_referencia)}</td>
                  <td><button className="btn btn-ghost btn-sm" onClick={() => openEdit(m)}>Editar</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {modal && (
        <Modal
          title={modal.isNew ? 'Nuevo material' : 'Editar material'}
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
              <input className="inp" value={modal.form.codigo} onChange={e => upd('codigo', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Unidad de medida</label>
              <select className="sel" value={modal.form.unidad_medida} onChange={e => upd('unidad_medida', e.target.value)}>
                {UNIDADES.map(u => <option key={u} value={u}>{u}</option>)}
              </select>
            </div>
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Descripción *</label>
              <input className="inp" value={modal.form.descripcion} onChange={e => upd('descripcion', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Precio de referencia</label>
              <input type="number" className="inp inp-right" min="0" value={modal.form.precio_referencia} onChange={e => upd('precio_referencia', e.target.value)} />
            </div>
            {!modal.isNew && (
              <div className="field">
                <label className="lbl">Estado</label>
                <select className="sel" value={modal.form.activo ? 'true' : 'false'} onChange={e => upd('activo', e.target.value === 'true')}>
                  <option value="true">Activo</option><option value="false">Inactivo</option>
                </select>
              </div>
            )}
          </div>
        </Modal>
      )}
    </div>
  )
}
