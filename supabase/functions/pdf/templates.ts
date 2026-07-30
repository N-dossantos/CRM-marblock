// supabase/functions/pdf/templates.ts
// Templates de PDF para cada tipo de comprobante. Puerto directo de
// backend/src/utils/pdf/templates.js — misma lógica pdfkit, sólo cambian imports/exports.
// deno-lint-ignore-file no-explicit-any
import PDFDocument from 'npm:pdfkit@0.15.0'
import { Buffer } from 'node:buffer'
import {
  COLORES, $ar, fFecha,
  dibujarHeader, dibujarCliente, dibujarCabeceraTabla,
  dibujarFilaItem, dibujarTotales, dibujarFooter,
} from './base.ts'

// ─────────────────────────────────────────────────────────────────────────────
// COLUMNAS PARA TABLA DE ÍTEMS
// ─────────────────────────────────────────────────────────────────────────────
const COLS_ITEMS = (ancho: number) => [
  { label: 'Cód.',        w: 55,   align: 'left'  },
  { label: 'Descripción', w: ancho - 55 - 50 - 90 - 65 - 80, align: 'left'  },
  { label: 'Cant.',       w: 50,   align: 'right' },
  { label: 'Precio s/IVA',w: 90,   align: 'right' },
  { label: 'Dto%',        w: 65,   align: 'right' },
  { label: 'Subtotal',    w: 80,   align: 'right' },
]

const COLS_ITEMS_REMITO = (ancho: number) => [
  { label: 'Cód.',        w: 55,   align: 'left'  },
  { label: 'Descripción', w: ancho - 55 - 60, align: 'left' },
  { label: 'Cantidad',    w: 60,   align: 'right' },
]

