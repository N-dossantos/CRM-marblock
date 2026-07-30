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

// Calcular totales de un comprobante
export const calcTotales = (items = [], dtoGeneral = 0) => {
  const subtotal       = items.reduce((a, it) => a + calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item), 0)
  const descuentoMonto = subtotal * ((parseFloat(dtoGeneral) || 0) / 100)
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

// Nombre legible del estado
export const ESTADOS = {
  pendiente:       'Pendiente',
  cobrada:         'Cobrada',
  parcial:         'Cobro parcial',
  anulada:         'Anulada',
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
}

// Badge JSX-string (para uso en tablas)
export const BADGE_COLORS = {
  pendiente:       'badge-pendiente',
  cobrada:         'badge-cobrada',
  parcial:         'badge-parcial',
  anulada:         'badge-anulada',
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
