import test from 'node:test'
import assert from 'node:assert/strict'
import {
  claveItem, palletsEquivalentes, palletsParaRenglon, faltan, armarItems, revisarRemito, llevaDesdeItems,
} from './pendientes.js'
import { renglonesDeRemito } from './index.js'

// Como las devuelve facturas_pendientes_remitir, de la más vieja a la más nueva: la 2230 (bloque,
// 4830 = 46 pallets) y la 2296 (bloque 25200 = 240 pallets, y 240 pallets de madera).
const item = (producto_id, descripcion, pendiente, unidades_por_pallet, marcas = {}) => ({
  clave: `p${producto_id}`, producto_id, descripcion, facturado: pendiente, remitido: 0, acreditado: 0, pendiente,
  unidades_por_pallet, es_pallet_vacio: false, es_transporte: false, ...marcas,
})
const BLOQUE = 'Bloque Hormigón 13x19x39'
const PALLET = 'Pallet de Madera Vacío'
const F2230 = { id: 8564, numero: '00001-00002230', fecha: '2026-08-12', items: [item(8, BLOQUE, 4830, 105)] }
const F2296 = {
  id: 8699, numero: '00001-00002296', fecha: '2026-09-03',
  items: [item(8, BLOQUE, 25200, 105), item(28, PALLET, 240, 1, { es_pallet_vacio: true })],
}
const FACTURAS = [F2230, F2296]
const UN_VIAJE = { 8699: { p8: 2520, p28: 24 } }
const MANUAL = { producto_id: 5, descripcion: 'Adoquín', cantidad: 10, precio_unitario: 0, pallets: 1, unidades_por_pallet: 10 }

const lineaPallets = (items) => items.filter(it => it.es_pallet_vacio)

test('claveItem da lo mismo que crm_clave_item', () => {
  assert.equal(claveItem(8, 'x'), 'p8')
  assert.equal(claveItem(null, '  Bloque Hueco 12 '), 'dbloque hueco 12')
})

test('pallets equivalentes con un decimal; para el renglón, redondeado para arriba', () => {
  assert.equal(palletsEquivalentes(1418, 105), 13.5)
  assert.equal(palletsParaRenglon(1418, 105), 14)
  assert.equal(palletsEquivalentes(24, 1), null)
  assert.equal(palletsParaRenglon(24, 1), null)
})

test('faltan: pallets equivalentes; sin productos con pallets, unidades', () => {
  assert.deepEqual(faltan(F2230), { cantidad: 46, unidad: 'pallets' })
  assert.deepEqual(faltan(F2296), { cantidad: 240, unidad: 'pallets' })
  const soloTransporte = { id: 1, items: [item(29, 'Servicio de Transporte', 4, 1, { es_transporte: true })] }
  assert.deepEqual(faltan(soloTransporte), { cantidad: 4, unidad: 'unidades' })
})

test('armarItems_un_viaje: un renglón de bloque y la línea de pallets, con sus asignaciones', () => {
  const items = armarItems([], FACTURAS, UN_VIAJE)
  assert.equal(items.length, 2)
  const [bloque, pallets] = items
  assert.equal(bloque.producto_id, 8)
  assert.equal(bloque.descripcion, BLOQUE)
  assert.equal(bloque.cantidad, 2520)
  assert.equal(bloque.pallets, 24)
  assert.equal(bloque.unidades_por_pallet, 105)
  assert.equal(bloque.precio_unitario, 0)
  assert.equal(bloque._lleva, true)
  assert.deepEqual(bloque.asignaciones, [{ factura_id: 8699, cantidad: 2520 }])
  assert.equal(pallets.es_pallet_vacio, true)
  assert.equal(pallets.cantidad, 24)
  assert.equal(pallets.pallets, 24)
  assert.equal(pallets.pallets_auto, true)
  assert.equal(pallets._lleva, true)
  assert.deepEqual(pallets.asignaciones, [{ factura_id: 8699, cantidad: 24 }])
})

test('armarItems_dos_facturas: un solo renglón con dos asignaciones, antes de los manuales', () => {
  const items = armarItems([MANUAL], FACTURAS, { 8564: { p8: 2310 }, 8699: { p8: 210 } })
  assert.equal(items.length, 2)
  assert.equal(items[0].cantidad, 2520)
  assert.equal(items[0].pallets, 24)
  assert.deepEqual(items[0].asignaciones, [{ factura_id: 8564, cantidad: 2310 }, { factura_id: 8699, cantidad: 210 }])
  assert.deepEqual(items[1], MANUAL)
})

test('armarItems_de_mas: lo que supera lo pendiente va en el renglón, no en la asignación', () => {
  const [bloque] = armarItems([], FACTURAS, { 8564: { p8: 5000 } })
  assert.equal(bloque.cantidad, 5000)
  assert.deepEqual(bloque.asignaciones, [{ factura_id: 8564, cantidad: 4830 }])
})

