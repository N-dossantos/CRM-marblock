// src/components/Forms/ComprobanteForm.jsx
// Formulario reutilizable para Factura, Presupuesto y Remito
import { useState, useEffect, useRef } from 'react'
import { ItemsTable, TotalesBox, TotalesBoxMulti, Modal, ClienteSearch } from '../UI'
import { calcTotalesMulti, renglonesDeRemito } from '../../utils'
import { usePalletsVacios } from '../../hooks/usePalletsVacios'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0, pallets: 1, unidades_por_pallet: 1 }

// Renglones que entran en una hoja del talonario preimpreso de remitos: el área de ítems va de
// 110,6 a 251,9 mm a 6 mm por renglón (23), pero se corta en 19 para dejar libre la leyenda
// "la mercadería viaja por cuenta y riesgo del comprador" (y=230 mm). Tiene que coincidir con
// MAPA.items.renglones en supabase/functions/pdf/preimpreso.ts.
const RENGLONES_TALONARIO = 19

// Letra de factura según la condición de IVA del receptor: A a Responsables Inscriptos y, desde
// 2021, también a Monotributistas (con la leyenda "Receptor del comprobante – Responsable
// Monotributo"); B a Consumidor Final y Exento. El CUIT genérico de consumidor final nunca va en A.
const CUIT_CONSUMIDOR_FINAL = '00-00000000-0'
const tipoFacturaPara = (cl) =>
  cl && ['Resp. Inscripto', 'Monotributista'].includes(cl.condicion_iva) && cl.cuit !== CUIT_CONSUMIDOR_FINAL ? 'A' : 'B'

