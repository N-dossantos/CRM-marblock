// src/utils/pendientes.js
// "Facturas pendientes de remitir" en el remito (PLAN_MAESTRO §3.11): la clave de cada renglón,
// los pallets, lo que arma "Lleva" y los avisos al guardar. JS puro y sin imports, así lo cargan
// los tests con `node --test` sin pasar por Vite.

// Clave de emparejamiento entre factura y remito: igual que crm_clave_item (SQL). Sin producto,
// la descripción sin espacios en los bordes (btrim saca sólo espacios) y en minúsculas.
export const claveItem = (productoId, descripcion) => {
  if (productoId != null && productoId !== '') return `p${productoId}`
  if (descripcion == null) return null
  return `d${String(descripcion).replace(/^ +| +$/g, '').toLowerCase()}`
}

const num = (x) => +x || 0

// Pallets que ocupan `cantidad` unidades, con un decimal (para mostrar lo que falta). null si el
// producto no va en pallets.
export const palletsEquivalentes = (cantidad, unidadesPorPallet) =>
  num(unidadesPorPallet) > 1 ? Math.round((num(cantidad) / num(unidadesPorPallet)) * 10) / 10 : null

// Pallets de un renglón: redondeados para arriba, como se cargan en el camión.
export const palletsParaRenglon = (cantidad, unidadesPorPallet) =>
  num(unidadesPorPallet) > 1 ? Math.ceil(num(cantidad) / num(unidadesPorPallet)) : null

// Lo que le falta remitir a una factura, para el encabezado: pallets equivalentes de los productos
// que van en pallets (sin pallets de madera ni transporte); si no hay ninguno, unidades.
export const faltan = (factura) => {
  const items = factura?.items || []
  const enPallets = items.filter(it => num(it.unidades_por_pallet) > 1 && !it.es_pallet_vacio && !it.es_transporte)
  if (enPallets.length) {
    const total = enPallets.reduce((s, it) => s + num(it.pendiente) / num(it.unidades_por_pallet), 0)
    return { cantidad: Math.round(total * 10) / 10, unidad: 'pallets' }
  }
  return { cantidad: items.reduce((s, it) => s + num(it.pendiente), 0), unidad: 'unidades' }
}

// Los ítems del remito con lo que dice "Lleva" (`{ [facturaId]: { [clave]: cantidad } }`): un
// renglón por producto, sumando entre facturas, con `asignaciones` = lo que sale de cada factura
// (hasta su pendiente; lo de más queda sin facturar). Los renglones armados así llevan `_lleva` y
// van antes de los cargados a mano; cada llamada los vuelve a armar desde cero. Los pallets de
// madera no arman renglón: sus asignaciones van en la línea de pallets de siempre (la de
// usePalletsVacios), que se crea si no está.
export const armarItems = (items, facturas, lleva) => {
  const manuales = (items || [])
    .filter(it => !it._lleva)
    .map(it => {
      if (!it.es_pallet_vacio || !('asignaciones' in it)) return it
      const { asignaciones, ...resto } = it
      return resto
    })

  // Por clave, en el orden de las facturas y de sus renglones: el producto y lo que sale de cada factura.
  const porClave = new Map()
  for (const f of facturas || []) {
    for (const it of f.items || []) {
      const cant = num(lleva?.[f.id]?.[it.clave])
      if (cant <= 0) continue
      if (!porClave.has(it.clave)) porClave.set(it.clave, { item: it, total: 0, asignaciones: [] })
      const g = porClave.get(it.clave)
      g.total += cant
      const asignado = Math.min(cant, num(it.pendiente))
      if (asignado > 0) g.asignaciones.push({ factura_id: f.id, cantidad: asignado })
    }
  }

  const armados = []
  let conPallets = manuales
  for (const { item: it, total, asignaciones } of porClave.values()) {
    if (it.es_pallet_vacio) {
      const idx = conPallets.findIndex(m => m.es_pallet_vacio)
      if (idx !== -1) {
        conPallets = conPallets.map((m, i) => (i === idx ? { ...m, asignaciones } : m))
        continue
      }
      armados.push({
        producto_id: it.producto_id, descripcion: it.descripcion, cantidad: total, pallets: total,
        precio_unitario: 0, descuento_item: 0, unidades_por_pallet: 1,
        es_pallet_vacio: true, es_transporte: false, pallets_auto: true, _lleva: true, asignaciones,
      })
      continue
    }
    armados.push({
      producto_id: it.producto_id, descripcion: it.descripcion, cantidad: total,
      precio_unitario: 0, descuento_item: 0,
      unidades_por_pallet: it.unidades_por_pallet, pallets: palletsParaRenglon(total, it.unidades_por_pallet),
      es_pallet_vacio: false, es_transporte: !!it.es_transporte, _lleva: true, asignaciones,
    })
  }
  return [...armados, ...conPallets]
}

const asignadoDe = (it) => (it.asignaciones || []).reduce((s, a) => s + num(a.cantidad), 0)

// Lo que hay que avisar al guardar: lo que no sale de ninguna factura (queda pendiente de facturar)
// y los renglones con menos cantidad que lo asignado (no se puede guardar).
export const revisarRemito = (items) => {
  const sinFacturar = []
  const excedidos = []
  for (const it of items || []) {
    const cantidad = num(it.cantidad)
    if (cantidad <= 0) continue
    const asignado = asignadoDe(it)
    if (asignado > cantidad) excedidos.push({ descripcion: it.descripcion, asignado, cantidad })
    else if (cantidad > asignado) sinFacturar.push({ descripcion: it.descripcion, cantidad: cantidad - asignado })
  }
  return { sinFacturar, excedidos }
}

// "Lleva" a partir de las asignaciones de los ítems, para editar un remito: las suyas (origen
// 'remito', o sin origen si todavía no se guardaron); las de una factura armada desde el remito o
// de Tango no son "Lleva".
export const llevaDesdeItems = (items) => {
  const lleva = {}
  for (const it of items || []) {
    const clave = claveItem(it.producto_id, it.descripcion)
    for (const a of it.asignaciones || []) {
      if ((a.origen ?? 'remito') !== 'remito') continue
      const f = (lleva[a.factura_id] ??= {})
      f[clave] = (f[clave] || 0) + num(a.cantidad)
    }
  }
  return lleva
}
