import test from 'node:test'
import assert from 'node:assert/strict'
import { rangoMes, subdiarioDelPeriodo, resumenPorMedio, parseDecimal, limpiarDecimal } from './index.js'

test('rangoMes va del 1 al último día, con años bisiestos y diciembre', () => {
  assert.deepEqual(rangoMes('2026-10'), { desde: '2026-10-01', hasta: '2026-10-31' })
  assert.deepEqual(rangoMes('2026-11'), { desde: '2026-11-01', hasta: '2026-11-30' })
  assert.deepEqual(rangoMes('2028-02'), { desde: '2028-02-01', hasta: '2028-02-29' })
  assert.deepEqual(rangoMes('2026-12'), { desde: '2026-12-01', hasta: '2026-12-31' })
})

test('subdiarioDelPeriodo arranca en 0 y no cuenta los anulados', () => {
  const r = subdiarioDelPeriodo([
    { id: 1, signo: 1,  monto: '1000.10', anulado: false },
    { id: 2, signo: -1, monto: '250.05',  anulado: false },
    { id: 3, signo: 1,  monto: '999',     anulado: true },
    { id: 4, signo: -1, monto: '0.05',    anulado: false },
  ])
  assert.deepEqual(r.movimientos.map(m => m.saldo), [1000.1, 750.05, 750.05, 750])
  assert.equal(r.entradas, 1000.1)
  assert.equal(r.salidas, 250.1)
  assert.equal(r.neto, 750)
})

test('subdiarioDelPeriodo sin movimientos da todo en 0', () => {
  assert.deepEqual(subdiarioDelPeriodo(undefined), { movimientos: [], entradas: 0, salidas: 0, neto: 0 })
})

test('resumenPorMedio suma por cuenta en el orden pedido, sin anulados, con total', () => {
  const r = resumenPorMedio([
    { cuenta_bancaria_id: 3, cuenta_descripcion: 'BANCO', signo: 1,  monto: '500',   anulado: false },
    { cuenta_bancaria_id: 1, cuenta_descripcion: 'CAJA',  signo: 1,  monto: '100.5', anulado: false },
    { cuenta_bancaria_id: 1, cuenta_descripcion: 'CAJA',  signo: -1, monto: '40.25', anulado: false },
    { cuenta_bancaria_id: 3, cuenta_descripcion: 'BANCO', signo: -1, monto: '999',   anulado: true },
    { cuenta_bancaria_id: 7, cuenta_descripcion: 'RET',   signo: 1,  monto: '10',    anulado: false },
  ], [1, 3])
  assert.deepEqual(r.medios, [
    { cuenta_id: 1, medio: 'CAJA',  entradas: 100.5, salidas: 40.25, neto: 60.25 },
    { cuenta_id: 3, medio: 'BANCO', entradas: 500,   salidas: 0,     neto: 500 },
    { cuenta_id: 7, medio: 'RET',   entradas: 10,    salidas: 0,     neto: 10 },
  ])
  assert.deepEqual(r.total, { entradas: 610.5, salidas: 40.25, neto: 570.25 })
})

test('resumenPorMedio deja afuera un medio que sólo tiene anulados', () => {
  const r = resumenPorMedio([{ cuenta_bancaria_id: 3, cuenta_descripcion: 'BANCO', signo: 1, monto: '5', anulado: true }])
  assert.deepEqual(r, { medios: [], total: { entradas: 0, salidas: 0, neto: 0 } })
})

test('parseDecimal toma el punto y la coma como decimal', () => {
  assert.equal(parseDecimal('1500.50'), 1500.5)
  assert.equal(parseDecimal('1500,50'), 1500.5)
  assert.equal(parseDecimal('15.000'), 15)
  assert.equal(parseDecimal('.5'), 0.5)
  assert.equal(parseDecimal('7.'), 7)
  assert.equal(parseDecimal(''), 0)
  assert.equal(parseDecimal('.'), 0)
  assert.equal(parseDecimal(null), 0)
})

test('limpiarDecimal deja sólo dígitos y un separador', () => {
  assert.equal(limpiarDecimal('1500.5'), '1500.5')
  assert.equal(limpiarDecimal('1500,5'), '1500,5')
  assert.equal(limpiarDecimal('$ 1 500'), '1500')
  assert.equal(limpiarDecimal(''), '')
  assert.equal(limpiarDecimal('1.500,5'), null)
  assert.equal(limpiarDecimal('1..5'), null)
  assert.equal(limpiarDecimal('1.500', { decimales: false }), '1500')
  assert.equal(limpiarDecimal('15', { decimales: false }), '15')
})
