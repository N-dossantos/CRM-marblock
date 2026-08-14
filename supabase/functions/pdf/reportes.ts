// supabase/functions/pdf/reportes.ts
// Templates PDF para los informes (ranking deudores, resumen ventas). Puerto directo de
// backend/src/utils/pdf/reportes.js.
// deno-lint-ignore-file no-explicit-any
import PDFDocument from 'npm:pdfkit@0.15.0'
import { Buffer } from 'node:buffer'
import {
  COLORES, $ar, fFecha,
  dibujarHeader, dibujarCabeceraTabla, dibujarFilaItem, dibujarFooter,
} from './base.ts'

// ─────────────────────────────────────────────────────────────────────────────
// RANKING DE DEUDORES
// ─────────────────────────────────────────────────────────────────────────────
export async function generarRankingDeudores(deudores: any[], empresa: any): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2
    const fecha = new Date().toISOString().split('T')[0]

    let y = dibujarHeader(doc, empresa, 'RANKING DE DEUDORES', '', fecha)

    // Total adeudado
    const totalAdeudado = deudores.reduce((a, d) => a + parseFloat(d.total_pendiente || 0), 0)
    doc.rect(M, y + 6, ancho, 36).fill(COLORES.azul_oscuro)
    doc.fillColor(COLORES.blanco).font('Helvetica').fontSize(9)
       .text(`${deudores.length} cliente(s) con saldo pendiente`, M + 12, y + 14)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(16)
       .text($ar(totalAdeudado), M + 12, y + 11, { width: ancho - 24, align: 'right' })
    doc.fillColor('rgba(255,255,255,0.55)').font('Helvetica').fontSize(8)
       .text('TOTAL ADEUDADO', M + 12, y + 28, { width: ancho - 24, align: 'right' })
    y += 50

    const cols = [
      { label: '#',             w: 28,  align: 'center' },
      { label: 'Cliente',       w: 200, align: 'left'   },
      { label: 'CUIT',          w: 95,  align: 'left'   },
      { label: 'Teléfono',      w: 85,  align: 'left'   },
      { label: 'Fact. pend.',   w: 65,  align: 'center' },
      { label: 'Total adeudado',w: 95,  align: 'right'  },
      { label: 'Días deuda',    w: ancho - 28 - 200 - 95 - 85 - 65 - 95, align: 'right' },
    ]

    y = dibujarCabeceraTabla(doc, y, cols)

    deudores.forEach((d, i) => {
      const dias = parseInt(d.dias_deuda) || 0
      y = dibujarFilaItem(doc, y, [
        i + 1,
        d.razon_social.length > 32 ? d.razon_social.slice(0, 32) + '…' : d.razon_social,
        d.cuit,
        d.telefono || '—',
        d.facturas_pendientes,
        $ar(d.total_pendiente),
        `${dias} días`,
      ], cols, i % 2 === 1)

      // Color en celda días (requiere dibujar sobre la fila)
      const colOffset = 28 + 200 + 95 + 85 + 65 + 95
      const color = dias > 60 ? '#fee2e2' : dias > 30 ? '#fef3c7' : '#d1fae5'
      const textColor = dias > 60 ? '#991b1b' : dias > 30 ? '#92400e' : '#065f46'
      const lastColW = cols[cols.length - 1].w
      doc.rect(M + colOffset + 2, y - 20 + 2, lastColW - 4, 16).fill(color)
      doc.fillColor(textColor).font('Helvetica-Bold').fontSize(8)
         .text(`${dias} días`, M + colOffset + 4, y - 20 + 6, { width: lastColW - 8, align: 'right' })

      if (y > doc.page.height - 100) {
        doc.addPage()
        y = 50
        y = dibujarCabeceraTabla(doc, y, cols)
      }
    })

    dibujarFooter(doc, empresa)
    doc.end()
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// RESUMEN DE VENTAS POR PERÍODO
// ─────────────────────────────────────────────────────────────────────────────
export async function generarResumenVentas(data: any, empresa: any, desde: any, hasta: any): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2
    const { totales, por_cliente, por_producto } = data

    let y = dibujarHeader(doc, empresa, 'RESUMEN DE VENTAS', '', new Date().toISOString().split('T')[0])

    // Período
    doc.rect(M, y + 6, ancho, 22).fill(COLORES.azul_claro).stroke('#93c5fd')
    doc.fillColor(COLORES.azul_medio).font('Helvetica-Bold').fontSize(9)
       .text(
         `Período: ${fFecha(desde)} al ${fFecha(hasta)}`,
         M + 8, y + 13, { width: ancho - 16, align: 'center' }
       )
    y += 34

    // KPIs en cajas 2x2
    const kw = (ancho - 10) / 2
    const kpis = [
      { label: 'Facturas emitidas',  val: totales.cantidad_facturas, color: COLORES.azul_medio },
      { label: 'Total facturado',    val: $ar(totales.total_facturado),  color: '#10b981' },
      { label: 'Total cobrado',      val: $ar(totales.total_cobrado),    color: '#059669' },
      { label: 'Total pendiente',    val: $ar(totales.total_pendiente),  color: COLORES.rojo  },
    ]
    kpis.forEach((k, i) => {
      const kx = M + (i % 2) * (kw + 10)
      const ky = y + Math.floor(i / 2) * 48
      doc.rect(kx, ky, kw, 42).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)
      doc.moveTo(kx, ky).lineTo(kx, ky + 42).stroke(k.color)
      doc.rect(kx, ky, 3, 42).fill(k.color)
      doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(8).text(k.label, kx + 10, ky + 8)
      doc.fillColor(k.color).font('Helvetica-Bold').fontSize(16).text(String(k.val), kx + 10, ky + 18)
    })
    y += 106

    // IVA y descuentos
    doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(8.5)
       .text(`Neto gravado: ${$ar(totales.neto_gravado)}   ·   IVA 21%: ${$ar(totales.iva_total)}   ·   Descuentos otorgados: ${$ar(totales.descuento_total)}`, M, y, { width: ancho, align: 'center' })
    y += 20

    // Tabla ventas por cliente
    doc.fillColor(COLORES.gris_oscuro).font('Helvetica-Bold').fontSize(10).text('Ventas por cliente', M, y)
    y += 14

    const colsCli = [
      { label: 'Cliente',       w: 220, align: 'left'   },
      { label: 'CUIT',          w: 95,  align: 'left'   },
      { label: 'Facturas',      w: 60,  align: 'center' },
      { label: 'Total',         w: 100, align: 'right'  },
      { label: 'Pendiente',     w: ancho - 220 - 95 - 60 - 100, align: 'right' },
    ]
    y = dibujarCabeceraTabla(doc, y, colsCli)
    por_cliente.forEach((c: any, i: number) => {
      y = dibujarFilaItem(doc, y, [
        c.razon_social.length > 34 ? c.razon_social.slice(0, 34) + '…' : c.razon_social,
        c.cuit,
        c.cantidad_facturas,
        $ar(c.total_facturado),
        parseFloat(c.pendiente) > 0 ? $ar(c.pendiente) : '✓ Cobrada',
      ], colsCli, i % 2 === 1)

      if (y > doc.page.height - 120) {
        doc.addPage(); y = 50
        y = dibujarCabeceraTabla(doc, y, colsCli)
      }
    })

    // Tabla top productos (si caben en la misma página)
    if (por_producto && por_producto.length > 0) {
      if (y > doc.page.height - 200) { doc.addPage(); y = 50 }
      y += 16
      doc.fillColor(COLORES.gris_oscuro).font('Helvetica-Bold').fontSize(10).text('Top productos', M, y)
      y += 14
      const colsProd = [
        { label: '#',          w: 28,  align: 'center' },
        { label: 'Código',     w: 60,  align: 'left'   },
        { label: 'Descripción',w: 260, align: 'left'   },
        { label: 'Cant. total',w: 80,  align: 'right'  },
        { label: 'Neto total', w: ancho - 28 - 60 - 260 - 80, align: 'right' },
      ]
      y = dibujarCabeceraTabla(doc, y, colsProd)
      por_producto.slice(0, 15).forEach((p: any, i: number) => {
        y = dibujarFilaItem(doc, y, [
          i + 1,
          p.codigo || '—',
          p.descripcion ? (p.descripcion.length > 42 ? p.descripcion.slice(0, 42) + '…' : p.descripcion) : '—',
          p.total_cantidad,
          $ar(p.total_neto),
        ], colsProd, i % 2 === 1)
      })
    }

    dibujarFooter(doc, empresa)
    doc.end()
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// SUBDIARIO DE CUENTA (saldo corrido)  — Tesorería, Fase D
// ─────────────────────────────────────────────────────────────────────────────
export async function generarSubdiario(data: any, empresa: any, filtros: any = {}): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2
    const { cuenta = {}, saldo_inicial = 0, movimientos = [], saldo_final = 0 } = data

    let y = dibujarHeader(doc, empresa, 'SUBDIARIO', '', new Date().toISOString().split('T')[0])

    // Info cuenta + saldos
    doc.rect(M, y + 6, ancho, 52).fill(COLORES.gris_fondo).stroke(COLORES.gris_borde)
    doc.fillColor(COLORES.gris_texto).font('Helvetica-Bold').fontSize(7.5).text('CUENTA', M + 10, y + 14)
    doc.fillColor(COLORES.gris_oscuro).font('Helvetica-Bold').fontSize(12).text(cuenta.descripcion || '—', M + 10, y + 24, { width: ancho * 0.6 })
    doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(8.5)
       .text(`${cuenta.banco ? cuenta.banco + '  ·  ' : ''}Saldo inicial período: ${$ar(saldo_inicial)}`, M + 10, y + 40)

    const saldoColor = saldo_final < 0 ? COLORES.rojo : COLORES.verde
    doc.fillColor(COLORES.gris_texto).font('Helvetica-Bold').fontSize(7.5).text('SALDO FINAL', W - M - 170, y + 14)
    doc.fillColor(saldoColor).font('Helvetica-Bold').fontSize(16).text($ar(saldo_final), W - M - 170, y + 25, { width: 160, align: 'right' })
    y += 64

    if (filtros.desde || filtros.hasta) {
      doc.fillColor(COLORES.gris_texto).font('Helvetica').fontSize(8)
         .text(`Período: ${filtros.desde ? fFecha(filtros.desde) : 'inicio'} al ${filtros.hasta ? fFecha(filtros.hasta) : 'hoy'}`, M, y + 6)
      y += 20
    }

    y += 4
    const cols = [
      { label: 'Fecha',       w: 62,  align: 'left'  },
      { label: 'Comprob.',    w: 80,  align: 'left'  },
      { label: 'Tipo',        w: 80,  align: 'left'  },
      { label: 'Concepto',    w: ancho - 62 - 80 - 80 - 75 - 75 - 85, align: 'left' },
      { label: 'Entrada',     w: 75,  align: 'right' },
      { label: 'Salida',      w: 75,  align: 'right' },
      { label: 'Saldo',       w: 85,  align: 'right' },
    ]
    y = dibujarCabeceraTabla(doc, y, cols)

    movimientos.forEach((m: any, i: number) => {
      const entrada = Number(m.signo) === 1 ? $ar(m.monto) : '—'
      const salida  = Number(m.signo) === -1 ? $ar(m.monto) : '—'
      y = dibujarFilaItem(doc, y, [
        fFecha(m.fecha),
        m.numero || `#${m.id}`,
        m.tipo_descripcion || m.tipo_codigo || '—',
        m.concepto || '—',
        entrada,
        salida,
        $ar(m.saldo_corrido),
      ], cols, i % 2 === 1)

      if (y > doc.page.height - 120) {
        doc.addPage(); y = 50
        y = dibujarCabeceraTabla(doc, y, cols)
      }
    })

    y += 4
    doc.rect(M, y, ancho, 26).fill(COLORES.azul_oscuro)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(9).text('SALDO FINAL:', M + 8, y + 9)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(12).text($ar(saldo_final), M + 8, y + 7, { width: ancho - 16, align: 'right' })

    dibujarFooter(doc, empresa)
    doc.end()
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// SALDOS DE TESORERÍA (por cuenta, agrupado)  — Fase D
// ─────────────────────────────────────────────────────────────────────────────
export async function generarSaldos(data: any, empresa: any): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2
    const { agrupaciones = [], total_general = 0 } = data

    let y = dibujarHeader(doc, empresa, 'SALDOS TESORERÍA', '', new Date().toISOString().split('T')[0])

    // Total general destacado
    doc.rect(M, y + 6, ancho, 36).fill(COLORES.azul_oscuro)
    doc.fillColor(COLORES.blanco).font('Helvetica').fontSize(9).text('Saldo total disponible', M + 12, y + 14)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(16).text($ar(total_general), M + 12, y + 11, { width: ancho - 24, align: 'right' })
    y += 52

    const cols = [
      { label: 'Cuenta',       w: ancho - 90 - 95 - 95 - 100, align: 'left'  },
      { label: 'Clase',        w: 90,  align: 'left'  },
      { label: 'Entradas',     w: 95,  align: 'right' },
      { label: 'Salidas',      w: 95,  align: 'right' },
      { label: 'Saldo actual', w: 100, align: 'right' },
    ]

    agrupaciones.forEach((g: any) => {
      // Sub-cabecera de agrupación
      doc.rect(M, y, ancho, 20).fill('#eef2ff')
      doc.fillColor('#3730a3').font('Helvetica-Bold').fontSize(9).text(g.descripcion || 'Sin agrupación', M + 8, y + 6)
      doc.fillColor('#3730a3').font('Helvetica-Bold').fontSize(9).text($ar(g.subtotal), M + 8, y + 6, { width: ancho - 16, align: 'right' })
      y += 20

      y = dibujarCabeceraTabla(doc, y, cols)
      ;(g.cuentas || []).forEach((c: any, i: number) => {
        y = dibujarFilaItem(doc, y, [
          c.descripcion || '—',
          c.clase || '—',
          $ar(c.entradas),
          $ar(c.salidas),
          $ar(c.saldo_actual),
        ], cols, i % 2 === 1)
        if (y > doc.page.height - 120) { doc.addPage(); y = 50 }
      })
      y += 10
      if (y > doc.page.height - 140) { doc.addPage(); y = 50 }
    })

    y += 2
    doc.rect(M, y, ancho, 26).fill(COLORES.azul_oscuro)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(9).text('TOTAL GENERAL:', M + 8, y + 9)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(12).text($ar(total_general), M + 8, y + 7, { width: ancho - 16, align: 'right' })

    dibujarFooter(doc, empresa)
    doc.end()
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// MAYOR DE TESORERÍA (por cuenta)  — Fase D
// ─────────────────────────────────────────────────────────────────────────────
export async function generarMayorTesoreria(data: any, empresa: any, filtros: any = {}): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const M = 45
    const ancho = W - M * 2
    const { cuentas = [], totales = {} } = data

    let y = dibujarHeader(doc, empresa, 'MAYOR TESORERÍA', '', new Date().toISOString().split('T')[0])

    if (filtros.desde || filtros.hasta) {
      doc.rect(M, y + 6, ancho, 22).fill(COLORES.azul_claro).stroke('#93c5fd')
      doc.fillColor(COLORES.azul_medio).font('Helvetica-Bold').fontSize(9)
         .text(`Período: ${filtros.desde ? fFecha(filtros.desde) : 'inicio'} al ${filtros.hasta ? fFecha(filtros.hasta) : 'hoy'}`, M + 8, y + 13, { width: ancho - 16, align: 'center' })
      y += 34
    } else {
      y += 6
    }

    const cols = [
      { label: 'Cuenta',        w: ancho - 70 - 95 - 95 - 100, align: 'left'  },
      { label: 'Clase',         w: 70,  align: 'left'  },
      { label: 'Saldo inicial', w: 95,  align: 'right' },
      { label: 'Débitos',       w: 95,  align: 'right' },
      { label: 'Saldo final',   w: 100, align: 'right' },
    ]
    // Nota: se muestran saldo inicial, débitos y saldo final; los créditos se derivan
    // (saldo_final = saldo_inicial + creditos − debitos). Columna créditos omitida por ancho.
    y = dibujarCabeceraTabla(doc, y, cols)

    cuentas.forEach((c: any, i: number) => {
      y = dibujarFilaItem(doc, y, [
        c.descripcion || '—',
        c.clase || '—',
        $ar(c.saldo_inicial),
        $ar(c.debitos),
        $ar(c.saldo_final),
      ], cols, i % 2 === 1)
      if (y > doc.page.height - 120) { doc.addPage(); y = 50; y = dibujarCabeceraTabla(doc, y, cols) }
    })

    // Totales
    y += 4
    doc.rect(M, y, ancho, 26).fill(COLORES.azul_oscuro)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(9)
       .text(`Débitos: ${$ar(totales.debitos)}   ·   Créditos: ${$ar(totales.creditos)}`, M + 8, y + 9)
    doc.fillColor(COLORES.blanco).font('Helvetica-Bold').fontSize(12)
       .text(`Saldo final: ${$ar(totales.saldo_final)}`, M + 8, y + 8, { width: ancho - 16, align: 'right' })

    dibujarFooter(doc, empresa)
    doc.end()
  })
}
