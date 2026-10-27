// src/views/Notas/NotaForm.jsx
import { useState } from 'react'
import { Modal, ItemsTable, TotalesBox, TotalesBoxMulti } from '../../components/UI'
import { $ar, fFecha, calcTotalesMulti } from '../../utils'
import { revisarEmision } from '../../components/Arca'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 0, precio_unitario: 0, descuento_item: 0, pallets: 1, unidades_por_pallet: 1 }

// `nota`: para corregir un borrador o rechazado (actualizar_nota). El tipo y la factura no cambian:
// para eso se descarta la nota y se crea otra.
// onSave(payload, { emitir }): `emitir` pide además el CAE a ARCA.
export default function NotaForm({ factura, nota = null, productos = [], alicuotas = [], onSave, onClose }) {
  const multiIva = alicuotas.length > 0
  const alic21 = alicuotas.find(a => +a.porcentaje === 21)
  const alicuotasById = Object.fromEntries(alicuotas.map(a => [a.id, a]))
  const [form, setForm]   = useState(() => nota
    ? { tipo: nota.tipo, motivo: nota.motivo || '', items: (nota.items || []).map(it => ({ ...it })), observaciones: nota.observaciones || '' }
    : { tipo: 'NC', motivo: '', items: [], observaciones: '' })
  const [loading, setLoading] = useState(null)   // null | 'guardar' | 'emitir'
  // Mientras guarda o emite no se cierra: el resultado se perdería de vista.
  const cerrar = () => { if (!loading) onClose() }

  // Validación previa a ARCA (§5): la nota hereda la letra de la factura y va al cliente de la
  // factura con su condición IVA actual. La base lo vuelve a controlar al emitir.
  const { bloqueos, avisos } = revisarEmision('notas', {
    tipo_letra: factura.tipo, clase: factura.clase, condicion_iva: factura.condicion_iva,
    doc_tipo: factura.doc_tipo, doc_nro: factura.doc_nro,
    percepciones_monto: nota?.percepciones_monto || 0,
    factura_estado_fiscal: factura.estado_fiscal, factura_numero: factura.numero,
  })

  const addItem = () => setForm(f => ({ ...f, items: [...f.items, { ...ITEM_BASE, ...(multiIva && { alicuota_iva_id: alic21?.id }) }] }))

  // Ítems de la factura para copiar a la nota. crear_nota calcula con descuento general 0, así que
  // el descuento general de la factura se combina en el descuento de cada ítem —
  // 1 − (1 − ítem)(1 − general) — salvo pallets vacíos y transporte, que en la factura tampoco lo
  // llevaron (crm_calc_totales_multi_alicuota los excluye). Así la nota repite el precio neto que
  // se facturó.
  const dtoGeneral = +factura.descuento_general || 0
  const itemsFactura = factura.items || []
  const desdeFactura = (it) => {
    const excluido = it.es_pallet_vacio || it.es_transporte
    const di = +it.descuento_item || 0
    const combinado = excluido || !dtoGeneral ? di : 100 * (1 - (1 - di / 100) * (1 - dtoGeneral / 100))
    return {
      _fac_item_id:        it.id,
      producto_id:         it.producto_id ?? '',
      descripcion:         it.descripcion || '',
      cantidad:            +it.cantidad || 0,
      precio_unitario:     +it.precio_unitario || 0,
      descuento_item:      Math.round(combinado * 100) / 100,
      pallets:             it.pallets ?? 1,
      unidades_por_pallet: it.unidades_por_pallet ?? 1,
      es_pallet_vacio:     !!it.es_pallet_vacio,
      es_transporte:       !!it.es_transporte,
      ...(multiIva && { alicuota_iva_id: it.alicuota_iva_id ?? alic21?.id }),
    }
  }
  const marcado = (it) => form.items.some(x => x._fac_item_id === it.id)
  const toggleItemFactura = (it) => setForm(f => ({
    ...f,
    items: f.items.some(x => x._fac_item_id === it.id)
      ? f.items.filter(x => x._fac_item_id !== it.id)
      : [...f.items, desdeFactura(it)],
  }))

  const save = async (emitir) => {
    if (!form.items.length) { toast.error('Agregue al menos un ítem'); return }
    if (!form.motivo.trim()) { toast.error('El motivo es obligatorio'); return }
    setLoading(emitir ? 'emitir' : 'guardar')
    try {
      await onSave({
        factura_id:   factura.id,
        tipo:         form.tipo,
        motivo:       form.motivo,
        // `_fac_item_id` es sólo para saber qué renglón vino de qué ítem de la factura.
        items:        form.items.map(({ _fac_item_id, ...it }) => it),
        observaciones: form.observaciones,
      }, { emitir })
    } finally {
      setLoading(null)
    }
  }

  const nombre = `Nota de ${form.tipo === 'NC' ? 'Crédito' : 'Débito'} ${factura.tipo}`
  return (
    <Modal
      calendario={false}
      title={`${nota ? 'Editar borrador — ' : 'Nueva '}${nombre} — Fac. ${factura.numero}`}
      size="xl"
      onClose={cerrar}
      footer={
        <>
          {loading === 'emitir' && (
            <span className="arca-ocupado" style={{ marginRight: 'auto' }}>
              <span className="arca-spinner" aria-hidden />Emitiendo en ARCA… puede tardar hasta 15 segundos.
            </span>
          )}
          <button className="btn btn-secondary" onClick={cerrar} disabled={!!loading}>Cancelar</button>
          <button className="btn btn-secondary" onClick={() => save(false)} disabled={!!loading}>
            {loading === 'guardar' ? 'Guardando…' : 'Guardar borrador'}
          </button>
          <button className="btn btn-primary" onClick={() => save(true)} disabled={!!loading || bloqueos.length > 0}
            title={bloqueos.length ? 'Hay datos que impiden emitir: ver el aviso' : 'Guarda la nota y pide el CAE a ARCA'}>
            {loading === 'emitir' ? 'Emitiendo…' : '⚡ Guardar y emitir en ARCA'}
          </button>
        </>
      }
    >
      {/* Factura de referencia */}
      <div className="info-box" style={{ marginBottom: 16 }}>
        <strong>Factura de referencia:</strong> {factura.numero} — {factura.razon_social} — {$ar(factura.total)} — {fFecha(factura.fecha)}
      </div>

      {bloqueos.length > 0 && (
        <div className="warn-box">
          <span>⚠️</span>
          <div>
            <strong>Esta nota no se va a poder emitir en ARCA</strong> hasta resolver:
            <ul style={{ margin: '4px 0 0', paddingLeft: 18 }}>{bloqueos.map((b, i) => <li key={i}>{b}</li>)}</ul>
            Se puede guardar como borrador.
          </div>
        </div>
      )}
      {avisos.map((a, i) => <div key={i} className="warn-box"><span>ℹ️</span><div>{a}</div></div>)}

      <div className="form-row3" style={{ marginBottom: 14 }}>
        <div className="field">
          <label className="lbl">Tipo de nota</label>
          <select className="sel" value={form.tipo} disabled={!!nota} onChange={e => setForm(f => ({ ...f, tipo: e.target.value }))}>
            <option value="NC">Nota de Crédito</option>
            <option value="ND">Nota de Débito</option>
          </select>
        </div>
        <div className="field" style={{ gridColumn: '2 / 4' }}>
          <label className="lbl">Motivo *</label>
          <input className="inp" value={form.motivo} onChange={e => setForm(f => ({ ...f, motivo: e.target.value }))}
            placeholder={form.tipo === 'NC' ? 'Ej: Devolución parcial de mercadería' : 'Ej: Diferencia de precio'} />
        </div>
      </div>

      {itemsFactura.length > 0 && (
        <div className="field" style={{ marginBottom: 14 }}>
          <label className="lbl">
            Ítems de la factura — marcá los que van en la nota (la cantidad se ajusta abajo)
            {dtoGeneral > 0 && ` · descuento general ${dtoGeneral}% incluido`}
          </label>
          <div style={{ border: '1px solid var(--gray-200)', borderRadius: 8, maxHeight: 220, overflowY: 'auto' }}>
            {itemsFactura.map(it => (
              <label key={it.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '7px 14px', borderBottom: '1px solid var(--gray-100)', cursor: 'pointer' }}>
                <input type="checkbox" checked={marcado(it)} onChange={() => toggleItemFactura(it)} />
                {it.codigo && <span className="code">{it.codigo}</span>}
                <span style={{ flex: 1 }}>{it.descripcion}</span>
                <span style={{ fontSize: 'calc(12px * var(--font-scale))', color: 'var(--gray-500)' }}>{+it.cantidad} × {$ar(it.precio_unitario)}{+it.descuento_item ? ` −${+it.descuento_item}%` : ''}</span>
                <span style={{ fontWeight: 700, minWidth: 100, textAlign: 'right' }}>{$ar(it.subtotal)}</span>
              </label>
            ))}
          </div>
        </div>
      )}

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
        <span className="lbl" style={{ margin: 0 }}>Ítems</span>
        <button className="btn btn-secondary btn-sm" onClick={addItem}>+ Agregar ítem</button>
      </div>

      <ItemsTable
        items={form.items}
        productos={productos}
        alicuotas={multiIva ? alicuotas : []}
        onChange={items => setForm(f => ({ ...f, items }))}
      />

      {multiIva
        ? <TotalesBoxMulti totales={calcTotalesMulti(form.items, 0, alicuotasById)} />
        : <TotalesBox items={form.items} dtoGeneral={0} />}

      <div className="field" style={{ marginTop: 14 }}>
        <label className="lbl">Observaciones</label>
        <input className="inp" value={form.observaciones} onChange={e => setForm(f => ({ ...f, observaciones: e.target.value }))} />
      </div>
    </Modal>
  )
}