// ─────────────────────────────────────────────────────────────────────────────
// FACTURA
// ─────────────────────────────────────────────────────────────────────────────
export async function generarFactura(factura: any, empresa: any): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2
    const tipoLabel = `FACTURA ${factura.tipo}`

    let y = dibujarHeader(doc, empresa, tipoLabel, factura.numero, factura.fecha)

    // Datos del cliente
    y = dibujarCliente(doc, y + 6, factura, {
      'Remito vinculado': factura.remito_numero || null,
      'Presupuesto orig.': factura.presupuesto_numero || null,
    })

    // Tabla de ítems
    y += 8
    const cols = COLS_ITEMS(ancho)
    y = dibujarCabeceraTabla(doc, y, cols)

    const items = factura.items || []
    items.forEach((it: any, i: number) => {
      const sub = parseFloat(it.cantidad) * parseFloat(it.precio_unitario) * (1 - (parseFloat(it.descuento_item) || 0) / 100)
      y = dibujarFilaItem(doc, y, [
        it.codigo || '—',
        it.descripcion,
        it.cantidad,
        $ar(it.precio_unitario),
        `${it.descuento_item || 0}%`,
        $ar(sub),
      ], cols, i % 2 === 1)
    })

    // Totales
    y += 12
    const totales = {
      subtotal:         parseFloat(factura.subtotal),
      descuento_monto:  parseFloat(factura.descuento_monto),
      descuento_porcentaje: parseFloat(factura.descuento_general),
      neto_gravado:     parseFloat(factura.neto_gravado),
      iva_monto:        parseFloat(factura.iva_monto),
      total:            parseFloat(factura.total),
    }
    y = dibujarTotales(doc, y, totales)

    // Observaciones
    if (factura.observaciones) {
      y += 10
      doc.rect(M, y, ancho, 34).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)
      doc.fillColor(COLORES.gris_texto).font('Helvetica-Bold').fontSize(7.5).text('OBSERVACIONES', M + 8, y + 6)
      doc.fillColor(COLORES.gris_oscuro).font('Helvetica').fontSize(8.5).text(factura.observaciones, M + 8, y + 16, { width: ancho - 16 })
    }

    // Leyenda CAE / firma (placeholder)
    const yLey = doc.page.height - 95
    doc.rect(M, yLey, ancho, 32).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)
    doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(7.5)
       .text('Comprobante no fiscal — Pendiente de homologación AFIP/ARCA', M + 8, yLey + 12, { width: ancho - 16, align: 'center' })

    dibujarFooter(doc, empresa)
    doc.end()
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// REMITO
// ─────────────────────────────────────────────────────────────────────────────
export async function generarRemito(remito: any, empresa: any): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2

    let y = dibujarHeader(doc, empresa, 'REMITO', remito.numero, remito.fecha)

    y = dibujarCliente(doc, y + 6, remito, {
      'Factura asociada': remito.factura_numero || 'Sin facturar',
    })

    y += 8
    const cols = COLS_ITEMS_REMITO(ancho)
    y = dibujarCabeceraTabla(doc, y, cols)

    ;(remito.items || []).forEach((it: any, i: number) => {
      y = dibujarFilaItem(doc, y, [
        it.codigo || '—',
        it.descripcion,
        it.cantidad,
      ], cols, i % 2 === 1)
    })

    // Firma receptor
    const yFirma = doc.page.height - 115
    doc.rect(M, yFirma, ancho, 55).stroke(COLORES.gris_borde)
    doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(8)
       .text('Recibí conforme:', M + 12, yFirma + 8)
    doc.moveTo(M + 110, yFirma + 42).lineTo(M + 300, yFirma + 42).stroke(COLORES.gris_borde)
    doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(7.5)
       .text('Firma y aclaración', M + 155, yFirma + 44)

    // Fecha / hora recepción
    doc.moveTo(W - M - 150, yFirma + 42).lineTo(W - M - 10, yFirma + 42).stroke(COLORES.gris_borde)
    doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(7.5)
       .text('Fecha y hora', W - M - 100, yFirma + 44)

    if (remito.observaciones) {
      y += 10
      doc.rect(M, y, ancho, 30).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)
      doc.fillColor(COLORES.gris_texto).font('Helvetica-Bold').fontSize(7.5).text('OBSERVACIONES', M + 8, y + 6)
      doc.fillColor(COLORES.gris_oscuro).font('Helvetica').fontSize(8.5).text(remito.observaciones, M + 8, y + 16, { width: ancho - 16 })
    }

    dibujarFooter(doc, empresa)
    doc.end()
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// PRESUPUESTO
// ─────────────────────────────────────────────────────────────────────────────
export async function generarPresupuesto(presupuesto: any, empresa: any): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2

    let y = dibujarHeader(doc, empresa, 'PRESUPUESTO', presupuesto.numero, presupuesto.fecha)

    // Franja de validez (alerta si está vencido)
    const vencido = new Date(presupuesto.fecha_vcto + 'T23:59:59') < new Date()
    doc.rect(M, y + 6, ancho, 22)
       .fill(vencido ? '#fef3c7' : COLORES.azul_claro)
       .stroke(vencido ? '#f59e0b' : '#93c5fd')
    doc.fillColor(vencido ? '#92400e' : COLORES.azul_medio)
       .font('Helvetica-Bold').fontSize(8.5)
       .text(
         `${vencido ? '⚠ PRESUPUESTO VENCIDO — ' : ''}Válido hasta: ${fFecha(presupuesto.fecha_vcto)}`,
         M + 8, y + 13, { width: ancho - 16, align: 'center' }
       )

    y = dibujarCliente(doc, y + 34, presupuesto, {})

    y += 8
    const cols = COLS_ITEMS(ancho)
    y = dibujarCabeceraTabla(doc, y, cols)

    ;(presupuesto.items || []).forEach((it: any, i: number) => {
      const sub = parseFloat(it.cantidad) * parseFloat(it.precio_unitario) * (1 - (parseFloat(it.descuento_item) || 0) / 100)
      y = dibujarFilaItem(doc, y, [
        it.codigo || '—',
        it.descripcion,
        it.cantidad,
        $ar(it.precio_unitario),
        `${it.descuento_item || 0}%`,
        $ar(sub),
      ], cols, i % 2 === 1)
    })

    y += 12
    const totales = {
      subtotal:             parseFloat(presupuesto.subtotal),
      descuento_monto:      parseFloat(presupuesto.descuento_monto),
      descuento_porcentaje: parseFloat(presupuesto.descuento_general),
      neto_gravado:         parseFloat(presupuesto.neto_gravado),
      iva_monto:            parseFloat(presupuesto.iva_monto),
      total:                parseFloat(presupuesto.total),
    }
    y = dibujarTotales(doc, y, totales)

    if (presupuesto.observaciones) {
      y += 10
      doc.rect(M, y, ancho, 34).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)
      doc.fillColor(COLORES.gris_texto).font('Helvetica-Bold').fontSize(7.5).text('OBSERVACIONES', M + 8, y + 6)
      doc.fillColor(COLORES.gris_oscuro).font('Helvetica').fontSize(8.5).text(presupuesto.observaciones, M + 8, y + 16, { width: ancho - 16 })
    }

    // Leyenda condiciones
    const yLey = doc.page.height - 95
    doc.rect(M, yLey, ancho, 32).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)
    doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(7.5)
       .text('Los precios indicados son en pesos argentinos e incluyen IVA 21%. Este presupuesto no constituye comprobante fiscal.', M + 8, yLey + 12, { width: ancho - 16, align: 'center' })

    dibujarFooter(doc, empresa)
    doc.end()
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// NOTA DE CRÉDITO / DÉBITO
// ─────────────────────────────────────────────────────────────────────────────
export async function generarNota(nota: any, empresa: any): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2
    const tipoLabel = nota.tipo === 'NC'
      ? `NOTA DE CRÉDITO ${nota.tipo_letra || 'A'}`
      : `NOTA DE DÉBITO ${nota.tipo_letra || 'A'}`

    let y = dibujarHeader(doc, empresa, tipoLabel, nota.numero, nota.fecha)

    y = dibujarCliente(doc, y + 6, nota, {
      'Factura de referencia': nota.factura_numero,
    })

    // Motivo
    if (nota.motivo) {
      y += 6
      doc.rect(M, y, ancho, 26).fill('#fef3c7').stroke('#f59e0b')
      doc.fillColor('#92400e').font('Helvetica-Bold').fontSize(7.5).text('MOTIVO:', M + 8, y + 7)
      doc.fillColor('#78350f').font('Helvetica').fontSize(9).text(nota.motivo, M + 60, y + 7, { width: ancho - 70 })
      y += 32
    }

    y += 4
    const cols = COLS_ITEMS(ancho)
    y = dibujarCabeceraTabla(doc, y, cols)

    ;(nota.items || []).forEach((it: any, i: number) => {
      const sub = parseFloat(it.cantidad) * parseFloat(it.precio_unitario) * (1 - (parseFloat(it.descuento_item) || 0) / 100)
      y = dibujarFilaItem(doc, y, [
        it.codigo || '—',
        it.descripcion,
        it.cantidad,
        $ar(it.precio_unitario),
        `${it.descuento_item || 0}%`,
        $ar(sub),
      ], cols, i % 2 === 1)
    })

    y += 12
    const totales = {
      subtotal:     parseFloat(nota.subtotal),
      neto_gravado: parseFloat(nota.neto_gravado),
      iva_monto:    parseFloat(nota.iva_monto),
      total:        parseFloat(nota.total),
    }
    y = dibujarTotales(doc, y, totales)

    dibujarFooter(doc, empresa)
    doc.end()
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// RECIBO DE COBRO
// ─────────────────────────────────────────────────────────────────────────────
export async function generarRecibo(recibo: any, empresa: any): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2

    let y = dibujarHeader(doc, empresa, 'RECIBO DE COBRO', recibo.numero, recibo.fecha)

    y = dibujarCliente(doc, y + 6, recibo, {})

    // Facturas imputadas
    y += 10
    const facsList = (recibo.facturas || [])
    if (facsList.length > 0) {
      doc.rect(M, y, ancho, 22).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)
      doc.fillColor(COLORES.gris_texto).font('Helvetica-Bold').fontSize(7.5).text('COMPROBANTES CANCELADOS', M + 8, y + 8)
      y += 22
      const cols = [
        { label: 'N° Factura', w: ancho * 0.4, align: 'left' },
      ]
      facsList.forEach((f: any, i: number) => {
        y = dibujarFilaItem(doc, y, [f.numero || `Factura ${f.factura_id}`], cols, i % 2 === 1)
      })
    } else {
      doc.rect(M, y, ancho, 22).fill('#fffbeb').stroke('#f59e0b')
      doc.fillColor('#92400e').font('Helvetica').fontSize(8.5)
         .text('Pago a cuenta — sin factura imputada', M + 8, y + 7, { width: ancho - 16, align: 'center' })
      y += 22
    }

    // Medios de pago
    y += 10
    doc.rect(M, y, ancho, 22).fill(COLORES.azul_oscuro)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(8)
       .text('FORMA DE PAGO', M + 8, y + 7)
    y += 22

    const TIPO_LABELS: Record<string, string> = { efectivo: 'Efectivo (Caja)', transferencia: 'Transferencia bancaria', cheque: 'Cheque físico', echeq: 'E-Cheq' }
    ;(recibo.medios || []).forEach((m: any, i: number) => {
      const h = (m.tipo === 'cheque' || m.tipo === 'echeq') ? 38 : 22
      doc.rect(M, y, ancho, h).fill(i % 2 === 1 ? COLORES.gris_fondo : COLORES.blanco).stroke(COLORES.gris_borde)

      doc.fillColor(COLORES.gris_oscuro).font('Helvetica-Bold').fontSize(9)
         .text(TIPO_LABELS[m.tipo] || m.tipo, M + 10, y + 7)
      doc.fillColor(COLORES.azul_medio).font('Helvetica-Bold').fontSize(11)
         .text($ar(m.monto), M + 10, y + 6, { width: ancho - 20, align: 'right' })

      if (m.tipo === 'transferencia' && m.detalle) {
        doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(8)
           .text(m.detalle, M + 10, y + 20)
      }
      if ((m.tipo === 'cheque' || m.tipo === 'echeq') && m.banco) {
        doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(8)
           .text(`Banco: ${m.banco}  ·  Nro: ${m.numero_cheque || '—'}  ·  Vence: ${fFecha(m.fecha_vcto)}${m.titular ? `  ·  Titular: ${m.titular}` : ''}`, M + 10, y + 20)
      }
      y += h
    })

    // Total recibido
    y += 10
    doc.rect(M, y, ancho, 36).fill(COLORES.azul_oscuro)
    doc.fillColor(COLORES.blanco).font('Helvetica').fontSize(9)
       .text('TOTAL RECIBIDO:', M + 12, y + 12)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(16)
       .text($ar(recibo.total), M + 12, y + 9, { width: ancho - 24, align: 'right' })
    y += 42

    // Observaciones
    if (recibo.observaciones) {
      y += 6
      doc.rect(M, y, ancho, 30).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)
      doc.fillColor(COLORES.gris_texto).font('Helvetica-Bold').fontSize(7.5).text('OBSERVACIONES', M + 8, y + 6)
      doc.fillColor(COLORES.gris_oscuro).font('Helvetica').fontSize(8.5).text(recibo.observaciones, M + 8, y + 16, { width: ancho - 16 })
      y += 36
    }

    // Firmas
    const yFirma = Math.max(y + 20, doc.page.height - 130)
    doc.moveTo(M + 20,  yFirma + 40).lineTo(M + 200, yFirma + 40).stroke(COLORES.gris_borde)
    doc.moveTo(W - M - 200, yFirma + 40).lineTo(W - M - 20, yFirma + 40).stroke(COLORES.gris_borde)
    doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(7.5)
       .text('Firma del emisor', M + 65, yFirma + 43)
       .text('Firma del receptor', W - M - 155, yFirma + 43)

    dibujarFooter(doc, empresa)
    doc.end()
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// CUENTA CORRIENTE
// ─────────────────────────────────────────────────────────────────────────────
export async function generarCtaCte(data: any, empresa: any, filtros: any = {}): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2
    const { cliente, movimientos = [], saldo_total } = data

    // Header
    let y = dibujarHeader(doc, empresa, 'CUENTA CORRIENTE', '', new Date().toISOString().split('T')[0])

    // Info cliente
    doc.rect(M, y + 6, ancho, 52).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)
    doc.fillColor(COLORES.gris_texto).font('Helvetica-Bold').fontSize(7.5).text('CLIENTE', M + 10, y + 14)
    doc.fillColor(COLORES.gris_oscuro).font('Helvetica-Bold').fontSize(12).text(cliente.razon_social, M + 10, y + 24, { width: ancho * 0.6 })
    doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(8.5)
       .text(`CUIT: ${cliente.cuit}  ·  ${cliente.condicion_iva}`, M + 10, y + 40)

    // Saldo (derecha)
    const saldoColor = saldo_total > 0 ? COLORES.rojo : saldo_total < 0 ? COLORES.verde : COLORES.gris_texto
    doc.fillColor(COLORES.gris_texto).font('Helvetica-Bold').fontSize(7.5)
       .text('SALDO ACTUAL', W - M - 170, y + 14)
    doc.fillColor(saldoColor).font('Helvetica-Bold').fontSize(16)
       .text($ar(saldo_total), W - M - 170, y + 25, { width: 160, align: 'right' })
    doc.fillColor(saldoColor).font('Helvetica').fontSize(8)
       .text(saldo_total > 0 ? 'Saldo deudor' : saldo_total < 0 ? 'Saldo a favor' : 'Cuenta balanceada', W - M - 170, y + 44, { width: 160, align: 'right' })

    y += 64

    // Filtro de fechas
    if (filtros.desde || filtros.hasta) {
      doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(8)
         .text(`Período: ${filtros.desde ? fFecha(filtros.desde) : 'inicio'} al ${filtros.hasta ? fFecha(filtros.hasta) : 'hoy'}`, M, y + 6)
      y += 20
    }

    // Cabecera tabla
    y += 4
    const cols = [
      { label: 'Fecha',       w: 70,  align: 'left'  },
      { label: 'Comprobante', w: 100, align: 'left'  },
      { label: 'Tipo',        w: 80,  align: 'left'  },
      { label: 'Debe',        w: (ancho - 250 - 90) / 2, align: 'right' },
      { label: 'Haber',       w: (ancho - 250 - 90) / 2, align: 'right' },
      { label: 'Saldo',       w: 90,  align: 'right' },
    ]
    y = dibujarCabeceraTabla(doc, y, cols)

    const TIPO_LABELS_CTA: Record<string, string> = {
      FACTURA: 'Factura', RECIBO: 'Recibo',
      'NOTA CRED.': 'N. Crédito', 'NOTA DEB.': 'N. Débito',
    }

    let saldoAcum = 0
    movimientos.forEach((m: any, i: number) => {
      saldoAcum = parseFloat(m.saldo)
      const saldoStr = $ar(Math.abs(saldoAcum))
      const saldoFmt = saldoAcum > 0 ? saldoStr : saldoAcum < 0 ? `(${saldoStr})` : '$0,00'

      y = dibujarFilaItem(doc, y, [
        fFecha(m.fecha),
        m.comprobante,
        TIPO_LABELS_CTA[m.tipo] || m.tipo,
        parseFloat(m.debe) > 0 ? $ar(m.debe) : '—',
        parseFloat(m.haber) > 0 ? $ar(m.haber) : '—',
        saldoFmt,
      ], cols, i % 2 === 1)

      // Nueva página si se llena
      if (y > doc.page.height - 120) {
        doc.addPage()
        y = 50
        y = dibujarCabeceraTabla(doc, y, cols)
      }
    })

    // Fila total final
    y += 4
    doc.rect(M, y, ancho, 26).fill(COLORES.azul_oscuro)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(9)
       .text('SALDO FINAL:', M + 8, y + 9)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(12)
       .text($ar(Math.abs(saldo_total)), M + 8, y + 7, { width: ancho - 16, align: 'right' })

    dibujarFooter(doc, empresa)
    doc.end()
  })
}
