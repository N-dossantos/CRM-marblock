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

// Fecha de calendario local: UTC adelanta el día después de las 21 h en Argentina.
export const fechaLocal = (d) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
export const hoy = () => fechaLocal(new Date())

// Documento del cliente con los códigos de ARCA (clientes.doc_tipo / doc_nro, sólo dígitos).
export const TIPOS_DOC = { 80: 'CUIT', 96: 'DNI' }

// Número tal como se lee: CUIT con guiones, DNI tal cual.
export const fDocNro = (tipo, nro) => {
  const d = String(nro ?? '')
  return +tipo === 80 && /^\d{11}$/.test(d) ? `${d.slice(0, 2)}-${d.slice(2, 10)}-${d.slice(10)}` : d
}

// Con el tipo adelante: "CUIT 30-12345678-9" / "DNI 12345678".
export const fDoc = (tipo, nro) => (nro ? `${TIPOS_DOC[tipo] || 'Doc.'} ${fDocNro(tipo, nro)}` : '—')

// Búsqueda de clientes por razón social o por los dígitos del documento (con o sin guiones).
export const clienteCoincide = (c, search) => {
  const s = String(search || '').trim()
  if (!s) return true
  const dig = s.replace(/\D/g, '')
  return (c.razon_social || '').toLowerCase().includes(s.toLowerCase())
    || (!!dig && String(c.doc_nro || '').includes(dig))
}

// Dígito verificador de CUIT (módulo 11). Mismo criterio que crm_cuit_valido en la base.
export const cuitValido = (nro) => {
  const d = String(nro ?? '')
  if (!/^\d{11}$/.test(d) || d === '00000000000') return false
  const s = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2].reduce((a, p, i) => a + p * +d[i], 0)
  const dv = 11 - (s % 11)
  return (dv === 11 ? 0 : dv) === +d[10]
}

// Teléfono argentino tal como se tipea ("011 15-2345-6789", "+54 9 11 2345 6789", "11 2345-6789 / 4698…")
// → número para wa.me (549 + área + abonado, 13 dígitos). null si no se puede armar: falta el
// código de área o no es un celular válido. Toma el primer número si hay varios separados por "/".
export const telefonoWhatsApp = (tel) => {
  let d = String(tel || '').split(/[/,;]| y /)[0].replace(/\D/g, '')
  if (d.startsWith('549') && d.length === 13) return d
  if (d.startsWith('54')) d = d.slice(2)
  if (d.startsWith('9') && d.length === 11) d = d.slice(1)
  if (d.startsWith('0')) d = d.slice(1)
  // "15" después del código de área (2 a 4 dígitos): área + 15 + abonado = 12 dígitos.
  if (d.length === 12) {
    const L = [2, 3, 4].find(l => d.slice(l, l + 2) === '15')
    if (L) d = d.slice(0, L) + d.slice(L + 2)
  }
  return d.length === 10 ? `549${d}` : null
}

// Agregar días a una fecha
export const addDias = (dateStr, n) => {
  const d = new Date(dateStr + 'T12:00:00')
  d.setDate(d.getDate() + n)
  return fechaLocal(d)
}

// Primer y último día de un mes 'AAAA-MM' (el día 0 del mes siguiente es el último de éste).
export const rangoMes = (mes) => {
  const [a, m] = mes.split('-').map(Number)
  return { desde: `${mes}-01`, hasta: `${mes}-${String(new Date(a, m, 0).getDate()).padStart(2, '0')}` }
}

// Subdiario de una cuenta sólo con el movimiento del período: el saldo corrido arranca en 0
// (no arrastra lo anterior) y los anulados se muestran pero no suman.
export const subdiarioDelPeriodo = (movimientos = []) => {
  const r2 = (n) => Math.round(n * 100) / 100
  let saldo = 0, entradas = 0, salidas = 0
  const movs = (movimientos || []).map(m => {
    if (!m.anulado) {
      const monto = +m.monto || 0
      if (+m.signo === 1) entradas = r2(entradas + monto)
      else salidas = r2(salidas + monto)
      saldo = r2(saldo + (+m.signo === 1 ? monto : -monto))
    }
    return { ...m, saldo }
  })
  return { movimientos: movs, entradas, salidas, neto: r2(entradas - salidas) }
}

// Importes y cantidades escritos a mano: el punto y la coma valen los dos como decimal (no hay
// separador de miles). Vacío es 0.
export const parseDecimal = (texto) => parseFloat(String(texto ?? '').replace(',', '.')) || 0

// Lo que queda en el campo mientras se escribe: dígitos y un solo separador decimal; null = la
// tecla no vale (un segundo separador) y no se toma. En una cantidad entera (unidades de venta) un
// punto o una coma sólo pueden ser de miles: se descartan y "1.500" queda 1500.
export const limpiarDecimal = (texto, { decimales = true } = {}) => {
  const t = String(texto ?? '').replace(decimales ? /[^\d.,]/g : /\D/g, '')
  return (t.match(/[.,]/g) || []).length > 1 ? null : t
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

// Renglones de un remito listos para sumarse a una factura: los usan el checkbox de remitos
// pendientes de ComprobanteForm y el botón "→ Factura" del listado de remitos, que tienen que dar
// lo mismo. Cada renglón queda etiquetado con `_remito_id` (destildar el remito se lleva sólo los
// suyos). La línea de pallets vacíos se descarta cuando el resto del remito trae `pallets`:
// usePalletsVacios la regenera UNA sola, consolidada sobre el total de los remitos marcados. Los
// remitos que vienen de Tango no traen `pallets` en los renglones — su línea "Pallets" es el único
// dato —, así que ahí se conserva, marcada como manual para que el hook no la borre al ver total 0.
export const renglonesDeRemito = (rem) => {
  const items = rem?.items || []
  const regenerable = items.some(it => !it.es_pallet_vacio && (parseInt(it.pallets, 10) || 0) > 0)
  return items
    .filter(it => !(it.es_pallet_vacio && regenerable))
    .map(it => ({
      ...it,
      _remito_id: rem.id,
      ...(it.es_pallet_vacio && { pallets: it.pallets ?? Math.trunc(+it.cantidad || 0), pallets_auto: false }),
    }))
}
