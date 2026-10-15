// src/views/Clientes/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { ClientesAPI, CondicionesIvaAPI } from '../../api'
import { $ar, fDocNro, cuitValido } from '../../utils'
import { Modal, Loading, EmptyState } from '../../components/UI'
import toast from 'react-hot-toast'

// La condición IVA no tiene valor por defecto: decide la letra de la factura (§3.2 de PLAN_ARCA).
const BLANK = { razon_social: '', doc_tipo: 80, doc_nro: '', condicion_iva_afip_id: '', direccion: '', localidad: '', telefono: '', email: '', descuento_porcentaje: 0, notas: '' }

export default function Clientes() {
  const [rows, setRows]       = useState([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch]   = useState('')
  const [modal, setModal]     = useState(null)  // null | { form, isNew }
  const [condiciones, setCondiciones] = useState([])

  useEffect(() => { CondicionesIvaAPI.list().then(setCondiciones) }, [])

  const load = useCallback(() => {
    setLoading(true)
    ClientesAPI.list({ q: search }).then(setRows).finally(() => setLoading(false))
  }, [search])

  useEffect(() => { load() }, [load])

  const openNew  = () => setModal({ form: { ...BLANK }, isNew: true })
  const openEdit = (c) => setModal({ form: { ...c, doc_nro: fDocNro(c.doc_tipo, c.doc_nro) }, isNew: false })

  const save = async () => {
    const { form, isNew } = modal
    if (!form.razon_social.trim()) { toast.error('Razón social obligatoria'); return }
    const nro = String(form.doc_nro || '').replace(/\D/g, '')
    if (+form.doc_tipo === 80 && !cuitValido(nro)) { toast.error('CUIT inválido: revisá los 11 dígitos'); return }
    if (+form.doc_tipo === 96 && !/^\d{7,8}$/.test(nro)) { toast.error('El DNI tiene que tener 7 u 8 dígitos'); return }
    if (!form.condicion_iva_afip_id) { toast.error('Condición IVA obligatoria'); return }
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
          <input className="search-inp" placeholder="Buscar por razón social, CUIT o DNI…" value={search} onChange={e => setSearch(e.target.value)} />
        </div>
        <button className="btn btn-primary" onClick={openNew}>+ Nuevo cliente</button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Razón Social</th>
                <th>CUIT / DNI</th>
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
                    <td className="td-mono">{fDocNro(c.doc_tipo, c.doc_nro)}</td>
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
              <label className="lbl">Documento *</label>
              <div style={{ display: 'flex', gap: 6 }}>
                <select className="sel" style={{ width: 90 }} value={modal.form.doc_tipo} onChange={e => upd('doc_tipo', +e.target.value)}>
                  <option value={80}>CUIT</option>
                  <option value={96}>DNI</option>
                </select>
                <input className="inp" value={modal.form.doc_nro} onChange={e => upd('doc_nro', e.target.value)}
                  placeholder={+modal.form.doc_tipo === 80 ? '30-12345678-9' : '12345678'} />
              </div>
            </div>
            <div className="field">
              <label className="lbl">Condición IVA *</label>
              <select className="sel" value={modal.form.condicion_iva_afip_id} onChange={e => upd('condicion_iva_afip_id', e.target.value)}>
                <option value="">Elegir…</option>
                {condiciones.map(ci => (
                  <option key={ci.id} value={ci.id}>{ci.descripcion} — Factura {ci.clase}</option>
                ))}
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
