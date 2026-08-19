// src/components/Forms/ComprobanteForm.jsx
// Formulario reutilizable para Factura, Presupuesto y Remito
import { useState } from 'react'
import { ItemsTable, TotalesBox, TotalesBoxMulti, Modal } from '../UI'
import { calcTotalesMulti } from '../../utils'
import { usePalletsVacios } from '../../hooks/usePalletsVacios'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0, pallets: 1, unidades_por_pallet: 1 }

export default function ComprobanteForm({
  title,
  tipo,           // 'factura' | 'presupuesto' | 'remito'
  initial = {},
  clientes = [],
  productos = [],
  remitos = [],   // solo para facturas
  alicuotas = [], // [{ id, porcentaje }] — activa el IVA multi-alícuota (sólo en facturas)
  onSave,
  onClose,
  warnVencido = false,
}) {
  // IVA multi-alícuota: sólo en facturas (presupuesto/remito siguen en 21% por defecto).
  const multiIva = tipo === 'factura' && alicuotas.length > 0
  const alic21 = alicuotas.find(a => +a.porcentaje === 21)
  const alicuotasById = Object.fromEntries(alicuotas.map(a => [a.id, a]))
  const [form, setForm]   = useState({
    cliente_id:       initial.cliente_id || '',
    descuento_general: initial.descuento_general || 0,
    items:            initial.items?.map(it => ({ ...it })) || [],
    observaciones:    initial.observaciones || '',
    remito_id:        initial.remito_id || '',
    presupuesto_id:   initial.presupuesto_id || '',
    tipo_fac:         initial.tipo || 'A',
    ...initial,
  })
  const [loading, setLoading] = useState(false)
  const [showWarn, setShowWarn] = useState(warnVencido)

  usePalletsVacios(form.items, (items) => setForm(f => ({ ...f, items })), productos)

  // Auto-aplicar descuento del cliente al seleccionarlo
  const onCliChange = (cliId) => {
    const cl = clientes.find(c => c.id === +cliId)
    setForm(f => ({
      ...f,
      cliente_id: cliId,
      descuento_general: cl?.descuento_porcentaje ?? f.descuento_general,
    }))
  }

  // Al seleccionar un remito pendiente, traer sus items
  const onRemitoChange = (remId) => {
    const rem = remitos.find(r => r.id === +remId)
    if (rem) {
      setForm(f => ({
        ...f,
        remito_id: remId,
        items: rem.items?.map(it => ({ ...it })) || f.items,
      }))
    } else {
      setForm(f => ({ ...f, remito_id: '' }))
    }
  }

  const addItem = () =>
    setForm(f => ({ ...f, items: [...f.items, { ...ITEM_BASE, ...(multiIva && { alicuota_iva_id: alic21?.id }) }] }))

  const save = async (forzar = false) => {
    if (!form.cliente_id)   { toast.error('Seleccione un cliente'); return }
    if (!form.items.length) { toast.error('Agregue al menos un ítem'); return }
    const payload = {
      cliente_id:        +form.cliente_id,
      descuento_general: +form.descuento_general || 0,
      items:             form.items,
      observaciones:     form.observaciones,
      ...(tipo === 'factura' && { tipo: form.tipo_fac, remito_id: form.remito_id ? +form.remito_id : null }),
      ...(tipo === 'factura' && form.presupuesto_id && { presupuesto_id: +form.presupuesto_id }),
      ...(forzar && { forzar_vencido: true }),
    }
    setLoading(true)
    try {
      await onSave(payload)
    } catch (err) {
      // 422 = presupuesto vencido, mostrar advertencia
      if (err.response?.status === 422) setShowWarn(true)
    } finally {
      setLoading(false)
    }
  }

  const totMulti = multiIva ? calcTotalesMulti(form.items, form.descuento_general, alicuotasById) : null

  return (
    <Modal
      title={title}
      size="xl"
      onClose={onClose}
      footer={
        <>
          <button className="btn btn-secondary" onClick={onClose} disabled={loading}>Cancelar</button>
          <button className="btn btn-primary" onClick={() => save(false)} disabled={loading}>
            {loading ? 'Guardando…' : '✓ Guardar'}
          </button>
        </>
      }
    >
      {showWarn && (
        <div className="warn-box">
          <span>⚠️</span>
          <div>
            <strong>Presupuesto vencido.</strong> Los precios pueden haber cambiado.
            ¿Desea continuar igualmente?
            <div style={{ marginTop: 8, display: 'flex', gap: 8 }}>
              <button className="btn btn-secondary btn-sm" onClick={() => { setShowWarn(false); onClose() }}>Cancelar</button>
              <button className="btn btn-orange btn-sm" onClick={() => { setShowWarn(false); save(true) }}>Continuar con precios actuales</button>
            </div>
          </div>
        </div>
      )}

      <div className="form-row3" style={{ marginBottom: 14 }}>
        {/* Cliente */}
        <div className="field" style={{ gridColumn: tipo === 'factura' ? '1 / 3' : '1 / 3' }}>
          <label className="lbl">Cliente *</label>
          <select className="sel" value={form.cliente_id} onChange={e => onCliChange(e.target.value)}>
            <option value="">— Seleccionar cliente —</option>
            {clientes.filter(c => c.activo !== false).map(c => (
              <option key={c.id} value={c.id}>{c.razon_social} — {c.cuit}</option>
            ))}
          </select>
        </div>

        {/* Tipo factura */}
        {tipo === 'factura' && (
          <div className="field">
            <label className="lbl">Tipo</label>
            <select className="sel" value={form.tipo_fac} onChange={e => setForm(f => ({ ...f, tipo_fac: e.target.value }))}>
              <option value="A">Factura A</option>
              <option value="B">Factura B</option>
            </select>
          </div>
        )}
      </div>

      {/* Remito vinculado (solo en facturas) */}
      {tipo === 'factura' && remitos.length > 0 && (
        <div className="field" style={{ marginBottom: 14 }}>
          <label className="lbl">Remito pendiente a facturar</label>
          <select className="sel" value={form.remito_id || ''} onChange={e => onRemitoChange(e.target.value)}>
            <option value="">— Sin remito vinculado —</option>
            {remitos.map(r => (
              <option key={r.id} value={r.id}>{r.numero} — {r.items?.length || 0} ítem(s)</option>
            ))}
          </select>
        </div>
      )}

      {/* Descuento general */}
      <div className="form-row3" style={{ marginBottom: 14 }}>
        <div className="field">
          <label className="lbl">Descuento general (%)</label>
          <select className="sel" value={form.descuento_general} onChange={e => setForm(f => ({ ...f, descuento_general: +e.target.value }))}>
            <option value={0}>Sin descuento</option>
            <option value={10}>10%</option>
            <option value={15}>15%</option>
            <option value={20}>20%</option>
          </select>
        </div>
        <div className="field" style={{ gridColumn: '2 / 4' }}>
          <label className="lbl">Observaciones</label>
          <input className="inp" value={form.observaciones || ''} onChange={e => setForm(f => ({ ...f, observaciones: e.target.value }))} />
        </div>
      </div>

      {/* Items */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
        <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px' }}>Ítems</span>
        <button className="btn btn-secondary btn-sm" onClick={addItem}>+ Agregar ítem</button>
      </div>

      <ItemsTable
        items={form.items}
        productos={productos}
        alicuotas={multiIva ? alicuotas : []}
        onChange={items => setForm(f => ({ ...f, items }))}
      />

      {multiIva
        ? <TotalesBoxMulti totales={totMulti} />
        : <TotalesBox items={form.items} dtoGeneral={form.descuento_general} />}
    </Modal>
  )
}
