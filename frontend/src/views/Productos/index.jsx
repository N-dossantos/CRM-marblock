// src/views/Productos/index.jsx
import { useState, useEffect, useCallback } from 'react'
import { ProductosAPI } from '../../api'
import { $ar } from '../../utils'
import { Modal, Loading, EmptyState } from '../../components/UI'
import toast from 'react-hot-toast'

const BLANK = { codigo: '', descripcion: '', precio_sin_iva: 0, unidades_por_pallet: 1, activo: true }

export default function Productos() {
  const [rows, setRows]       = useState([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch]   = useState('')
  const [modal, setModal]     = useState(null)
  const [aumento, setAumento] = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    ProductosAPI.list({ q: search }).then(setRows).finally(() => setLoading(false))
  }, [search])

  useEffect(() => { load() }, [load])

  const upd  = (f, v) => setModal(m => ({ ...m, form: { ...m.form, [f]: v } }))
  const save = async () => {
    const { form, isNew } = modal
    if (!form.codigo.trim() || !form.descripcion.trim()) { toast.error('Código y descripción obligatorios'); return }
    try {
      if (isNew) await ProductosAPI.create(form)
      else       await ProductosAPI.update(form.id, { ...form, precio_sin_iva: +form.precio_sin_iva })
      toast.success('Producto guardado')
      setModal(null); load()
    } catch {}
  }

  const aplicarAumento = async () => {
    const pct = parseFloat(aumento.pct)
    if (!pct || pct <= 0) { toast.error('Porcentaje inválido'); return }
    if (!confirm(`¿Aumentar todos los precios un ${pct}%?`)) return
    try {
      const r = await ProductosAPI.actualizarPrecio(pct)
      toast.success(`Precios actualizados: ${r.actualizados} productos +${pct}%`)
      setAumento(null); load()
    } catch {}
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar producto…" value={search} onChange={e => setSearch(e.target.value)} />
        </div>
        <div className="toolbar-right">
          <button className="btn btn-secondary" onClick={() => setAumento({ pct: 10 })}>📈 Actualizar lista de precios</button>
          <button className="btn btn-primary" onClick={() => setModal({ form: { ...BLANK }, isNew: true })}>+ Nuevo producto</button>
        </div>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Código</th>
                <th>Descripción</th>
                <th className="th-right">Un./Pallet</th>
                <th className="th-right">Precio s/IVA</th>
                <th className="th-right">Precio c/IVA 21%</th>
                <th>Estado</th>
                <th style={{ width: 80 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="📦" message="Sin productos" /> : rows.map(p => (
                <tr key={p.id}>
                  <td><span className="code">{p.codigo}</span></td>
                  <td className="td-bold">{p.descripcion}</td>
                  <td className="td-right">{p.unidades_por_pallet}</td>
                  <td className="td-right">{$ar(p.precio_sin_iva)}</td>
                  <td className="td-right" style={{ color: 'var(--blue-600)', fontWeight: 700 }}>{$ar(p.precio_sin_iva * 1.21)}</td>
                  <td>
                    <span className={`badge ${p.activo ? 'badge-cobrada' : 'badge-anulada'}`}>{p.activo ? 'Activo' : 'Inactivo'}</span>
                  </td>
                  <td><button className="btn btn-ghost btn-sm" onClick={() => setModal({ form: { ...p }, isNew: false })}>Editar</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {modal && (
        <Modal title={modal.isNew ? 'Nuevo producto' : 'Editar producto'} size="sm" onClose={() => setModal(null)}
          footer={<><button className="btn btn-secondary" onClick={() => setModal(null)}>Cancelar</button><button className="btn btn-primary" onClick={save}>✓ Guardar</button></>}
        >
          <div className="field"><label className="lbl">Código *</label><input className="inp" value={modal.form.codigo} onChange={e => upd('codigo', e.target.value)} /></div>
          <div className="field"><label className="lbl">Descripción *</label><input className="inp" value={modal.form.descripcion} onChange={e => upd('descripcion', e.target.value)} /></div>
          <div className="field"><label className="lbl">Precio sin IVA ($)</label><input type="number" className="inp inp-right" value={modal.form.precio_sin_iva} min="0" onChange={e => upd('precio_sin_iva', e.target.value)} /></div>
          <div className="field"><label className="lbl">Unidades por pallet</label><input type="number" className="inp inp-right" value={modal.form.unidades_por_pallet} min="1" step="1" onChange={e => upd('unidades_por_pallet', e.target.value)} /></div>
          <div style={{ background: 'var(--blue-50)', borderRadius: 6, padding: '8px 12px', fontSize: 13, color: 'var(--blue-700)' }}>
            Precio con IVA 21%: <strong>{$ar((+modal.form.precio_sin_iva || 0) * 1.21)}</strong>
          </div>
          {!modal.isNew && (
            <div className="field" style={{ marginTop: 14 }}>
              <label className="lbl">Estado</label>
              <select className="sel" value={modal.form.activo ? 'true' : 'false'} onChange={e => upd('activo', e.target.value === 'true')}>
                <option value="true">Activo</option>
                <option value="false">Inactivo</option>
              </select>
            </div>
          )}
        </Modal>
      )}

      {aumento && (
        <Modal title="Actualizar lista de precios" size="sm" onClose={() => setAumento(null)}
          footer={<><button className="btn btn-secondary" onClick={() => setAumento(null)}>Cancelar</button><button className="btn btn-orange" onClick={aplicarAumento}>Aplicar aumento</button></>}
        >
          <div className="warn-box"><span>⚠️</span><span>Esta acción modifica <strong>todos</strong> los precios activos de forma permanente.</span></div>
          <div className="field">
            <label className="lbl">Porcentaje de aumento (%)</label>
            <input type="number" className="inp inp-right" value={aumento.pct} min="0.1" step="0.1" onChange={e => setAumento(a => ({ ...a, pct: e.target.value }))} />
          </div>
          <div style={{ background: 'var(--gray-50)', borderRadius: 6, padding: '10px 14px', fontSize: 13, color: 'var(--gray-600)', marginTop: 8 }}>
            Ejemplo: precio actual <strong>$ 10.000</strong> → nuevo precio <strong>{$ar(10000 * (1 + (+aumento.pct || 0) / 100))}</strong>
          </div>
        </Modal>
      )}
    </div>
  )
}
