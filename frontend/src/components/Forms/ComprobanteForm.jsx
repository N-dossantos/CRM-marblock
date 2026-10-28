// src/components/Forms/ComprobanteForm.jsx
// Formulario reutilizable para Factura, Presupuesto y Remito
import { useState, useEffect, useRef } from 'react'
import { ItemsTable, TotalesBox, TotalesBoxMulti, Modal, ClienteSearch, agregarProductos } from '../UI'
import { ElegirProductosBtn } from '../UI/ProductoPicker'
import { calcTotalesMulti, renglonesDeRemito, fFecha } from '../../utils'
import { armarItems, revisarRemito, llevaDesdeItems } from '../../utils/pendientes'
import { usePalletsVacios } from '../../hooks/usePalletsVacios'
import { useNumeroRepetido } from '../../hooks/useNumeroRepetido'
import { RemitosAPI, ArcaAPI } from '../../api'
import { revisarEmision } from '../Arca'
import FacturasPendientesRemitir from './FacturasPendientesRemitir'
import toast from 'react-hot-toast'

// Un renglón de remito con asignaciones propias lo armó "Lleva" (no la línea de pallets, que es
// siempre la del hook): se marca para que cambiar "Lleva" lo vuelva a armar en vez de sumar otro.
const deLleva = (it) => !it.es_pallet_vacio && (it.asignaciones || []).some(a => (a.origen ?? 'remito') === 'remito')

const fCant = (x) => (+x || 0).toLocaleString('es-AR', { maximumFractionDigits: 3 })

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 0, precio_unitario: 0, descuento_item: 0, pallets: 1, unidades_por_pallet: 1 }

// Renglones que entran en una hoja del talonario preimpreso de remitos: el área de ítems va de
// 110,6 a 251,9 mm a 6 mm por renglón (23), pero se corta en 19 para dejar libre la leyenda
// "la mercadería viaja por cuenta y riesgo del comprador" (y=230 mm). Tiene que coincidir con
// MAPA.items.renglones en supabase/functions/pdf/preimpreso.ts.
const RENGLONES_TALONARIO = 19

