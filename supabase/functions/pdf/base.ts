// supabase/functions/pdf/base.ts
// Utilidades base para todos los templates de PDF (pdfkit). Puerto directo de
// backend/src/utils/pdf/base.js a Deno/TS: sólo cambian require/module.exports por import/export.
// deno-lint-ignore-file no-explicit-any

export const COLORES = {
  azul_oscuro:  '#0f2645',
  azul_medio:   '#1d4ed8',
  azul_claro:   '#dbeafe',
  gris_borde:   '#e2e8f0',
  gris_fondo:   '#f8fafc',
  gris_texto:   '#64748b',
  gris_oscuro:  '#1e293b',
  verde:        '#10b981',
  rojo:         '#ef4444',
  naranja:      '#f97316',
  violeta:      '#7c3aed',
  negro:        '#000000',
  blanco:       '#ffffff',
}

// Formatea moneda argentina
export const $ar = (n: any) => {
  const num = parseFloat(n) || 0
  const parts = num.toFixed(2).split('.')
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, '.')
  return `$ ${parts[0]},${parts[1]}`
}

// Formatea fecha dd/mm/aaaa
export const fFecha = (s: any) => {
  if (!s) return '—'
  const d = new Date(s + 'T12:00:00')
  return d.toLocaleDateString('es-AR')
}

// Dibuja el encabezado común de la empresa
export function dibujarHeader(doc: any, empresa: any, tipoDoc: string, numero: string, fecha: any) {
  const W = doc.page.width
  const M = 45 // margen

  // Franja superior azul oscuro
  doc.rect(0, 0, W, 80).fill(COLORES.azul_oscuro)

  // Nombre empresa (izquierda)
  doc.fillColor(COLORES.blanco)
     .font('Helvetica-Bold')
     .fontSize(16)
     .text(empresa.razon_social || 'Mi Empresa S.A.', M, 18, { width: 300 })

  doc.fillColor('rgba(255,255,255,0.6)')
     .font('Helvetica')
     .fontSize(8.5)
     .text(`CUIT: ${empresa.cuit || '—'}  ·  ${empresa.condicion_iva || 'Resp. Inscripto'}`, M, 38)
     .text(empresa.direccion || '', M, 50)

  // Tipo y número de comprobante (derecha)
  const tipoAncho = 160
  const tipoX = W - M - tipoAncho

  doc.rect(tipoX, 8, tipoAncho, 64).fill('rgba(255,255,255,0.12)').stroke('rgba(255,255,255,0.2)')

  doc.fillColor(COLORES.blanco)
     .font('Helvetica-Bold')
     .fontSize(13)
     .text(tipoDoc, tipoX, 16, { width: tipoAncho, align: 'center' })

  doc.fillColor('rgba(255,255,255,0.75)')
     .font('Helvetica')
     .fontSize(9)
     .text(numero, tipoX, 34, { width: tipoAncho, align: 'center' })
     .text(`Fecha: ${fFecha(fecha)}`, tipoX, 47, { width: tipoAncho, align: 'center' })

  return 88 // Y donde continúa el contenido
}

// Dibuja la sección de datos del cliente/receptor
export function dibujarCliente(doc: any, y: number, cliente: any, extra: Record<string, any> = {}) {
  const W = doc.page.width
  const M = 45
  const ancho = W - M * 2

  doc.rect(M, y, ancho, 70).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)

  doc.fillColor(COLORES.gris_texto)
     .font('Helvetica-Bold')
     .fontSize(7.5)
     .text('RECEPTOR', M + 10, y + 8)

  doc.fillColor(COLORES.gris_oscuro)
     .font('Helvetica-Bold')
     .fontSize(11)
     .text(cliente.razon_social || '—', M + 10, y + 20, { width: ancho * 0.6 })

  doc.fillColor(COLORES.gris_texto)
     .font('Helvetica')
     .fontSize(8.5)
     .text(`CUIT: ${cliente.cuit || '—'}  ·  ${cliente.condicion_iva || '—'}`, M + 10, y + 36)
     .text(cliente.direccion || '', M + 10, y + 47)

  // Columna derecha: datos extra (ej: remito vinculado, presupuesto, etc.)
  const colDer = M + ancho * 0.65
  let yExtra   = y + 20

  for (const [label, val] of Object.entries(extra)) {
    if (val) {
      doc.fillColor(COLORES.gris_texto).font('Helvetica-Bold').fontSize(7.5)
         .text(label.toUpperCase(), colDer, yExtra)
      doc.fillColor(COLORES.gris_oscuro).font('Helvetica').fontSize(9)
         .text(String(val), colDer, yExtra + 10)
      yExtra += 22
    }
  }

  return y + 78
}

// Dibuja la cabecera de la tabla de ítems
export function dibujarCabeceraTabla(doc: any, y: number, cols: any[]) {
  const W   = doc.page.width
  const M   = 45
  const h   = 22

  doc.rect(M, y, W - M * 2, h).fill(COLORES.azul_oscuro)

  doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(8)

  let x = M
  for (const col of cols) {
    doc.text(col.label.toUpperCase(), x + 4, y + 7, { width: col.w - 8, align: col.align || 'left' })
    x += col.w
  }

  return y + h
}

