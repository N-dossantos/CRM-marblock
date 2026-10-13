// src/utils/excel.js
// Exportar informes a .xlsx (M12): se descargan para mandarlos por WhatsApp o pasarlos al contador.
// `write-excel-file` se importa recién al exportar, así no suma peso a la carga inicial de la app.
// Los importes van como número (con formato #,##0.00, que Excel muestra con el separador del
// sistema) y las fechas como fecha: el contador puede sumar y filtrar sin convertir nada.
import toast from 'react-hot-toast'
import { $ar, fFecha, hoy } from './index'

// Una columna: { titulo, valor: fila => …, tipo?: 'texto' | 'fecha' | 'importe' | 'numero', ancho? }
const FORMATO = { importe: '#,##0.00', numero: '#,##0' }
const ANCHO   = { texto: 18, fecha: 11, importe: 15, numero: 9 }

// 'YYYY-MM-DD' → Date a medianoche UTC: la librería pasa el Date a número de serie de Excel por
// getTime(), así que con hora local el día podría correrse.
const aFecha = (s) => (s ? new Date(String(s).slice(0, 10) + 'T00:00:00Z') : null)

function celda(col, v) {
  const tipo = col.tipo || 'texto'
  if (v === null || v === undefined || v === '') return null
  if (tipo === 'fecha') return { value: aFecha(v), type: Date, format: 'dd/mm/yyyy' }
  if (tipo === 'importe' || tipo === 'numero') return { value: Number(v) || 0, type: Number, format: FORMATO[tipo] }
  return { value: String(v), type: String }
}

// hojas: [{ nombre, columnas, filas, encabezado?: [texto, …], total?: { titulo, columnas: ['clave de valor', …] } }]
//   * encabezado: líneas sueltas arriba de la tabla (empresa / período / cuenta).
//   * total: fila final que suma las columnas de importe indicadas por su `titulo`.
export async function exportarXlsx(archivo, hojas) {
  try {
    const { default: writeXlsxFile } = await import('write-excel-file/universal')
    const sheets = hojas.map(h => {
      const data = []
      ;(h.encabezado || []).forEach((linea, i) =>
        data.push([i === 0 ? { value: linea, type: String, fontWeight: 'bold' } : { value: linea, type: String }]))
      if (h.encabezado?.length) data.push([null])
      data.push(h.columnas.map(c => ({ value: c.titulo, type: String, fontWeight: 'bold', backgroundColor: '#DBEAFE' })))
      for (const f of h.filas) data.push(h.columnas.map(c => celda(c, c.valor(f))))
      if (h.total) {
        data.push(h.columnas.map((c, i) => {
          if (i === 0) return { value: h.total.titulo || 'Totales', type: String, fontWeight: 'bold' }
          if (!h.total.columnas.includes(c.titulo)) return null
          const suma = h.filas.reduce((a, f) => a + (Number(c.valor(f)) || 0), 0)
          return { value: Math.round(suma * 100) / 100, type: Number, format: FORMATO.importe, fontWeight: 'bold' }
        }))
      }
      return {
        data,
        // Excel no acepta en el nombre de hoja \ / ? * [ ] : y lo corta en 31 caracteres.
        sheet: String(h.nombre || 'Hoja').replace(/[\\/?*[\]:]/g, '-').slice(0, 31),
        columns: h.columnas.map(c => ({ width: c.ancho || ANCHO[c.tipo || 'texto'] })),
        stickyRowsCount: (h.encabezado?.length ? h.encabezado.length + 1 : 0) + 1,
      }
    })
    const blob = await writeXlsxFile(sheets).toBlob()
    const url  = URL.createObjectURL(blob)
    const a    = document.createElement('a')
    a.href = url
    a.download = `${archivo}.xlsx`
    document.body.appendChild(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  } catch (e) {
    console.error(e)
    toast.error('No se pudo generar el Excel')
  }
}

// Nombre de archivo sin caracteres que Windows / WhatsApp no aceptan.
export const nombreArchivo = (...partes) =>
  partes.filter(Boolean).join('_').replace(/[\\/:*?"<>|]+/g, '-').replace(/\s+/g, '_')

// Cuenta corriente de un cliente o proveedor (`informe_cta_cte` / `informe_cta_cte_proveedor`):
// mismas columnas que la pantalla. `data.desde` / `data.hasta` son los de la consulta.
export function exportarCtaCte(data, entidad, rotulo) {
  const periodo = data.desde || data.hasta
    ? `Período: ${data.desde ? fFecha(data.desde) : 'inicio'} al ${data.hasta ? fFecha(data.hasta) : 'hoy'}`
    : `Al ${fFecha(hoy())}`
  return exportarXlsx(nombreArchivo('CtaCte', entidad.razon_social, data.desde, data.hasta), [{
    nombre: 'Cuenta corriente',
    encabezado: [
      `Cuenta corriente — ${entidad.razon_social}`,
      `${rotulo} · CUIT ${entidad.cuit || '—'} · ${entidad.condicion_iva || ''}`,
      periodo,
      `${data.hasta ? `Saldo al ${fFecha(data.hasta)}` : 'Saldo actual'}: ${$ar(data.saldo_total)}`,
    ],
    columnas: [
      { titulo: 'Fecha',       valor: m => m.fecha, tipo: 'fecha' },
      { titulo: 'Comprobante', valor: m => m.comprobante, ancho: 18 },
      { titulo: 'Tipo',        valor: m => m.tipo, ancho: 16 },
      { titulo: 'Debe',        valor: m => (+m.debe > 0 ? m.debe : null), tipo: 'importe' },
      { titulo: 'Haber',       valor: m => (+m.haber > 0 ? m.haber : null), tipo: 'importe' },
      { titulo: 'Saldo',       valor: m => m.saldo, tipo: 'importe' },
    ],
    filas: data.movimientos || [],
  }])
}