// Tipo de comprobante de ARCA por letra de factura: tiene que coincidir con arca_cbte_tipo('FAC', …).
const CBTE_TIPO_FACTURA = { A: 1, B: 6 }

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
  onSave,         // (payload, { emitir }) — en facturas, `emitir` pide además el CAE a ARCA
  onDelete,       // sólo para presupuestos guardados
  onClose,
  warnVencido = false,
}) {
  // Los remitos de venta se emiten sobre talonario preimpreso: el número lo trae la
  // hoja, no el sistema. Se prellena con la sugerencia, pero lo confirma el operador
  // mirando el papel. En edición no se toca — si la hoja se arruinó el flujo es
  // anular y reemitir, no renumerar.
  const esRemito     = tipo === 'remito'
  const esPresupuesto = tipo === 'presupuesto'
  const esRemitoNuevo = esRemito && !initial.id
  // Una factura sólo se edita mientras es borrador o rechazada (sin CAE). Sus remitos ya están
  // tomados por ella y no salen en los pendientes: se muestran como dato, no como selector. El
  // cliente tampoco cambia: de él dependen la letra y esos remitos.
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
    destinatario: initial.destinatario || initial.razon_social || '',
    // Remito: "Lleva" por factura y producto. En edición arranca con lo que ya asignó el remito.
    ...(esRemito && {
      items: (initial.items || []).map(it => (deLleva(it) ? { ...it, _lleva: true } : { ...it })),
      lleva: llevaDesdeItems(initial.items),
    }),
  })
  const [loading, setLoading] = useState(null)   // null | 'guardar' | 'emitir' | 'eliminar'

  // Remito: las facturas pendientes de remitir del cliente elegido (en edición, sin contar lo que
  // ya asignó este remito) y el aviso de lo que va a quedar sin facturar.
  const [facturasPend, setFacturasPend] = useState([])
  const [facturasLoading, setFacturasLoading] = useState(false)
  const [sinFacturar, setSinFacturar] = useState(null)
  const avisoRef = useRef(null)
  useEffect(() => {
    if (!esRemito || !form.cliente_id) { setFacturasPend([]); return }
    let vigente = true
    setFacturasLoading(true)
    RemitosAPI.facturasPendientes(+form.cliente_id, initial.id ?? null)
      .then(fs => { if (vigente) setFacturasPend(fs || []) })
      .catch(() => { if (vigente) setFacturasPend([]) })
      .finally(() => { if (vigente) setFacturasLoading(false) })
    return () => { vigente = false }
  }, [esRemito, form.cliente_id, initial.id])
  // El aviso vale para los ítems que se revisaron: si cambian, se vuelve a revisar al guardar.
  useEffect(() => { setSinFacturar(null) }, [form.items])
  useEffect(() => { if (sinFacturar) avisoRef.current?.scrollIntoView({ block: 'nearest', behavior: 'smooth' }) }, [sinFacturar])

  const onLlevaChange = (lleva) => setForm(f => ({ ...f, lleva, items: armarItems(f.items, facturasPend, lleva) }))
  const [showWarn, setShowWarn] = useState(warnVencido)
  // Para "Continuar con precios actuales" del presupuesto vencido: repite el botón que se tocó.
  const emitirPedido = useRef(false)
  // Mientras guarda o emite (3–15 s contra ARCA) no se cierra: el resultado se perdería de vista.
  const cerrar = () => { if (!loading) onClose() }

  // El 4º argumento son los campos que dependen del comprobante: en facturas multi-alícuota la
  // línea automática debe traer alicuota_iva_id como cualquier ítem de "+ Agregar ítem", si no el
  // selector de IVA de esa fila aparece vacío (el total igual sale bien: el servidor asume 21%).
  // El 5º dice si los ítems iniciales son de un comprobante guardado. Los de "→ Facturar" del
  // listado de remitos no: los armó renglonesDeRemito sin la línea de pallets, que la arma el hook.
  usePalletsVacios(
    form.items,
    (items) => setForm(f => ({ ...f, items })),
    productos,
    multiIva ? { alicuota_iva_id: alic21?.id } : null,
    !(esFacturaNueva && initial.remito_ids?.length > 0),
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

  // Auto-aplicar descuento del cliente al seleccionarlo
  const onCliChange = (cliId) => {
    const cl = clientes.find(c => c.id === +cliId)
    setForm(f => ({
      ...f,
      cliente_id: cliId,
      ...(esPresupuesto && cl ? { destinatario: cl.razon_social } : {}),
      // Los remitos marcados eran del cliente anterior: se sueltan junto con sus renglones.
      // Los ítems cargados a mano (sin _remito_id) se respetan. En el remito, "Lleva" era de las
      // facturas del cliente anterior: se vacía y se van los renglones que armó.
      remito_ids: [],
      items: esRemito ? armarItems(f.items.filter(it => !it._remito_id), [], {}) : f.items.filter(it => !it._remito_id),
      ...(esRemito && { lleva: {} }),
      descuento_general: cl?.descuento_porcentaje ?? f.descuento_general,
      // El teléfono del remito se prellena con el del cliente pero queda editable: el de la
      // obra suele ser otro (capataz/obrador) y es el que sirve si hay que llamar en la entrega.
      ...(esRemito && !f.telefono_entrega && cl?.telefono ? { telefono_entrega: cl.telefono } : {}),
    }))
    dtoClienteAplicado.current = true
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

  const itemBase = () => ({ ...ITEM_BASE, ...(multiIva && { alicuota_iva_id: alic21?.id }) })
  const addItem = () => setForm(f => ({ ...f, items: [...f.items, itemBase()] }))
  const addProductos = (sel) => setForm(f => ({ ...f, items: agregarProductos(f.items, sel, itemBase()) }))

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
  // Un número que ya usó otro remito, en cambio, sí bloquea: se avisa mientras se escribe.
  const repetido = useNumeroRepetido(RemitosAPI.buscarNumero, (form.numero || '').trim(), esRemitoNuevo)

  // La letra la decide la clase de la condición IVA del cliente en el catálogo de ARCA (A: Resp.
  // Inscripto y monotributos; B: el resto). No se elige: el servidor rechaza cualquier otra.
  const clienteSel = tipo === 'factura' ? clientes.find(c => c.id === +form.cliente_id) : null
  const letra = esFacturaNueva ? clienteSel?.clase : form.tipo_fac

  // El número de una factura lo da ARCA al emitir (último autorizado + 1 del PV del despliegue).
  // Mientras no lo tiene se muestra el que le tocaría ahora, sin reservarlo: si otro comprobante de
  // la misma letra se emite antes, éste sale con el siguiente.
  const muestraProximo = tipo === 'factura' && (esFacturaNueva || !initial.numero)
  const [proximo, setProximo] = useState(null)   // null | { cargando } | { numero } | { error }
  useEffect(() => {
    const cbte = CBTE_TIPO_FACTURA[letra]
    if (!muestraProximo || !cbte) { setProximo(null); return }
    let vigente = true
    setProximo({ cargando: true })
    ArcaAPI.ultimoAutorizado(cbte)
      .then(r => {
        if (!vigente) return
        setProximo(r.status === 200
          ? { numero: `${String(r.punto_venta).padStart(5, '0')}-${String(r.ultimo + 1).padStart(8, '0')}` }
          : { error: r.error || 'No se pudo consultar ARCA' })
      })
      .catch(() => { if (vigente) setProximo({ error: 'No se pudo consultar ARCA' }) })
    return () => { vigente = false }
  }, [muestraProximo, letra])

  // Validación previa a ARCA (§5): lo que impediría emitir se avisa acá, y sólo deja guardar el
  // borrador. La base lo vuelve a controlar al emitir.
  const bloqueosArca = tipo === 'factura' && clienteSel
    ? revisarEmision('facturas', { ...clienteSel, tipo: letra, percepciones_monto: initial.percepciones_monto || 0 }).bloqueos
    : []

  const save = async (forzar = false, emitir = emitirPedido.current) => {
    emitirPedido.current = emitir
    if (loading) return
    if (esPresupuesto ? !form.destinatario.trim() : !form.cliente_id) {
      toast.error(esPresupuesto ? 'Ingrese el nombre del destinatario' : 'Seleccione un cliente'); return
    }
    if (!form.items.length) { toast.error('Agregue al menos un ítem'); return }
    if (esRemitoNuevo && !/^\d{5}-\d{8}$/.test((form.numero || '').trim())) {
      toast.error('El número del remito debe tener el formato 00001-00012345'); return
    }
    if (repetido) { toast.error(`El remito ${repetido.numero} ya existe: revisá el número de la hoja`); return }
    // Una hoja del talonario tiene RENGLONES_TALONARIO renglones, y una hoja es un número es
    // un remito: lo que no entra no se puede continuar en otra hoja sin gastar otro número.
    if (esRemito && form.items.length > RENGLONES_TALONARIO) {
      toast.error(`No entran más de ${RENGLONES_TALONARIO} ítems en el formulario. Dividí la entrega en dos remitos.`)
      return
    }
    if (esRemito) {
      const revision = revisarRemito(form.items)
      if (revision.excedidos.length) {
        const e = revision.excedidos[0]
        toast.error(`El renglón "${e.descripcion}" lleva ${e.cantidad} pero se asignan ${e.asignado} a facturas: corregí "Lleva".`)
        return
      }
      // Sólo si el cliente tiene facturas pendientes de remitir: sin ellas, el remito queda
      // pendiente de facturar entero, como siempre. El segundo clic guarda.
      if (revision.sinFacturar.length && facturasPend.length && !sinFacturar) {
        setSinFacturar(revision.sinFacturar)
        return
      }
    }
    const payload = {
      cliente_id:        form.cliente_id ? +form.cliente_id : null,
      ...(esPresupuesto && { destinatario: form.destinatario.trim() }),
      descuento_general: +form.descuento_general || 0,
      // `_remito_id` / `_precio_auto` / `_lleva` son marcas de UI (qué renglón vino de qué remito,
      // si ya tomó el precio de lista, si lo armó "Lleva"): no van al servidor. Del remito van sus
      // asignaciones (de qué factura sale cada renglón); lo que viene de remitos_list, no.
      items:             form.items.map(({ _remito_id, _precio_auto, _lleva, asignado, sin_facturar, asignaciones, ...it }) => ({
        ...it,
        ...(esRemito && { asignaciones: (asignaciones || []).map(a => ({ factura_id: a.factura_id, cantidad: +a.cantidad })) }),
      })),
      observaciones:     form.observaciones,
      ...(esRemitoNuevo && { numero: form.numero.trim() }),
      ...(esRemito && {
        condiciones_venta: form.condiciones_venta?.trim() || null,
        domicilio_obra:    form.domicilio_obra?.trim() || null,
        telefono_entrega:  form.telefono_entrega?.trim() || null,
      }),
      ...(tipo === 'factura' && { tipo: letra, remito_ids: form.remito_ids }),
      ...(tipo === 'factura' && form.presupuesto_id && { presupuesto_id: +form.presupuesto_id }),
      ...(forzar && { forzar_vencido: true }),
    }
    setLoading(emitir ? 'emitir' : 'guardar')
    try {
      await onSave(payload, { emitir })
    } catch (err) {
      // 422 = presupuesto vencido, mostrar advertencia
      if (err.response?.status === 422) setShowWarn(true)
    } finally {
      setLoading(null)
    }
  }

  const eliminar = async () => {
    if (loading) return
    setLoading('eliminar')
    try { await onDelete() }
    finally { setLoading(null) }
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
      calendario={false}
      title={title}
      size="xl"
      onClose={cerrar}
      footer={tipo === 'factura' ? (
        <>
          {loading === 'emitir' && (
            <span className="arca-ocupado" style={{ marginRight: 'auto' }}>
              <span className="arca-spinner" aria-hidden />Emitiendo en ARCA… puede tardar hasta 15 segundos.
            </span>
          )}
          <button className="btn btn-secondary" onClick={cerrar} disabled={!!loading}>Cancelar</button>
          <button className="btn btn-secondary" onClick={() => save(false, false)} disabled={!!loading}>
            {loading === 'guardar' ? 'Guardando…' : 'Guardar borrador'}
          </button>
          <button className="btn btn-primary" onClick={() => save(false, true)} disabled={!!loading || bloqueosArca.length > 0}
            title={bloqueosArca.length ? 'Hay datos que impiden emitir: ver el aviso' : 'Guarda la factura y pide el CAE a ARCA'}>
            {loading === 'emitir' ? 'Emitiendo…' : '⚡ Guardar y emitir en ARCA'}
          </button>
        </>
      ) : (
        <>
          {esPresupuesto && onDelete && (
            <button className="btn btn-danger presupuesto-eliminar" onClick={eliminar} disabled={!!loading}>
              {loading === 'eliminar' ? 'Eliminando…' : 'Eliminar presupuesto'}
            </button>
          )}
          <button className="btn btn-secondary" onClick={cerrar} disabled={!!loading}>Cancelar</button>
          <button className="btn btn-primary" onClick={() => save(false)} disabled={!!loading || !!repetido}>
            {loading === 'guardar' ? 'Guardando…' : '✓ Guardar'}
          </button>
        </>
      )}
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

      {esPresupuesto && (
        <div className="field" style={{ marginBottom: 14 }}>
          <label className="lbl" htmlFor="presupuesto-destinatario">A nombre de *</label>
          <input id="presupuesto-destinatario" className="inp" value={form.destinatario}
            placeholder="Nombre de la persona o empresa" required
            onChange={e => setForm(f => ({ ...f, destinatario: e.target.value }))} />
          <span className="form-hint">No hace falta que esté registrado como cliente.</span>
        </div>
      )}

      <div className={esPresupuesto ? 'field' : tipo === 'factura' ? 'form-row4' : 'form-row3'} style={{ marginBottom: 14 }}>
        {/* Cliente */}
        <div className="field" style={{ gridColumn: '1 / 3' }}>
          <label className="lbl">{esPresupuesto ? 'Vincular a un cliente (opcional)' : 'Cliente *'}</label>
          <ClienteSearch clientes={clientes} value={form.cliente_id} onChange={onCliChange}
            disabled={tipo === 'factura' && !esFacturaNueva} />
        </div>

        {/* Número de la hoja del talonario preimpreso (solo remitos) */}
        {esRemito && (
          <div className="field">
            <label className="lbl">N° de remito {esRemitoNuevo && '*'}</label>
            <input
              className={`inp${repetido ? ' inp-error' : ''}`}
              value={form.numero || ''}
              readOnly={!esRemitoNuevo}
              placeholder="00001-00012345"
              onChange={e => setForm(f => ({ ...f, numero: e.target.value }))}
              style={{ fontFamily: 'monospace', ...(esRemitoNuevo ? {} : { background: 'var(--gray-50)', color: 'var(--gray-500)' }) }}
            />
            {repetido && (
              <div className="field-error">
                Ya existe el remito {repetido.numero}{repetido.razon_social ? ` de ${repetido.razon_social}` : ''} ({fFecha(repetido.fecha)}).
              </div>
            )}
          </div>
        )}

        {/* Tipo factura */}
        {tipo === 'factura' && (
          <div className="field">
            <label className="lbl">Tipo</label>
            <input
              className="inp"
              readOnly
              value={letra ? `Factura ${letra}` : '—'}
              title={clienteSel ? `Cliente ${clienteSel.condicion_iva}` : 'Depende de la condición IVA del cliente'}
              style={{ background: 'var(--gray-50)', color: 'var(--gray-500)' }}
            />
          </div>
        )}

        {/* Número que le daría ARCA si se emitiera ahora (solo facturas sin número) */}
        {muestraProximo && (
          <div className="field">
            <label className="lbl">N° a emitir</label>
            <input
              className="inp"
              readOnly
              value={proximo?.numero || (proximo?.cargando ? 'Consultando ARCA…' : '—')}
              title={proximo?.error || (letra ? undefined : 'Depende de la letra, que sale del cliente')}
              style={{ background: 'var(--gray-50)', ...(proximo?.numero ? { fontFamily: 'monospace', fontWeight: 700 } : { color: 'var(--gray-500)' }) }}
            />
            {proximo?.numero && <span className="form-hint">Lo confirma ARCA al emitir</span>}
            {proximo?.error && <span className="form-hint">No se pudo consultar ARCA: el número lo asigna al emitir</span>}
          </div>
        )}
      </div>

      {bloqueosArca.length > 0 && (
        <div className="warn-box" style={{ marginBottom: 14 }}>
          <span>⚠️</span>
          <div>
            <strong>Esta factura no se va a poder emitir en ARCA</strong> hasta resolver:
            <ul style={{ margin: '4px 0 0', paddingLeft: 18 }}>{bloqueosArca.map((b, i) => <li key={i}>{b}</li>)}</ul>
            Se puede guardar como borrador.
          </div>
        </div>
      )}

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

      {esRemito && form.cliente_id && (
        <FacturasPendientesRemitir facturas={facturasPend} lleva={form.lleva || {}}
          onChange={onLlevaChange} loading={facturasLoading} />
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
          <label className="lbl">Remitos vinculados</label>
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
      <div className={`form-row3${esPresupuesto ? ' presupuesto-leyenda' : ''}`} style={{ marginBottom: 14 }}>
        <div className="field">
          <label className="lbl">Descuento general (%)</label>
          <select className="sel" value={form.descuento_general} onChange={e => setForm(f => ({ ...f, descuento_general: +e.target.value }))}>
            <option value={0}>Sin descuento</option>
            <option value={10}>10%</option>
            <option value={15}>15%</option>
            <option value={20}>20%</option>
          </select>
        </div>
        <div className="field" style={{ gridColumn: esPresupuesto ? undefined : '2 / 4' }}>
          <label className="lbl" htmlFor="comprobante-observaciones">{esPresupuesto ? 'Leyenda / contacto' : 'Observaciones'}</label>
          <input id="comprobante-observaciones" className="inp" value={form.observaciones || ''}
            placeholder={esPresupuesto ? 'Teléfono, mail u otra aclaración' : undefined}
            onChange={e => setForm(f => ({ ...f, observaciones: e.target.value }))} />
        </div>
      </div>

      {/* Items */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
        <span style={{ fontSize: 'calc(12px * var(--font-scale))', fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px' }}>Ítems</span>
        <div style={{ display: 'flex', gap: 6 }}>
          <button className="btn btn-secondary btn-sm" onClick={addItem}>+ Agregar ítem</button>
          <ElegirProductosBtn productos={productos} onConfirm={addProductos} />
        </div>
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

      {sinFacturar && (
        <div className="warn-box" ref={avisoRef} style={{ marginTop: 14 }}>
          <span>⚠️</span>
          <div>
            Estos ítems no están en ninguna factura y van a quedar pendientes de facturar:
            <ul className="sin-facturar-lista">
              {sinFacturar.map((s, i) => <li key={i}>{s.descripcion}: {fCant(s.cantidad)}</li>)}
            </ul>
            <button className="btn btn-orange btn-sm" onClick={() => save(false)} disabled={!!loading}>Guardar igual</button>
          </div>
        </div>
      )}
    </Modal>
  )
}