export default function ComprobanteForm({
  title,
  tipo,           // 'factura' | 'presupuesto' | 'remito'
  initial = {},
  clientes = [],
  productos = [],
  remitos = [],   // solo para facturas — los pendientes DEL cliente elegido (los trae el padre)
  remitosLoading = false,
  onClienteChange,  // avisa al padre para que traiga los remitos pendientes de ese cliente
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
  // En una factura ya emitida los remitos quedan 'facturado' y no salen en los pendientes:
  // se muestran como dato, no como selector.
  const esFacturaNueva = tipo === 'factura' && !initial.id
  // IVA multi-alícuota: sólo en facturas (presupuesto/remito siguen en 21% por defecto).
  const multiIva = tipo === 'factura' && alicuotas.length > 0
  const alic21 = alicuotas.find(a => +a.porcentaje === 21)
  const alicuotasById = Object.fromEntries(alicuotas.map(a => [a.id, a]))
  const [form, setForm]   = useState({
    cliente_id:       initial.cliente_id || '',
    descuento_general: initial.descuento_general || 0,
    items:            initial.items?.map(it => ({ ...it })) || [],
    observaciones:    initial.observaciones || '',
    // Una factura puede cubrir varios remitos: la fuente de verdad es remitos.factura_id
    // (FK sin UNIQUE), no facturas.remito_id. Al reabrir una factura los ids vienen en
    // `initial.remitos`; el enlace viejo de un solo remito se sigue aceptando.
    remito_ids:       initial.remito_ids || initial.remitos?.map(r => r.id) || (initial.remito_id ? [+initial.remito_id] : []),
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

  // Los renglones que llegan de un remito o un presupuesto no traen alícuota (esos comprobantes no
  // discriminan IVA). El servidor y los totales ya los toman al 21%, pero el selector de la fila
  // mostraba la primera opción ("0%"): se completa el 21% explícito para que diga lo que se guarda.
  useEffect(() => {
    if (!multiIva || !alic21) return
    if (form.items.every(it => it.alicuota_iva_id)) return
    setForm(f => ({ ...f, items: f.items.map(it => it.alicuota_iva_id ? it : { ...it, alicuota_iva_id: alic21.id }) }))
  }, [multiIva, alic21, form.items])

  // Remito → factura: el remito se emite sin precio (es para el camión), así que cada renglón que
  // llega de un remito con precio 0 toma el precio de lista del producto. Cubre las dos entradas:
  // el checkbox de remitos pendientes y el botón "→ Factura" del listado de remitos (que llega por
  // `initial`, a veces antes de que carguen los productos — por eso es un efecto y no va en el
  // toggle). `_precio_auto` marca el renglón ya resuelto: si el operador después lo pone en 0 a
  // propósito, no se lo vuelve a pisar.
  useEffect(() => {
    if (tipo !== 'factura' || !productos.length) return
    setForm(f => {
      let cambio = false
      const items = f.items.map(it => {
        if (!it._remito_id || it._precio_auto || +it.precio_unitario > 0) return it
        const p = productos.find(p => p.id === +it.producto_id)
        if (!p) return it
        cambio = true
        return { ...it, precio_unitario: +p.precio_sin_iva || 0, _precio_auto: true }
      })
      return cambio ? { ...f, items } : f
    })
  }, [tipo, productos, form.items])

  // Factura nueva que llega con el cliente ya elegido (botón "→ Factura" de un remito): no pasa
  // por onCliChange, así que el descuento del cliente se aplica acá, una sola vez.
  const dtoClienteAplicado = useRef(initial.descuento_general != null || !!initial.id)
  useEffect(() => {
    if (dtoClienteAplicado.current || tipo !== 'factura' || !form.cliente_id) return
    const cl = clientes.find(c => c.id === +form.cliente_id)
    if (!cl) return
    dtoClienteAplicado.current = true
    if (cl.descuento_porcentaje != null) setForm(f => ({ ...f, descuento_general: +cl.descuento_porcentaje }))
  }, [tipo, clientes, form.cliente_id])

  // Misma idea para la letra: si la factura nueva llega con el cliente ya elegido (desde un remito
  // o un presupuesto), se propone A o B según su condición de IVA, una sola vez.
  const tipoClienteAplicado = useRef(!esFacturaNueva || !!initial.tipo)
  useEffect(() => {
    if (tipoClienteAplicado.current || !form.cliente_id) return
    const cl = clientes.find(c => c.id === +form.cliente_id)
    if (!cl) return
    tipoClienteAplicado.current = true
    setForm(f => ({ ...f, tipo_fac: tipoFacturaPara(cl) }))
  }, [clientes, form.cliente_id])

  // Auto-aplicar descuento del cliente al seleccionarlo
  const onCliChange = (cliId) => {
    const cl = clientes.find(c => c.id === +cliId)
    setForm(f => ({
      ...f,
      cliente_id: cliId,
      // Los remitos marcados eran del cliente anterior: se sueltan junto con sus renglones.
      // Los ítems cargados a mano (sin _remito_id) se respetan.
      remito_ids: [],
      items: f.items.filter(it => !it._remito_id),
      descuento_general: cl?.descuento_porcentaje ?? f.descuento_general,
      ...(esFacturaNueva && cl && { tipo_fac: tipoFacturaPara(cl) }),
      // El teléfono del remito se prellena con el del cliente pero queda editable: el de la
      // obra suele ser otro (capataz/obrador) y es el que sirve si hay que llamar en la entrega.
      ...(esRemito && !f.telefono_entrega && cl?.telefono ? { telefono_entrega: cl.telefono } : {}),
    }))
    dtoClienteAplicado.current = true
    tipoClienteAplicado.current = true
    onClienteChange?.(cliId)
  }

  // Marcar/desmarcar un remito agrega o quita SUS renglones, sin tocar el resto: cada ítem que
  // entra queda etiquetado con `_remito_id` (marca de UI, se saca antes de mandar al servidor), así
  // desmarcar no se lleva puesto lo que el operador cargó o trajo de otro remito.
  const onRemitoToggle = (remId) => {
    const id  = +remId
    const rem = remitos.find(r => r.id === id)
    setForm(f => {
      const marcado = f.remito_ids.includes(id)
      return {
        ...f,
        remito_ids: marcado ? f.remito_ids.filter(x => x !== id) : [...f.remito_ids, id],
        items: marcado
          ? f.items.filter(it => it._remito_id !== id)
          // La línea de pallets vacíos de cada remito se descarta si el hook la puede regenerar
          // consolidada (ver renglonesDeRemito): una por remito quedaría huérfana sumando de más.
          : [...f.items, ...renglonesDeRemito(rem)],
      }
    })
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

  // Letra distinta de la que corresponde al cliente: avisa, no bloquea (el operador decide).
  const clienteSel = tipo === 'factura' ? clientes.find(c => c.id === +form.cliente_id) : null
  const letraDesvio = esFacturaNueva && clienteSel && form.tipo_fac !== tipoFacturaPara(clienteSel)

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
      // `_remito_id` / `_precio_auto` son marcas de UI (qué renglón vino de qué remito, y si ya
      // tomó el precio de lista): no van al servidor.
      items:             form.items.map(({ _remito_id, _precio_auto, ...it }) => it),
      observaciones:     form.observaciones,
      ...(esRemitoNuevo && { numero: form.numero.trim() }),
      ...(esRemito && {
        condiciones_venta: form.condiciones_venta?.trim() || null,
        domicilio_obra:    form.domicilio_obra?.trim() || null,
        telefono_entrega:  form.telefono_entrega?.trim() || null,
      }),
      ...(tipo === 'factura' && { tipo: form.tipo_fac, remito_ids: form.remito_ids }),
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

  // Renglones de remito sin producto del catálogo (artículos de Tango que el CRM no tiene: bloques
  // huecos, rodados…): no hay precio de lista que tomar y quedan en 0 hasta que el operador elija
  // el producto o cargue el precio.
  const sinPrecio = tipo === 'factura'
    ? form.items.filter(it => it._remito_id && !it.producto_id && !(+it.precio_unitario > 0)).length
    : 0

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
          <ClienteSearch clientes={clientes} value={form.cliente_id} onChange={onCliChange} />
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

      {letraDesvio && (
        <div className="warn-box" style={{ marginBottom: 14 }}>
          <span>⚠️</span>
          <div>
            {form.tipo_fac === 'A'
              ? <>El cliente es <strong>{clienteSel.cuit === CUIT_CONSUMIDOR_FINAL ? 'consumidor final genérico (sin CUIT)' : clienteSel.condicion_iva}</strong>: le corresponde <strong>Factura B</strong>. Una Factura A necesita un receptor Responsable Inscripto o Monotributista con CUIT.</>
              : <>El cliente es <strong>{clienteSel.condicion_iva}</strong>: le corresponde <strong>Factura A</strong>. Con una Factura B no puede computar el IVA.</>}
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

      {/* Remitos pendientes del cliente (solo en facturas). Se pueden marcar varios: una factura
          puede cubrir todas las entregas del período. */}
      {esFacturaNueva && form.cliente_id && (
        <div className="field" style={{ marginBottom: 14 }}>
          <label className="lbl">Remitos pendientes a facturar</label>
          {remitosLoading ? (
            <div className="rem-pend-vacio">Buscando remitos…</div>
          ) : remitos.length === 0 ? (
            <div className="rem-pend-vacio">Este cliente no tiene remitos pendientes de facturar.</div>
          ) : (
            <div className="rem-pend">
              {remitos.map(r => (
                <label key={r.id} className="rem-pend-row">
                  <input
                    type="checkbox"
                    checked={form.remito_ids.includes(r.id)}
                    onChange={() => onRemitoToggle(r.id)}
                  />
                  <span className="code">{r.numero}</span>
                  <span className="rem-pend-fecha">{r.fecha}</span>
                  <span className="rem-pend-items">{r.items?.length || 0} ítem(s)</span>
                </label>
              ))}
            </div>
          )}
        </div>
      )}

      {tipo === 'factura' && !esFacturaNueva && initial.remitos?.length > 0 && (
        <div className="field" style={{ marginBottom: 14 }}>
          <label className="lbl">Remitos facturados</label>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
            {initial.remitos.map(r => <span key={r.id} className="code">{r.numero}</span>)}
          </div>
        </div>
      )}

      {sinPrecio > 0 && (
        <div className="warn-box" style={{ marginBottom: 14 }}>
          <span>⚠️</span>
          <div>
            {sinPrecio === 1 ? 'Un renglón' : `${sinPrecio} renglones`} del remito no {sinPrecio === 1 ? 'tiene' : 'tienen'} producto
            del catálogo y {sinPrecio === 1 ? 'quedó' : 'quedaron'} sin precio: elegí el producto o cargá el precio a mano.
          </div>
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