// Dibuja una fila de ítem
export function dibujarFilaItem(doc: any, y: number, values: any[], cols: any[], sombreado = false) {
  const W  = doc.page.width
  const M  = 45
  const h  = 20

  if (sombreado) doc.rect(M, y, W - M * 2, h).fill('#f1f5f9').stroke(COLORES.gris_borde)
  else           doc.rect(M, y, W - M * 2, h).stroke(COLORES.gris_borde)

  doc.fillColor(COLORES.gris_oscuro).font('Helvetica').fontSize(8.5)

  let x = M
  for (let i = 0; i < cols.length; i++) {
    const col = cols[i]
    const val = values[i] !== undefined ? String(values[i]) : ''
    doc.text(val, x + 4, y + 6, { width: col.w - 8, align: col.align || 'left' })
    x += col.w
  }

  return y + h
}

// Dibuja la caja de totales (alineada a la derecha)
export function dibujarTotales(doc: any, y: number, totales: any) {
  const W   = doc.page.width
  const M   = 45
  const cw  = 230
  const x   = W - M - cw
  let   cy  = y + 10

  const fila = (label: string, val: string, negrita = false, color = COLORES.gris_oscuro) => {
    doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(8.5)
       .text(label, x, cy, { width: cw * 0.55 })
    doc.fillColor(color).font(negrita ? 'Helvetica-Bold' : 'Helvetica').fontSize(negrita ? 11 : 8.5)
       .text(val, x + cw * 0.55, cy, { width: cw * 0.42, align: 'right' })
    cy += negrita ? 16 : 14
  }

  if (totales.subtotal !== undefined) fila('Subtotal s/IVA:', $ar(totales.subtotal))
  if (totales.descuento_monto > 0)    fila(`Descuento ${totales.descuento_porcentaje || ''}%:`, `— ${$ar(totales.descuento_monto)}`, false, COLORES.rojo)
  if (totales.neto_gravado !== undefined) fila('Neto gravado:', $ar(totales.neto_gravado))
  // IVA: desglose por alícuota si hay más de una; si no, la tasa real (21%, 10.5%, …).
  if (totales.detalle && totales.detalle.length > 1) {
    for (const d of totales.detalle) fila(`IVA ${d.porcentaje}%:`, $ar(d.iva_monto))
  } else if (totales.iva_monto !== undefined) {
    const pct = totales.detalle?.[0]?.porcentaje ?? totales.iva_alicuota ?? 21
    fila(`IVA ${pct}%:`, $ar(totales.iva_monto))
  }

  // Línea separadora
  doc.moveTo(x, cy).lineTo(W - M, cy).stroke(COLORES.gris_borde)
  cy += 6

  // Total
  doc.rect(x, cy, cw, 28).fill(COLORES.azul_oscuro)
  doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(9)
     .text('TOTAL', x + 8, cy + 9)
  doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(14)
     .text($ar(totales.total), x + 8, cy + 6, { width: cw - 16, align: 'right' })

  return cy + 36
}

// Dibuja el pie de página
export function dibujarFooter(doc: any, empresa: any) {
  const W  = doc.page.width
  const H  = doc.page.height
  const M  = 45
  const yF = H - 38

  doc.moveTo(M, yF).lineTo(W - M, yF).stroke(COLORES.gris_borde)

  doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(7.5)
     .text(
       `${empresa.razon_social || ''}  ·  CUIT: ${empresa.cuit || ''}  ·  ${empresa.condicion_iva || ''}  ·  Ing. Brutos: ${empresa.ingresos_brutos || ''}  ·  Inicio actividades: ${empresa.inicio_actividades || ''}`,
       M, yF + 6, { width: W - M * 2, align: 'center' }
     )
}

// Calcula totales desde items + dto general
export function calcularTotales(items: any[] = [], descuentoGeneral: any = 0) {
  const subtotal       = items.reduce((a, it) => a + (parseFloat(it.cantidad) * parseFloat(it.precio_unitario) * (1 - (parseFloat(it.descuento_item) || 0) / 100)), 0)
  const descuento_monto = subtotal * (parseFloat(descuentoGeneral) / 100)
  const neto_gravado   = subtotal - descuento_monto
  const iva_monto      = neto_gravado * 0.21
  const total          = neto_gravado + iva_monto
  return { subtotal, descuento_monto, neto_gravado, iva_monto, total, descuento_porcentaje: descuentoGeneral }
}

// Desglose de IVA por alícuota (mismo criterio que calcTotalesMulti del frontend).
// Usa it.iva_porcentaje de cada ítem (los *_list lo traen por LEFT JOIN alicuotas_iva); sin él → 21%.
export function calcularDetalleAlicuotas(items: any[] = [], descuentoGeneral: any = 0) {
  const factor = 1 - (parseFloat(descuentoGeneral) || 0) / 100
  const grupos = new Map<number, { porcentaje: number; neto_gravado: number; iva_monto: number }>()
  for (const it of items) {
    const pct  = it.iva_porcentaje != null ? parseFloat(it.iva_porcentaje) : 21
    const neto = parseFloat(it.cantidad) * parseFloat(it.precio_unitario) * (1 - (parseFloat(it.descuento_item) || 0) / 100) * factor
    const cur  = grupos.get(pct) || { porcentaje: pct, neto_gravado: 0, iva_monto: 0 }
    cur.neto_gravado += neto
    grupos.set(pct, cur)
  }
  const r2 = (n: number) => Math.round(n * 100) / 100
  return [...grupos.values()]
    .map(g => ({ porcentaje: g.porcentaje, neto_gravado: r2(g.neto_gravado), iva_monto: r2(g.neto_gravado * g.porcentaje / 100) }))
    .sort((a, b) => a.porcentaje - b.porcentaje)
}
