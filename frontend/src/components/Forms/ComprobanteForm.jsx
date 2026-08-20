// src/components/Forms/ComprobanteForm.jsx
// Formulario reutilizable para Factura, Presupuesto y Remito
import { useState } from 'react'
import { ItemsTable, TotalesBox, TotalesBoxMulti, Modal } from '../UI'
import { calcTotalesMulti } from '../../utils'
import { usePalletsVacios } from '../../hooks/usePalletsVacios'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0, pallets: 1, unidades_por_pallet: 1 }

// Renglones que entran en una hoja del talonario preimpreso de remitos: el área de ítems va de
// 110,6 a 251,9 mm a 6 mm por renglón (23), pero se corta en 19 para dejar libre la leyenda
// "la mercadería viaja por cuenta y riesgo del comprador" (y=230 mm). Tiene que coincidir con
// MAPA.items.renglones en supabase/functions/pdf/preimpreso.ts.
const RENGLONES_TALONARIO = 19

export default function ComprobanteForm({
  title,
  tipo,           // 'factura' | 'presupuesto' | 'remito'
  initial = {},
  clientes = [],
  productos = [],
  remitos = [],   // solo para facturas
  alicuotas = [], // [{ id, porcentaje }] — activa el IVA multi-alícuota (sólo en facturas)
  numeroSugerido = null, // { punto_venta, numero, numero_formateado } — sólo para remitos nuevos
  onSave,
  onClose,
  warnVencido = false,
}) {
  // Los remitos de venta se emiten sobre talonario preimpreso: el número lo trae la
  // hoja, no el sistema. Se prellena con la sugerencia, pero lo confirma el operador
  // mirando el papel. En edición no se toca — si la hoja se arruinó el flujo es
  // anular y reemitir, no renumerar.
  const esRemito     = tipo === 'remito'
  const esRemitoNuevo = esRemito && !initial.id
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
    numero:           initial.numero || numeroSugerido?.numero_formateado || '',
    condiciones_venta: initial.condiciones_venta || '',
    domicilio_obra:    initial.domicilio_obra || '',
    telefono_entrega:  initial.telefono_entrega || '',
    ...initial,
  })
  const [loading, setLoading] = useState(false)
  const [showWarn, setShowWarn] = useState(warnVencido)

  // El 4º argumento son los campos que dependen del comprobante: en facturas multi-alícuota la
  // línea automática debe traer alicuota_iva_id como cualquier ítem de "+ Agregar ítem", si no el
  // selector de IVA de esa fila aparece vacío (el total igual sale bien: el servidor asume 21%).
  usePalletsVacios(
    form.items,
    (items) => setForm(f => ({ ...f, items })),
    productos,
    multiIva ? { alicuota_iva_id: alic21?.id } : null,
  )

  // Auto-aplicar descuento del cliente al seleccionarlo
  const onCliChange = (cliId) => {
    const cl = clientes.find(c => c.id === +cliId)
    setForm(f => ({
      ...f,
      cliente_id: cliId,
      descuento_general: cl?.descuento_porcentaje ?? f.descuento_general,
      // El teléfono del remito se prellena con el del cliente pero queda editable: el de la
      // obra suele ser otro (capataz/obrador) y es el que sirve si hay que llamar en la entrega.
      ...(esRemito && !f.telefono_entrega && cl?.telefono ? { telefono_entrega: cl.telefono } : {}),
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

  // Aviso (no bloqueante) cuando el número tipeado se aleja del sugerido: la base impide
  // duplicados, pero no puede detectar un error de tipeo que caiga en un número libre.
  // Sólo compara dentro del mismo punto de venta — un talonario nuevo arranca otra serie
  // y la distancia entre series no significa nada.
  const UMBRAL_DESVIO = 10
  const desvio = (() => {
    if (!esRemitoNuevo || !numeroSugerido) return null
    const m = /^(\d{5})-(\d{8})$/.exec((form.numero || '').trim())
    if (!m || m[1] !== numeroSugerido.punto_venta) return null
    const dif = parseInt(m[2], 10) - numeroSugerido.numero
    return Math.abs(dif) > UMBRAL_DESVIO ? dif : null
  })()

  const save = async (forzar = false) => {
    if (!form.cliente_id)   { toast.error('Seleccione un cliente'); return }
    if (!form.items.length) { toast.error('Agregue al menos un ítem'); return }
    if (esRemitoNuevo && !/^\d{5}-\d{8}$/.test((form.numero || '').trim())) {
      toast.error('El número del remito debe tener el formato 00001-00012345'); return
    }
    // Una hoja del talonario tiene RENGLONES_TALONARIO renglones, y una hoja es un número es
    // un remito: lo que no entra no se puede continuar en otra hoja sin gastar otro número.
    if (esRemito && form.items.length > RENGLONES_TALONARIO) {
      toast.error(`No entran más de ${RENGLONES_TALONARIO} ítems en el formulario. Dividí la entrega en dos remitos.`)
      return
    }
    const payload = {
      cliente_id:        +form.cliente_id,
      descuento_general: +form.descuento_general || 0,
      items:             form.items,
      observaciones:     form.observaciones,
      ...(esRemitoNuevo && { numero: form.numero.trim() }),
      ...(esRemito && {
        condiciones_venta: form.condiciones_venta?.trim() || null,
        domicilio_obra:    form.domicilio_obra?.trim() || null,
        telefono_entrega:  form.telefono_entrega?.trim() || null,
      }),
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

        {/* Número de la hoja del talonario preimpreso (solo remitos) */}
        {esRemito && (
          <div className="field">
            <label className="lbl">N° de remito {esRemitoNuevo && '*'}</label>
            <input
              className="inp"
              value={form.numero || ''}
              readOnly={!esRemitoNuevo}
              placeholder="00001-00012345"
              onChange={e => setForm(f => ({ ...f, numero: e.target.value }))}
              style={{ fontFamily: 'monospace', ...(esRemitoNuevo ? {} : { background: 'var(--gray-50)', color: 'var(--gray-500)' }) }}
            />
          </div>
        )}

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

      {/* Desvío respecto del número sugerido — advierte, no bloquea: puede ser legítimo
          (talonario salteado) o un error de tipeo que la base no puede detectar. */}
      {desvio !== null && (
        <div className="warn-box" style={{ marginBottom: 14 }}>
          <span>⚠️</span>
          <div>
            El número está <strong>{Math.abs(desvio)} hoja(s) {desvio > 0 ? 'adelante' : 'atrás'}</strong> del
            sugerido (<span style={{ fontFamily: 'monospace' }}>{numeroSugerido.numero_formateado}</span>).
            Verificá que coincida con la hoja que pusiste en la impresora.
          </div>
        </div>
      )}

      {/* Campos que exige el formulario preimpreso del talonario (solo remitos) */}
      {esRemito && (
        <div className="form-row3" style={{ marginBottom: 14 }}>
          <div className="field">
            <label className="lbl">Condiciones de venta</label>
            <input
              className="inp"
              list="cond-venta-sugeridas"
              value={form.condiciones_venta || ''}
              placeholder="Contado / Cuenta corriente…"
              onChange={e => setForm(f => ({ ...f, condiciones_venta: e.target.value }))}
            />
            <datalist id="cond-venta-sugeridas">
              <option value="Contado" />
              <option value="Cuenta corriente" />
              <option value="Cuenta corriente 30 días" />
            </datalist>
          </div>
          <div className="field">
            <label className="lbl">Domicilio de obra</label>
            <input
              className="inp"
              value={form.domicilio_obra || ''}
              placeholder="Dónde se entrega"
              onChange={e => setForm(f => ({ ...f, domicilio_obra: e.target.value }))}
            />
          </div>
          <div className="field">
            <label className="lbl">Teléfono de entrega</label>
            <input
              className="inp"
              value={form.telefono_entrega || ''}
              placeholder="Se prellena con el del cliente"
              onChange={e => setForm(f => ({ ...f, telefono_entrega: e.target.value }))}
            />
          </div>
        </div>
      )}

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
