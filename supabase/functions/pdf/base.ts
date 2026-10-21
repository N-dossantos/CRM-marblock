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

// Documento del cliente con los códigos de ARCA (clientes.doc_tipo / doc_nro, sólo dígitos).
// Mismo formato que fDocNro / fDoc de frontend/src/utils.
const TIPOS_DOC: Record<number, string> = { 80: 'CUIT', 96: 'DNI' }

// Número tal como se lee: CUIT con guiones, DNI tal cual.
export const fDocNro = (tipo: any, nro: any) => {
  const d = String(nro ?? '')
  return +tipo === 80 && /^\d{11}$/.test(d) ? `${d.slice(0, 2)}-${d.slice(2, 10)}-${d.slice(10)}` : d
}

// Con el tipo adelante: "CUIT 30-12345678-9" / "DNI 12345678".
export const fDoc = (tipo: any, nro: any) =>
  nro ? `${TIPOS_DOC[+tipo] || 'Doc.'} ${fDocNro(tipo, nro)}` : '—'

// Texto blanco semitransparente sobre una franja oscura. Reemplaza a fillColor('rgba(…)'), que
// pdfkit no soporta; save/restore vuelve la opacidad a 1 para lo que sigue.
export function textoTenue(doc: any, opacidad: number, dibujar: () => void) {
  doc.save()
  doc.fillColor(COLORES.blanco, opacidad)
  dibujar()
  doc.restore()
}

// Dibuja el encabezado común de la empresa. Con `empresa` = null (Cuenta 2) la franja sale sin
// razón social, CUIT ni dirección: esos PDF no llevan los datos de la empresa.
export function dibujarHeader(doc: any, empresa: any, tipoDoc: string, numero: string, fecha: any) {
  const W = doc.page.width
  const M = 45 // margen

  // Franja superior azul oscuro
  doc.rect(0, 0, W, 80).fill(COLORES.azul_oscuro)

  if (empresa) {
    // Nombre empresa (izquierda)
    doc.fillColor(COLORES.blanco)
       .font('Helvetica-Bold')
       .fontSize(16)
       .text(empresa.razon_social || 'Mi Empresa S.A.', M, 18, { width: 300 })

    // pdfkit no entiende colores 'rgba(...)': los ignora y sigue con el color anterior (así el recuadro
    // salía blanco opaco y el tipo/número/fecha, blanco sobre blanco). La transparencia va como
    // opacidad, entre save/restore porque pdfkit la deja fija para todo lo que se dibuje después.
    textoTenue(doc, 0.6, () => doc
       .font('Helvetica')
       .fontSize(8.5)
       .text(`CUIT: ${empresa.cuit || '—'}  ·  ${empresa.condicion_iva || 'Resp. Inscripto'}`, M, 38)
       .text(empresa.direccion || '', M, 50))
  }

  // Tipo y número de comprobante (derecha)
  const tipoAncho = 160
  const tipoX = W - M - tipoAncho

  doc.save()
  doc.rect(tipoX, 8, tipoAncho, 64).fillOpacity(0.12).strokeOpacity(0.2).fillAndStroke(COLORES.blanco, COLORES.blanco)
  doc.restore()

  // El título va en una sola línea: uno largo ("COMPROBANTE TESORERÍA") se partía en dos y tapaba
  // el número. Se achica la letra hasta que entre.
  doc.font('Helvetica-Bold')
  let tamTitulo = 13
  while (tamTitulo > 8 && doc.fontSize(tamTitulo).widthOfString(tipoDoc) > tipoAncho - 12) tamTitulo -= 0.5
  doc.fillColor(COLORES.blanco)
     .fontSize(tamTitulo)
     .text(tipoDoc, tipoX, 16, { width: tipoAncho, align: 'center', lineBreak: false })

  textoTenue(doc, 0.75, () => doc
     .font('Helvetica')
     .fontSize(9)
     .text(numero, tipoX, 34, { width: tipoAncho, align: 'center' })
     .text(`Fecha: ${fFecha(fecha)}`, tipoX, 47, { width: tipoAncho, align: 'center' }))

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
  // Un presupuesto a nombre de alguien que no es cliente no tiene documento ni condición de IVA:
  // sin la línea, en vez de "—  ·  —".
  if (cliente.doc_nro || cliente.condicion_iva)
    doc.text(`${fDoc(cliente.doc_tipo, cliente.doc_nro)}  ·  ${cliente.condicion_iva || '—'}`, M + 10, y + 36)
  doc.text(cliente.direccion || '', M + 10, y + 47)

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

  doc.font('Helvetica').fontSize(8.5)
  const textos = cols.map((_: any, i: number) => values[i] !== undefined ? String(values[i]) : '')
  // La fila crece con el texto que no entra en una línea (un nombre o concepto largo se parte en
  // dos): con alto fijo de 20 la segunda línea se dibujaba encima de la fila siguiente.
  const altoTexto = Math.max(...textos.map((t: string, i: number) => doc.heightOfString(t, { width: cols[i].w - 8 })))
  const h  = Math.max(20, Math.ceil(altoTexto) + 10)

  if (sombreado) doc.rect(M, y, W - M * 2, h).fill('#f1f5f9').stroke(COLORES.gris_borde)
  else           doc.rect(M, y, W - M * 2, h).stroke(COLORES.gris_borde)

  doc.fillColor(COLORES.gris_oscuro).font('Helvetica').fontSize(8.5)

  let x = M
  for (let i = 0; i < cols.length; i++) {
    const col = cols[i]
    doc.text(textos[i], x + 4, y + 6, { width: col.w - 8, align: col.align || 'left' })
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

  // Percepciones: una línea por impuesto + jurisdicción, como las liquida AFIP/ARBA.
  // Suman al total (total = neto + IVA + percepciones), no son un descuento.
  if (Array.isArray(totales.percepciones)) {
    const NOMBRE: Record<string, string> = { iibb: 'IIBB', iva: 'IVA', ganancias: 'Ganancias' }
    for (const p of totales.percepciones) {
      const nombre = NOMBRE[p.tipo_percepcion] ?? p.tipo_percepcion
      const donde  = p.jurisdiccion ? ` ${p.jurisdiccion}` : ''
      fila(`Perc. ${nombre}${donde} ${parseFloat(p.alicuota)}%:`, $ar(p.monto))
    }
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

// Dibuja el pie de página (sin texto si `empresa` es null, como en Cuenta 2)
export function dibujarFooter(doc: any, empresa: any) {
  const W  = doc.page.width
  const H  = doc.page.height
  const M  = 45
  const yF = H - 38

  doc.moveTo(M, yF).lineTo(W - M, yF).stroke(COLORES.gris_borde)
  if (!empresa) return

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
