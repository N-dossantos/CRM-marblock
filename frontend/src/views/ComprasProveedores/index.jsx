// src/views/ComprasProveedores/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { ProveedoresAPI } from '../../api'
import { $ar } from '../../utils'
import { Modal, Loading, EmptyState } from '../../components/UI'
import toast from 'react-hot-toast'

const BLANK = {
  razon_social: '', cuit: '', condicion_iva: 'Resp. Inscripto', condicion_compra: 'Cuenta Corriente',
  actividad: '', numero_ingresos_brutos: '', clasificacion_bienes_servicios: 'Bienes',
  direccion: '', localidad: '', provincia: 'Buenos Aires', telefono: '', email: '', notas: '',
}

export default function ComprasProveedores() {
  const [rows, setRows]       = useState([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch]   = useState('')
  const [modal, setModal]     = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    ProveedoresAPI.list({ q: search }).then(setRows).finally(() => setLoading(false))
  }, [search])

  useEffect(() => { load() }, [load])

  const openNew  = () => setModal({ form: { ...BLANK }, isNew: true })
  const openEdit = (p) => setModal({ form: { ...p }, isNew: false })
  const upd = (field, val) => setModal(m => ({ ...m, form: { ...m.form, [field]: val } }))

  const save = async () => {
    const { form, isNew } = modal
    if (!form.razon_social.trim()) { toast.error('Razón social obligatoria'); return }
    if (!form.cuit.trim())         { toast.error('CUIT obligatorio'); return }
    try {
      if (isNew) await ProveedoresAPI.create(form)
      else       await ProveedoresAPI.update(form.id, form)
      toast.success(isNew ? 'Proveedor creado' : 'Proveedor actualizado')
      setModal(null); load()
    } catch {}
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar por razón social o CUIT…" value={search} onChange={e => setSearch(e.target.value)} />
        </div>
        <button className="btn btn-primary" onClick={openNew}>+ Nuevo proveedor</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Razón Social</th><th>CUIT</th><th>Cond. IVA</th><th>Cond. Compra</th>
                <th>Teléfono</th><th className="th-right">Comprado</th><th className="th-right">Saldo</th>
                <th style={{ width: 80 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="🏭" message="Sin proveedores" /> : rows.map(p => (
                <tr key={p.id}>
                  <td>
                    <div className="td-bold">{p.razon_social}</div>
                    <div style={{ fontSize: 12, color: 'var(--gray-400)' }}>{p.email}</div>
                  </td>
                  <td className="td-mono">{p.cuit}</td>
                  <td style={{ fontSize: 12 }}>{p.condicion_iva}</td>
                  <td style={{ fontSize: 12 }}>{p.condicion_compra}</td>
                  <td style={{ fontSize: 12 }}>{p.telefono || '—'}</td>
                  <td className="td-right">{$ar(p.total_comprado || 0)}</td>
                  <td className="td-right" style={{ color: +p.saldo_pendiente > 0 ? 'var(--red-500)' : 'var(--green-600)', fontWeight: 600 }}>
                    {$ar(p.saldo_pendiente || 0)}
                  </td>
                  <td><button className="btn btn-ghost btn-sm" onClick={() => openEdit(p)}>Editar</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {modal && (
        <Modal
          title={modal.isNew ? 'Nuevo proveedor' : 'Editar proveedor'}
          size="lg"
          onClose={() => setModal(null)}
          footer={
            <>
              <button className="btn btn-secondary" onClick={() => setModal(null)}>Cancelar</button>
              <button className="btn btn-primary" onClick={save}>✓ Guardar</button>
            </>
          }
        >
          <div className="form-row2">
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Razón Social *</label>
              <input className="inp" value={modal.form.razon_social} onChange={e => upd('razon_social', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">CUIT *</label>
              <input className="inp" value={modal.form.cuit} onChange={e => upd('cuit', e.target.value)} placeholder="30-12345678-9" />
            </div>
            <div className="field">
              <label className="lbl">Condición IVA</label>
              <select className="sel" value={modal.form.condicion_iva} onChange={e => upd('condicion_iva', e.target.value)}>
                <option>Resp. Inscripto</option><option>Monotributista</option><option>Exento</option><option>Consumidor Final</option>
              </select>
            </div>
            <div className="field">
              <label className="lbl">Condición de compra</label>
              <select className="sel" value={modal.form.condicion_compra} onChange={e => upd('condicion_compra', e.target.value)}>
                <option>Cuenta Corriente</option><option>Contado</option>
              </select>
            </div>
            <div className="field">
              <label className="lbl">Clasificación</label>
              <select className="sel" value={modal.form.clasificacion_bienes_servicios} onChange={e => upd('clasificacion_bienes_servicios', e.target.value)}>
                <option>Bienes</option><option>Servicios</option><option>Bienes y Servicios</option>
              </select>
            </div>
            <div className="field">
              <label className="lbl">Actividad</label>
              <input className="inp" value={modal.form.actividad || ''} onChange={e => upd('actividad', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Ingresos Brutos</label>
              <input className="inp" value={modal.form.numero_ingresos_brutos || ''} onChange={e => upd('numero_ingresos_brutos', e.target.value)} />
            </div>
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Dirección</label>
              <input className="inp" value={modal.form.direccion || ''} onChange={e => upd('direccion', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Localidad</label>
              <input className="inp" value={modal.form.localidad || ''} onChange={e => upd('localidad', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Provincia</label>
              <input className="inp" value={modal.form.provincia || ''} onChange={e => upd('provincia', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Teléfono</label>
              <input className="inp" value={modal.form.telefono || ''} onChange={e => upd('telefono', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Email</label>
              <input className="inp" type="email" value={modal.form.email || ''} onChange={e => upd('email', e.target.value)} />
            </div>
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Notas internas</label>
              <textarea className="textarea" value={modal.form.notas || ''} onChange={e => upd('notas', e.target.value)} />
            </div>
          </div>
        </Modal>
      )}
    </div>
  )
}