test('armarItems_respeta_linea_del_hook: sigue habiendo una sola línea de pallets, con asignaciones', () => {
  const delHook = { producto_id: 28, descripcion: PALLET, cantidad: 24, pallets: 24, unidades_por_pallet: 1, es_pallet_vacio: true, pallets_auto: true }
  const items = armarItems([delHook], FACTURAS, UN_VIAJE)
  const lineas = lineaPallets(items)
  assert.equal(lineas.length, 1)
  assert.equal(lineas[0].cantidad, 24)
  assert.equal(lineas[0]._lleva, undefined)
  assert.deepEqual(lineas[0].asignaciones, [{ factura_id: 8699, cantidad: 24 }])
  // Sin "Lleva", la línea del hook queda, sin asignaciones.
  const sin = lineaPallets(armarItems(items, FACTURAS, {}))
  assert.equal(sin.length, 1)
  assert.equal(sin[0].asignaciones, undefined)
})

test('armarItems_sin_lleva_saca_los_renglones_lleva: quedan sólo los manuales', () => {
  const armados = armarItems([MANUAL], FACTURAS, UN_VIAJE)
  assert.equal(armados.length, 3)
  assert.deepEqual(armarItems(armados, FACTURAS, {}), [MANUAL])
})

test('revisar_sin_facturar: lo que se lleva de más queda sin facturar', () => {
  const r = revisarRemito(armarItems([MANUAL], FACTURAS, { 8564: { p8: 5000 } }))
  assert.deepEqual(r.sinFacturar, [{ descripcion: BLOQUE, cantidad: 170 }, { descripcion: 'Adoquín', cantidad: 10 }])
  assert.deepEqual(r.excedidos, [])
})

test('revisar_detecta_excedidos: renglón con menos de lo asignado', () => {
  const r = revisarRemito([{ descripcion: PALLET, cantidad: 20, asignaciones: [{ factura_id: 8699, cantidad: 24 }] }])
  assert.deepEqual(r.excedidos, [{ descripcion: PALLET, asignado: 24, cantidad: 20 }])
  assert.deepEqual(r.sinFacturar, [])
})

test('llevaDesdeItems: el "Lleva" con el que se armaron los ítems; ignora lo que no es del remito', () => {
  assert.deepEqual(llevaDesdeItems(armarItems([], FACTURAS, UN_VIAJE)), UN_VIAJE)
  const guardado = [
    { producto_id: 8, cantidad: 2520, asignaciones: [{ factura_id: 8699, cantidad: 2310, origen: 'remito' }, { factura_id: 8564, cantidad: 210, origen: 'remito' }] },
    { producto_id: 28, cantidad: 24, asignaciones: [{ factura_id: 8699, cantidad: 24, origen: 'tango' }] },
  ]
  assert.deepEqual(llevaDesdeItems(guardado), { 8699: { p8: 2310 }, 8564: { p8: 210 } })
})

test('renglonesDeRemito_usa_sin_facturar: entra lo que falta facturar, sin las claves de las asignaciones', () => {
  const rem = {
    id: 77,
    items: [
      { id: 1, producto_id: 8, descripcion: BLOQUE, cantidad: 2520, pallets: 24, unidades_por_pallet: 105,
        asignado: 1470, sin_facturar: 1050, asignaciones: [{ factura_id: 8699, cantidad: 1470, origen: 'remito' }] },
      { id: 2, producto_id: 29, descripcion: 'Servicio de Transporte', cantidad: 1, unidades_por_pallet: 1,
        asignado: 1, sin_facturar: 0, asignaciones: [{ factura_id: 8699, cantidad: 1, origen: 'remito' }] },
    ],
  }
  const renglones = renglonesDeRemito(rem)
  assert.equal(renglones.length, 1)
  assert.equal(renglones[0].cantidad, 1050)
  assert.equal(renglones[0].pallets, 10)
  assert.equal(renglones[0]._remito_id, 77)
  for (const k of ['asignaciones', 'asignado', 'sin_facturar']) assert.equal(k in renglones[0], false, k)
})

test('renglonesDeRemito: los pallets de madera sin facturar entran tal cual si el hook no los puede regenerar', () => {
  // 14 de los 24 pallets de bloque salieron de una factura con "Lleva"; los 24 de madera, no.
  const rem = {
    id: 78,
    items: [
      { id: 1, producto_id: 8, descripcion: BLOQUE, cantidad: 2520, pallets: 24, unidades_por_pallet: 105, sin_facturar: 1050 },
      { id: 2, producto_id: 28, descripcion: PALLET, cantidad: 24, pallets: 24, unidades_por_pallet: 1, es_pallet_vacio: true, sin_facturar: 24 },
    ],
  }
  const pallets = renglonesDeRemito(rem).filter(it => it.es_pallet_vacio)
  assert.equal(pallets.length, 1)
  assert.equal(pallets[0].cantidad, 24)
  assert.equal(pallets[0].pallets, 24)
  assert.equal(pallets[0].pallets_auto, false)
  // Si coinciden con los pallets del resto, la línea la vuelve a armar el hook (consolidada).
  rem.items[1].sin_facturar = 10
  assert.equal(renglonesDeRemito(rem).some(it => it.es_pallet_vacio), false)
})

test('renglonesDeRemito sin sin_facturar: el remito entero, como antes', () => {
  const rem = { id: 5, items: [{ id: 1, producto_id: 8, cantidad: 2520, pallets: 24, unidades_por_pallet: 105 }] }
  assert.deepEqual(renglonesDeRemito(rem), [{ id: 1, producto_id: 8, cantidad: 2520, pallets: 24, unidades_por_pallet: 105, _remito_id: 5 }])
})
