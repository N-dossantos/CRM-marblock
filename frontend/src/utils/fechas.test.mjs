import test from 'node:test'
import assert from 'node:assert/strict'
import { hoy, fechaLocal, addDias } from './index.js'

process.env.TZ = 'America/Argentina/Buenos_Aires'

test('hoy conserva el día argentino después de las 21 h y cambia a medianoche', () => {
  const Original = globalThis.Date
  for (const [instante, esperado] of [
    ['2026-10-21T00:30:00Z', '2026-10-20'],
    ['2026-10-21T02:59:59Z', '2026-10-20'],
    ['2026-10-21T03:00:00Z', '2026-10-21'],
    ['2027-01-01T01:00:00Z', '2026-12-31'],
  ]) {
    globalThis.Date = class extends Original {
      constructor(...args) { super(...(args.length ? args : [instante])) }
    }
    try { assert.equal(hoy(), esperado) }
    finally { globalThis.Date = Original }
  }
})

test('fechaLocal y desplazamientos respetan los límites del calendario', () => {
  assert.equal(fechaLocal(new Date('2026-10-21T01:00:00Z')), '2026-10-20')
  assert.equal(addDias('2026-12-31', 1), '2027-01-01')
  assert.equal(addDias('2028-02-28', 1), '2028-02-29')
  assert.equal(addDias('2028-03-01', -1), '2028-02-29')
  assert.equal(addDias('2026-10-20', 7), '2026-10-27')
})
