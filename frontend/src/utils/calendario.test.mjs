import test from 'node:test'
import assert from 'node:assert/strict'
import { datosEvento, errorEvento } from './index.js'

test('datosEvento recorta el título y deja la descripción vacía en null', () => {
  assert.deepEqual(datosEvento({ fecha: '2026-10-21', titulo: '  Cliente Duramat ', descripcion: '   ' }),
    { fecha: '2026-10-21', titulo: 'Cliente Duramat', descripcion: null })
  assert.deepEqual(datosEvento({ fecha: '2026-10-21', titulo: 'Vence IVA' }),
    { fecha: '2026-10-21', titulo: 'Vence IVA', descripcion: null })
})

test('datosEvento conserva los saltos de línea de la descripción', () => {
  assert.equal(datosEvento({ fecha: '2026-10-21', titulo: 'Duramat', descripcion: '\n10 bloques de 20\n10 liso de 10\n' }).descripcion,
    '10 bloques de 20\n10 liso de 10')
})

test('errorEvento pide un título de 1 a 100 caracteres', () => {
  assert.equal(errorEvento({ titulo: '   ' }), 'Escribí un título de entre 1 y 100 caracteres.')
  assert.equal(errorEvento({ titulo: 'a'.repeat(101) }), 'Escribí un título de entre 1 y 100 caracteres.')
  assert.equal(errorEvento({ titulo: ' ' + 'ñ'.repeat(100) + ' ' }), '')
})

test('errorEvento acepta la descripción vacía y hasta 500 caracteres', () => {
  assert.equal(errorEvento({ titulo: 'Duramat', descripcion: '' }), '')
  assert.equal(errorEvento({ titulo: 'Duramat', descripcion: 'ñ'.repeat(500) }), '')
  assert.equal(errorEvento({ titulo: 'Duramat', descripcion: 'a'.repeat(501) }), 'La descripción puede tener hasta 500 caracteres.')
})
