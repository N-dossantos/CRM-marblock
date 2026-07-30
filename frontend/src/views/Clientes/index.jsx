// src/views/Clientes/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { ClientesAPI } from '../../api'
import { $ar } from '../../utils'
import { Modal, Loading, EmptyState } from '../../components/UI'
import toast from 'react-hot-toast'

const BLANK = { razon_social: '', cuit: '', condicion_iva: 'Resp. Inscripto', direccion: '', localidad: '', telefono: '', email: '', descuento_porcentaje: 0, notas: '' }

export default function Clientes() {
  const [rows, setRows]       = useState([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch]   = useState('')
  const [modal, setModal]     = useState(null)  // null | { form, isNew }

  const load = useCallback(() => {
    setLoading(true)
    ClientesAPI.list({ q: search }).then(setRows).finally(() => setLoading(false))
  }, [search])

  useEffect(() => { load() }, [load])

  const openNew  = () => setModal({ form: { ...BLANK }, isNew: true })
  const openEdit = (c) => setModal({ form: { ...c }, isNew: false })

  const save = async () => {
    const { form, isNew } = modal
    if (!form.razon_social.trim()) { toast.error('Razón social obligatoria'); return }
    if (!form.cuit.trim())         { toast.error('CUIT obligatorio'); return }
    try {
      if (isNew) await ClientesAPI.create(form)
      else       await ClientesAPI.update(form.id, form)
      toast.success(isNew ? 'Cliente creado' : 'Cliente actualizado')
      setModal(null)
      load()
    } catch {}
  }

  const upd = (field, val) =>
    setModal(m => ({ ...m, form: { ...m.form, [field]: val } }))

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar por razón social o CUIT…" value={search} onChange={e => setSearch(e.target.value)} />
        </div>
        <button className="btn btn-primary" onClick={openNew}>+ Nuevo cliente</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Razón Social</th>
                <th>CUIT</th>
                <th>Condición IVA</th>
                <th>Localidad</th>
                <th>Teléfono</th>
                <th>Descuento</th>
                <th>Facturado</th>
                <th>Saldo</th>
                <th style={{ width: 80 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0
                ? <EmptyState icon="👥" message="Sin clientes" />
                : rows.map(c => (
                  <tr key={c.id}>
                    <td>
                      <div className="td-bold">{c.razon_social}</div>
                      <div style={{ fontSize: 12, color: 'var(--gray-400)' }}>{c.email}</div>
                    </td>
                    <td className="td-mono">{c.cuit}</td>
                    <td style={{ fontSize: 12 }}>{c.condicion_iva}</td>
                    <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{c.localidad || '—'}</td>
                    <td style={{ fontSize: 12 }}>{c.telefono || '—'}</td>
                    <td>
                      <span style={{ fontWeight: 700, color: c.descuento_porcentaje > 0 ? 'var(--blue-600)' : 'var(--gray-400)' }}>
                        {c.descuento_porcentaje}%
                      </span>
                    </td>
                    <td className="td-right">{$ar(c.total_facturado || 0)}</td>
                    <td className="td-right" style={{ color: +c.saldo_pendiente > 0 ? 'var(--red-500)' : 'var(--green-600)', fontWeight: 600 }}>
                      {$ar(c.saldo_pendiente || 0)}
                    </td>
                    <td>
                      <button className="btn btn-ghost btn-sm" onClick={() => openEdit(c)}>Editar</button>
                    </td>
                  </tr>
                ))
              }
            </tbody>
          </table>
        )}
      </div>

      {modal && (
        <Modal
          title={modal.isNew ? 'Nuevo cliente' : 'Editar cliente'}
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
                <option>Resp. Inscripto</option>
                <option>Monotributista</option>
                <option>Exento</option>
                <option>Consumidor Final</option>
              </select>
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
              <label className="lbl">Teléfono</label>
              <input className="inp" value={modal.form.telefono || ''} onChange={e => upd('telefono', e.target.value)} />
            </div>
            <div className="field" style={{ gridColumn: '1 / 3' }}>
              <label className="lbl">Email</label>
              <input className="inp" type="email" value={modal.form.email || ''} onChange={e => upd('email', e.target.value)} />
            </div>
            <div className="field">
              <label className="lbl">Descuento predefinido</label>
              <select className="sel" value={modal.form.descuento_porcentaje} onChange={e => upd('descuento_porcentaje', +e.target.value)}>
                <option value={0}>Sin descuento</option>
                <option value={10}>10%</option>
                <option value={15}>15%</option>
                <option value={20}>20%</option>
              </select>
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
