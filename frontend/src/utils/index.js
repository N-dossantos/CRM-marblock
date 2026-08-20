// src/utils/index.js

export const IVA = 0.21

// Formateo de moneda argentina
export const $ar = (n) =>
  `$ ${(+n || 0).toLocaleString('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`

// Formateo de fecha
export const fFecha = (s) => {
  if (!s) return '—'
  return new Date(s + 'T12:00:00').toLocaleDateString('es-AR')
}

// Fecha de hoy en formato YYYY-MM-DD
export const hoy = () => new Date().toISOString().split('T')[0]

// Agregar días a una fecha
export const addDias = (dateStr, n) => {
  const d = new Date(dateStr + 'T12:00:00')
  d.setDate(d.getDate() + n)
  return d.toISOString().split('T')[0]
}

// ¿Está vencido?
export const isVencido = (dateStr) =>
  dateStr ? new Date(dateStr + 'T23:59:59') < new Date() : false

// Calcular subtotal de un ítem
export const calcSubtotalItem = (cant, precio, dtoItem = 0) =>
  (parseFloat(cant) || 0) * (parseFloat(precio) || 0) * (1 - (parseFloat(dtoItem) || 0) / 100)

// Pallet de Madera Vacío y Servicio de Transporte nunca reciben el descuento general del
// cliente — son costos de paso, no productos negociables. El Dto% manual por ítem sigue
// disponible en esas filas; sólo el % automático del cliente las excluye.
const esExcluidoDeDescuentoGeneral = (it) => !!(it.es_pallet_vacio || it.es_transporte)

// Calcular totales de un comprobante
export const calcTotales = (items = [], dtoGeneral = 0) => {
  const subtotal = items.reduce((a, it) => a + calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item), 0)
  const subtotalDescontable = items.reduce((a, it) =>
    esExcluidoDeDescuentoGeneral(it) ? a : a + calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item), 0)
  const descuentoMonto = subtotalDescontable * ((parseFloat(dtoGeneral) || 0) / 100)
  const netoGravado    = subtotal - descuentoMonto
  const ivaMonto       = netoGravado * IVA
  const total          = netoGravado + ivaMonto
  return {
    subtotal:        r2(subtotal),
    descuento_monto: r2(descuentoMonto),
    neto_gravado:    r2(netoGravado),
    iva_monto:       r2(ivaMonto),
    total:           r2(total),
  }
}

const r2 = (n) => Math.round(n * 100) / 100

// Totales de un Remito X de Cuenta 2 — SIN IVA (circuito informal, precios ya netos).
// Espeja crm_calc_totales_cuenta2() del servidor, que es el cálculo autoritativo.
export const calcTotalesC2 = (items = [], dtoGeneral = 0) => {
  const subtotal = items.reduce((a, it) => a + calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item), 0)
  const subtotalDescontable = items.reduce((a, it) =>
    esExcluidoDeDescuentoGeneral(it) ? a : a + calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item), 0)
  const descuentoMonto = subtotalDescontable * ((parseFloat(dtoGeneral) || 0) / 100)
  return {
    subtotal:        r2(subtotal),
    descuento_monto: r2(descuentoMonto),
    total:           r2(subtotal - descuentoMonto),
  }
}

// Totales multi-alícuota (Compras) — preview cliente. El servidor recalcula (anti-tamper).
// `alicuotasById`: { [id]: { porcentaje } }. Ítem sin alícuota → se asume 21%.
export const calcTotalesMulti = (items = [], dtoGeneral = 0, alicuotasById = {}) => {
  const pct21 = Object.values(alicuotasById).find(a => +a.porcentaje === 21)
  const subtotal = items.reduce((a, it) => a + calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item), 0)
  const subtotalDescontable = items.reduce((a, it) =>
    esExcluidoDeDescuentoGeneral(it) ? a : a + calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item), 0)
  const descuentoMonto = subtotalDescontable * ((parseFloat(dtoGeneral) || 0) / 100)
  const factor   = 1 - (parseFloat(dtoGeneral) || 0) / 100
  const netoGravado = subtotal - descuentoMonto

  const grupos = new Map()  // alicuota_iva_id -> { porcentaje, neto }
  for (const it of items) {
    const alic = alicuotasById[it.alicuota_iva_id] || pct21
    const pct  = alic ? +alic.porcentaje : 21
    const id   = it.alicuota_iva_id ?? (pct21 ? pct21.id : null)
    const netoItem = calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item)
    const neto = esExcluidoDeDescuentoGeneral(it) ? netoItem : netoItem * factor
    const cur  = grupos.get(id) || { alicuota_iva_id: id, porcentaje: pct, neto_gravado: 0, iva_monto: 0 }
    cur.neto_gravado += neto
    grupos.set(id, cur)
  }
  let ivaMonto = 0
  const detalle = [...grupos.values()].map(g => {
    const iva = r2(g.neto_gravado * g.porcentaje / 100)
    ivaMonto += iva
    return { ...g, neto_gravado: r2(g.neto_gravado), iva_monto: iva }
  }).sort((a, b) => a.porcentaje - b.porcentaje)

  return {
    subtotal:        r2(subtotal),
    descuento_monto: r2(descuentoMonto),
    neto_gravado:    r2(netoGravado),
    iva_monto:       r2(ivaMonto),
    total:           r2(netoGravado + ivaMonto),
    detalle,
  }
}

// Nombre legible del estado
export const ESTADOS = {
  pendiente:       'Pendiente',
  cobrada:         'Cobrada',
  pagada:          'Pagada',
  parcial:         'Parcial',
  anulada:         'Anulada',
  anulado:         'Anulado',
  borrador:        'Borrador',
  enviado:         'Enviado',
  aceptado:        'Aceptado',
  vencido:         'Vencido',
  rechazado:       'Rechazado',
  convertido:      'Convertido',
  facturado:       'Facturado',
  en_cartera:      'En cartera',
  entregado:       'Entregado',
  depositado:      'Depositado',
  rechazado_banco: 'Rech. banco',
  transferido_c1:  'Transf. a Cta. 1',
  COBRO:           'Cobro',
  PAGO:            'Pago',
  AJUSTE:          'Ajuste',
}

// Badge JSX-string (para uso en tablas)
export const BADGE_COLORS = {
  pendiente:       'badge-pendiente',
  cobrada:         'badge-cobrada',
  pagada:          'badge-cobrada',
  parcial:         'badge-parcial',
  anulada:         'badge-anulada',
  anulado:         'badge-anulada',
  borrador:        'badge-borrador',
  enviado:         'badge-enviado',
  aceptado:        'badge-aceptado',
  vencido:         'badge-vencido',
  rechazado:       'badge-rechazado',
  convertido:      'badge-convertido',
  facturado:       'badge-facturado',
  en_cartera:      'badge-en_cartera',
  entregado:       'badge-entregado',
  depositado:      'badge-depositado',
  rechazado_banco: 'badge-rechazado_banco',
  transferido_c1:  'badge-transferido_c1',
  NC:              'badge-NC',
  ND:              'badge-ND',
  A:               'badge-A',
  B:               'badge-B',
}

// Fecha larga para el header
export const fechaLarga = () =>
  new Date().toLocaleDateString('es-AR', {
    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
  })
