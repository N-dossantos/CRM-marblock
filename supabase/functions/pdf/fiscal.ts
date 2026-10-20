// supabase/functions/pdf/fiscal.ts
// Factura y Nota de Crédito/Débito con el formato del comprobante que imprime ARCA en "Comprobantes
// en línea": blanco y negro, ORIGINAL / DUPLICADO / TRIPLICADO, la letra en un recuadro con su código
// (RG 1415) y, al pie, el bloque del CAE con el QR de la RG 4892/2020 (PLAN_ARCA §6). Lo que lleva
// depende del estado fiscal:
//   autorizado → número fiscal, CAE, vencimiento y QR;
//   historico  → su número (PV 00002) y la leyenda de registro histórico: el ETL de Tango no trae CAE;
//   el resto   → marca de agua SIN VALIDEZ FISCAL, sin número fiscal ni QR.
// deno-lint-ignore-file no-explicit-any
import PDFDocument from 'npm:pdfkit@0.15.0'
import QRCode from 'npm:qrcode@1.5.4'
import { Buffer } from 'node:buffer'
import { $ar, fFecha, calcularDetalleAlicuotas } from './base.ts'

export interface ContextoFiscal {
  cuitEmisor: string | null   // secret ARCA_CUIT del proyecto: el mismo CUIT que se le informó a ARCA
  ambiente:   string | null   // secret ARCA_AMBIENTE ('homologacion' | 'produccion')
}

const NEGRO = '#000000'
const GRIS  = '#d9d9d9'
const M     = 28            // margen
const PIE   = 112           // alto reservado al pie (bloque CAE / leyenda + número de página)

// Tipos de comprobante de ARCA (PLAN_ARCA §3.1).
const CODIGO_ARCA: Record<string, number> = {
  'FACTURA A': 1, 'ND A': 2, 'NC A': 3,
  'FACTURA B': 6, 'ND B': 7, 'NC B': 8,
}

// Condiciones IVA de clase A que son monotributo (§3.2).
const MONOTRIBUTO = [6, 13, 16]

// RG 5003/2021, art. 20 pto. 1 (sustituye el art. 15 inc. a de la RG 1415). Texto a confirmar con el
// contador (PLAN_ARCA §6).
const LEYENDA_MONOTRIBUTO =
  'El crédito fiscal discriminado en el presente comprobante, sólo podrá ser computado a efectos del ' +
  'Régimen de Sostenimiento e Inclusión Fiscal para Pequeños Contribuyentes de la Ley Nº 27.618'

// Pie del modelo de la especificación del QR de ARCA.
const DESCARGO_ARCA =
  'Esta Administración Federal no se responsabiliza por la veracidad de los datos ingresados en el detalle de la operación'

// Como el PDF de ARCA: el comprobante completo tres veces.
const COPIAS = ['ORIGINAL', 'DUPLICADO', 'TRIPLICADO']

// Todas las facturas del CRM van a cuenta corriente: se cobran después con recibos.
const CONDICION_VENTA = 'Cuenta Corriente'

const ESTADO_LABEL: Record<string, string> = {
  borrador: 'borrador', rechazado: 'rechazado por ARCA',
  en_proceso: 'en emisión', resultado_incierto: 'resultado incierto',
}

const r2     = (n: number) => Math.round(n * 100) / 100
const num    = (v: any) => parseFloat(v) || 0
const digitos = (v: any) => String(v ?? '').replace(/\D/g, '')

// Importe sin signo de pesos, como en las columnas del comprobante de ARCA.
const nAr = (v: any) => $ar(v).replace(/^\$ /, '')

// Cantidad con 2 decimales, o 3 si los tiene (cantidad es numeric(10,3)).
const fCant = (v: any) => {
  const c = num(v)
  const dosDec = Math.abs(Math.round(c * 100) - c * 100) < 1e-6
  return (dosDec ? c.toFixed(2) : c.toFixed(3)).replace('.', ',')
}

const fPct = (p: number) => String(p).replace('.', ',')

// ─────────────────────────────────────────────────────────────────────────────
// QR (RG 4892/2020)
// ─────────────────────────────────────────────────────────────────────────────

// Texto del QR según la especificación de ARCA (versión 1): la URL con el JSON del comprobante en
// base64. Todo sale de lo que se registró al autorizar (arca_registrar_cae), no de los datos actuales
// del cliente. El base64 va sin escapar: con un JSON de dígitos, letras y `{}":,.-` nunca aparecen
// `+` ni `/`, y el `=` del relleno no rompe el parámetro.
export function urlQrArca(c: any, cuitEmisor: string | null): string {
  const datos = {
    ver:        1,
    fecha:      String(c.fecha ?? '').slice(0, 10),
    cuit:       Number(digitos(cuitEmisor)),
    ptoVta:     Number(c.punto_venta),
    tipoCmp:    Number(c.afip_tipo_comprobante),
    nroCmp:     Number(c.numero_comp),
    importe:    r2(num(c.total)),
    moneda:     'PES',
    ctz:        1,
    tipoDocRec: Number(c.afip_doc_tipo),
    nroDocRec:  Number(digitos(c.afip_doc_nro)),
    tipoCodAut: 'E',
    codAut:     Number(digitos(c.cae)),
  }
  // Un QR que se genera sin error pero con datos incompletos se ve idéntico a uno bueno: mejor no
  // generar el PDF que imprimir uno inválido.
  const faltan = [
    !/^\d{4}-\d{2}-\d{2}$/.test(datos.fecha) && 'fecha',
    digitos(cuitEmisor).length !== 11 && 'CUIT del emisor (ARCA_CUIT)',
    !(datos.ptoVta > 0) && 'punto de venta',
    !(datos.tipoCmp > 0) && 'tipo de comprobante',
    !(datos.nroCmp > 0) && 'número',
    !(datos.tipoDocRec > 0) && 'tipo de documento del receptor',
    !(datos.nroDocRec > 0) && 'documento del receptor',
    digitos(c.cae).length !== 14 && 'CAE',
  ].filter(Boolean)
  if (faltan.length) throw new Error(`No se puede armar el QR del comprobante: falta ${faltan.join(', ')}.`)
  return `https://www.arca.gob.ar/fe/qr/?p=${btoa(JSON.stringify(datos))}`
}

// Dibuja el QR como vector (un rectángulo por tramo de módulos oscuros): impreso queda más nítido que
// una imagen escalada. `lado` incluye el margen blanco de 2 módulos que necesita el lector.
function dibujarQr(doc: any, texto: string, x: number, y: number, lado: number) {
  const { modules } = QRCode.create(texto, { errorCorrectionLevel: 'M' })
  const n = modules.size
  const borde = 2
  const m = lado / (n + borde * 2)
  doc.save()
  doc.rect(x, y, lado, lado).fill('#ffffff')
  for (let fila = 0; fila < n; fila++) {
    let col = 0
    while (col < n) {
      if (!modules.get(fila, col)) { col++; continue }
      const desde = col
      while (col < n && modules.get(fila, col)) col++
      doc.rect(x + (borde + desde) * m, y + (borde + fila) * m, (col - desde) * m, m)
    }
  }
  doc.fill(NEGRO)
  doc.restore()
}

// ─────────────────────────────────────────────────────────────────────────────
// PIEZAS DEL COMPROBANTE
// ─────────────────────────────────────────────────────────────────────────────

// "Etiqueta: valor" con la etiqueta en negrita; el valor ocupa `lineas` renglones como máximo y lo
// que no entra se corta con "…".
function campo(doc: any, etiqueta: string, valor: any, x: number, y: number, ancho: number, tam = 8.5, lineas = 1) {
  const etq = `${etiqueta}: `
  doc.fillColor(NEGRO).font('Helvetica-Bold').fontSize(tam)
  const wEtq = doc.widthOfString(etq)
  doc.text(etq, x, y, { lineBreak: false })
  doc.font('Helvetica')
     .text(String(valor ?? '—'), x + wEtq, y, { width: Math.max(ancho - wEtq, 20), height: tam * 1.2 * lineas, ellipsis: true })
}

function condicionIvaEmisor(texto: any) {
  const t = String(texto ?? '').trim()
  return !t || /^resp(\.|onsable)?\s+inscripto$/i.test(t) ? 'IVA Responsable Inscripto' : t
}

interface Datos {
  c: any
  empresa: any
  titulo: string
  letra: string
  codigo: number
  autorizado: boolean
  historico: boolean
  homologacion: boolean
  extraReceptor: [string, string] | null
}

// Copia (ORIGINAL / DUPLICADO / TRIPLICADO) + cabecera del emisor + receptor. Se repite en cada
// página, como en el comprobante de ARCA.
function dibujarEncabezado(doc: any, d: Datos, copia: string): number {
  const W = doc.page.width
  const ancho = W - M * 2
  const medio = W / 2
  const { c, empresa } = d

  doc.lineWidth(0.8).strokeColor(NEGRO)
  doc.rect(M, 28, ancho, 18).stroke()
  doc.fillColor(NEGRO).font('Helvetica-Bold').fontSize(11)
     .text(copia, M, 32.5, { width: ancho, align: 'center', lineBreak: false })

  // Recuadro de la cabecera, partido al medio por la letra.
  const yC = 46
  const hC = 122
  doc.rect(M, yC, ancho, hC).stroke()
  const lado = 46
  doc.rect(medio - lado / 2, yC, lado, lado).fillAndStroke('#ffffff', NEGRO)
  doc.fillColor(NEGRO).font('Helvetica-Bold').fontSize(28)
     .text(d.letra, medio - lado / 2, yC + 5, { width: lado, align: 'center', lineBreak: false })
  doc.font('Helvetica-Bold').fontSize(6.5)
     .text(`COD. ${String(d.codigo).padStart(2, '0')}`, medio - lado / 2, yC + 35, { width: lado, align: 'center', lineBreak: false })
  doc.moveTo(medio, yC + lado).lineTo(medio, yC + hC).stroke()

  // Emisor (izquierda)
  const xI = M + 8
  const wI = medio - lado / 2 - xI - 6
  doc.fillColor(NEGRO).font('Helvetica-Bold').fontSize(16)
     .text(String(empresa?.razon_social || '—').toUpperCase(), xI, yC + 14, { width: wI, align: 'center', height: 40, ellipsis: true })
  const wIc = medio - xI - 8
  campo(doc, 'Razón Social', empresa?.razon_social, xI, yC + 62, wIc)
  campo(doc, 'Domicilio Comercial', empresa?.direccion, xI, yC + 76, wIc, 8.5, 2)
  campo(doc, 'Condición frente al IVA', condicionIvaEmisor(empresa?.condicion_iva), xI, yC + 104, wIc)

  // Comprobante (derecha)
  const xD = medio + lado / 2 + 10
  const wD = W - M - xD - 6
  doc.fillColor(NEGRO).font('Helvetica-Bold').fontSize(d.titulo.length > 10 ? 16 : 20)
     .text(d.titulo, xD, yC + 14, { width: wD, lineBreak: false })
  const xD2 = medio + 12
  const wD2 = W - M - xD2 - 6
  const fiscal = d.autorizado || d.historico
  const pv  = fiscal ? String(c.punto_venta ?? '').padStart(5, '0') : '—'
  const nro = fiscal ? String(c.numero_comp ?? '').padStart(8, '0') : '—'
  campo(doc, 'Punto de Venta', pv, xD2, yC + 48, 110)
  campo(doc, 'Comp. Nro', nro, xD2 + 112, yC + 48, wD2 - 112)
  campo(doc, 'Fecha de Emisión', fFecha(c.fecha), xD2, yC + 62, wD2)
  campo(doc, 'CUIT', digitos(empresa?.cuit) || '—', xD2, yC + 82, wD2)
  campo(doc, 'Ingresos Brutos', empresa?.ingresos_brutos, xD2, yC + 96, wD2)
  campo(doc, 'Fecha de Inicio de Actividades', empresa?.inicio_actividades, xD2, yC + 110, wD2)

  // Receptor. Una vez autorizado, el documento es el que se le informó a ARCA.
  const yR = yC + hC + 4
  const hR = 52
  doc.rect(M, yR, ancho, hR).stroke()
  const docTipo = d.autorizado ? c.afip_doc_tipo : c.doc_tipo
  const docNro  = d.autorizado ? c.afip_doc_nro  : c.doc_nro
  const docLbl  = +docTipo === 96 ? 'DNI' : 'CUIT'
  const xR = M + 6
  campo(doc, docLbl, digitos(docNro) || '—', xR, yR + 7, 150)
  campo(doc, 'Apellido y Nombre / Razón Social', c.razon_social, xR + 160, yR + 7, ancho - 172)
  campo(doc, 'Condición frente al IVA', c.condicion_iva, xR, yR + 22, 250)
  campo(doc, 'Domicilio', c.direccion || '—', xR + 260, yR + 22, ancho - 272)
  campo(doc, 'Condición de venta', CONDICION_VENTA, xR, yR + 37, 250)
  if (d.extraReceptor) campo(doc, d.extraReceptor[0], d.extraReceptor[1], xR + 260, yR + 37, ancho - 272)

  return yR + hR + 6
}

// Columnas de la tabla: la A discrimina el IVA por ítem; la B lleva los precios con IVA incluido.
function columnas(letra: string, ancho: number) {
  const cols = letra === 'A'
    ? [
        { label: 'Código',              w: 42, align: 'left'   },
        { label: 'Producto / Servicio', w: 0,  align: 'left'   },
        { label: 'Cantidad',            w: 46, align: 'right'  },
        { label: 'U. Medida',           w: 46, align: 'center' },
        { label: 'Precio Unit.',        w: 58, align: 'right'  },
        { label: '% Bonif',             w: 34, align: 'right'  },
        { label: 'Subtotal',            w: 60, align: 'right'  },
        { label: 'Alícuota IVA',        w: 40, align: 'right'  },
        { label: 'Subtotal c/IVA',      w: 64, align: 'right'  },
      ]
    : [
        { label: 'Código',              w: 42, align: 'left'   },
        { label: 'Producto / Servicio', w: 0,  align: 'left'   },
        { label: 'Cantidad',            w: 50, align: 'right'  },
        { label: 'U. Medida',           w: 50, align: 'center' },
        { label: 'Precio Unit.',        w: 64, align: 'right'  },
        { label: '% Bonif',             w: 38, align: 'right'  },
        { label: 'Imp. Bonif.',         w: 56, align: 'right'  },
        { label: 'Subtotal',            w: 70, align: 'right'  },
      ]
  cols[1].w = ancho - cols.reduce((a, col) => a + col.w, 0)
  return cols
}

function dibujarCabeceraItems(doc: any, y: number, cols: any[]) {
  const ancho = cols.reduce((a, col) => a + col.w, 0)
  doc.font('Helvetica-Bold').fontSize(7.5)
  const alto = Math.max(...cols.map(col => doc.heightOfString(col.label, { width: col.w - 6 })))
  const h = Math.ceil(alto) + 8
  doc.rect(M, y, ancho, h).fillAndStroke(GRIS, NEGRO)
  doc.fillColor(NEGRO)
  let x = M
  for (const col of cols) {
    const hTxt = doc.heightOfString(col.label, { width: col.w - 6 })
    doc.text(col.label, x + 3, y + (h - hTxt) / 2, { width: col.w - 6, align: col.align })
    x += col.w
  }
  return y + h
}

function altoFila(doc: any, valores: string[], cols: any[]) {
  doc.font('Helvetica').fontSize(8)
  return Math.max(14, Math.ceil(Math.max(...valores.map((v, i) => doc.heightOfString(v, { width: cols[i].w - 6 })))) + 5)
}

function dibujarFila(doc: any, y: number, valores: string[], cols: any[]) {
  doc.fillColor(NEGRO).font('Helvetica').fontSize(8)
  let x = M
  for (let i = 0; i < cols.length; i++) {
    doc.text(valores[i], x + 3, y + 3, { width: cols[i].w - 6, align: cols[i].align })
    x += cols[i].w
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// COMPROBANTE FISCAL
// ─────────────────────────────────────────────────────────────────────────────
export async function generarComprobanteFiscal(
  c: any, empresa: any, ctx: ContextoFiscal, clase: 'factura' | 'nota',
): Promise<Uint8Array> {
  const autorizado = c.estado_fiscal === 'autorizado'
  const historico  = c.estado_fiscal === 'historico'
  // El QR se arma antes de empezar: si faltan datos, el PDF no sale.
  const qr = autorizado ? urlQrArca(c, ctx.cuitEmisor) : null

  const letra  = clase === 'factura' ? c.tipo : (c.tipo_letra || 'A')
  const titulo = clase === 'factura' ? 'FACTURA' : c.tipo === 'NC' ? 'NOTA DE CRÉDITO' : 'NOTA DE DÉBITO'
  const codigo = Number(c.afip_tipo_comprobante) ||
    CODIGO_ARCA[clase === 'factura' ? `FACTURA ${letra}` : `${c.tipo} ${letra}`]

  const extraReceptor: [string, string] | null = clase === 'factura'
    ? (c.remito_numero ? ['Remito', c.remito_numero] : null)
    : (c.factura_numero ? ['Comprobante asociado', `Factura ${c.factura_tipo || letra} ${c.factura_numero}`] : null)

  const d: Datos = {
    c, empresa, titulo, letra, codigo, autorizado, historico,
    homologacion: ctx.ambiente === 'homologacion', extraReceptor,
  }

  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0, bufferPages: true })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = doc.page.width
    const H = doc.page.height
    const ancho = W - M * 2
    const limite = H - PIE - 4

    // ── Ítems ──────────────────────────────────────────────────────────────
    const cols  = columnas(letra, ancho)
    const items = c.items || []
    let sumaConIva = 0   // Factura B: suma de los subtotales con IVA de las filas
    const filas = items.map((it: any) => {
      const cant   = num(it.cantidad)
      const precio = num(it.precio_unitario)
      const dto    = num(it.descuento_item)
      const pct    = it.iva_porcentaje != null ? num(it.iva_porcentaje) : 21
      const sub    = cant * precio * (1 - dto / 100)
      const conIva = r2(sub * (1 + pct / 100))
      if (letra === 'A') {
        return [it.codigo || '', it.descripcion || '', fCant(cant), 'unidades', nAr(precio), nAr(dto),
                nAr(sub), pct === 0 ? 'Exento' : `${fPct(pct)}%`, nAr(conIva)]
      }
      const precioConIva = precio * (1 + pct / 100)
      sumaConIva += conIva
      return [it.codigo || '', it.descripcion || '', fCant(cant), 'unidades', nAr(precioConIva), nAr(dto),
              nAr(cant * precioConIva * dto / 100), nAr(conIva)]
    })

    // ── Totales ────────────────────────────────────────────────────────────
    const total  = num(c.total)
    const otros  = num(c.percepciones_monto) ||
      (c.percepciones || []).reduce((a: number, p: any) => a + num(p.monto), 0)
    const dtoGral = num(c.descuento_general)
    const lineas: [string, number, boolean?][] = []
    if (letra === 'A') {
      const detalle = calcularDetalleAlicuotas(items, dtoGral)
      const exento  = detalle.find(g => g.porcentaje === 0)?.neto_gravado ?? 0
      const ivaDe   = (p: number) => detalle.find(g => g.porcentaje === p)?.iva_monto ?? 0
      if (dtoGral > 0) {
        lineas.push(['Subtotal', num(c.subtotal)])
        lineas.push([`Bonificación general ${fPct(dtoGral)}%`, -num(c.descuento_monto)])
      }
      lineas.push(['Importe Neto Gravado', r2(num(c.neto_gravado) - exento)])
      for (const p of [27, 21, 10.5, 5, 2.5]) lineas.push([`IVA ${fPct(p)}%`, ivaDe(p)])
      if (exento > 0) lineas.push(['Importe Exento', exento])
    } else {
      // La B no discrimina IVA: los ítems y el subtotal van con IVA incluido. El subtotal es el total
      // sin otros tributos; si hay bonificación general, sale de la diferencia con la suma de las
      // filas para que el comprobante cierre al centavo.
      const subtotal = r2(total - otros)
      if (dtoGral > 0) {
        lineas.push(['Subtotal ítems', r2(sumaConIva)])
        lineas.push([`Bonificación general ${fPct(dtoGral)}%`, -r2(sumaConIva - subtotal)])
      }
      lineas.push(['Subtotal', subtotal])
    }
    lineas.push(['Importe Otros Tributos', otros])
    lineas.push(['Importe Total', total, true])

    // Leyendas del ángulo inferior izquierdo del recuadro de totales.
    const leyendas: { texto: string; negrita?: boolean }[] = []
    if (letra === 'B') {
      // Ley 27.743 (RG 5614): en la B, el IVA contenido y los otros impuestos nacionales indirectos.
      leyendas.push({ texto: 'Régimen de Transparencia Fiscal al Consumidor (Ley 27.743)', negrita: true })
      leyendas.push({ texto: `IVA Contenido: ${$ar(c.iva_monto)}` })
      leyendas.push({ texto: `Otros Impuestos Nacionales Indirectos: ${$ar(0)}` })
    } else if (MONOTRIBUTO.includes(Number(c.condicion_iva_afip_id))) {
      leyendas.push({ texto: LEYENDA_MONOTRIBUTO, negrita: true })
    }

    const hLinea = 13
    const hTot = Math.max(lineas.length * hLinea + 14, 60)
    const textoObs = [
      clase === 'nota' && c.motivo ? `Motivo: ${c.motivo}` : null,
      c.observaciones ? `Observaciones: ${c.observaciones}` : null,
    ].filter(Boolean).join('\n')
    doc.font('Helvetica').fontSize(8)
    const hObs = textoObs ? Math.ceil(doc.heightOfString(textoObs, { width: ancho - 12 })) + 10 : 0

    // ── Copias: el mismo comprobante tres veces, cada una con su numeración de páginas ──
    const paginaActual = () => { const { start, count } = doc.bufferedPageRange(); return start + count - 1 }
    const tramos: [number, number][] = []
    COPIAS.forEach((copia, k) => {
      if (k > 0) doc.addPage()
      const primera = paginaActual()

      let y = dibujarCabeceraItems(doc, dibujarEncabezado(doc, d, copia), cols)
      for (const valores of filas) {
        const h = altoFila(doc, valores, cols)
        if (y + h > limite) {
          doc.addPage()
          y = dibujarCabeceraItems(doc, dibujarEncabezado(doc, d, copia), cols)
        }
        dibujarFila(doc, y, valores, cols)
        y += h
      }
      if (y + 6 + hObs + hTot > limite) {
        doc.addPage()
        dibujarCabeceraItems(doc, dibujarEncabezado(doc, d, copia), cols)
      }

      const yTot = limite - hTot
      if (textoObs) {
        doc.fillColor(NEGRO).font('Helvetica').fontSize(8)
           .text(textoObs, M + 6, yTot - hObs, { width: ancho - 12 })
      }
      doc.lineWidth(0.8).rect(M, yTot, ancho, hTot).stroke(NEGRO)
      const xEtq = W / 2 + 10
      const wEtq = 150
      const xVal = xEtq + wEtq + 6
      const wVal = W - M - 8 - xVal
      let yL = yTot + 8
      for (const [etiqueta, valor, fuerte] of lineas) {
        doc.fillColor(NEGRO).font('Helvetica-Bold').fontSize(fuerte ? 9.5 : 8.5)
           .text(`${etiqueta}: $`, xEtq, yL, { width: wEtq, align: 'right', lineBreak: false })
           .text(nAr(valor), xVal, yL, { width: wVal, align: 'right', lineBreak: false })
        yL += hLinea
      }
      let yLey = yTot + 8
      for (const l of leyendas) {
        doc.fillColor(NEGRO).font(l.negrita ? 'Helvetica-Bold' : 'Helvetica').fontSize(8)
           .text(l.texto, M + 8, yLey, { width: W / 2 - M - 14 })
        yLey = doc.y + 3
      }

      tramos.push([primera, paginaActual()])
    })

    // ── Pie, franja y marca de agua en cada página ────────────────────────
    for (const [primera, ultima] of tramos) {
      for (let i = primera; i <= ultima; i++) {
        doc.switchToPage(i)
        dibujarPie(doc, d, qr, i - primera + 1, ultima - primera + 1)
        if (d.homologacion) dibujarFranjaHomologacion(doc)
        if (!autorizado && !historico) dibujarMarcaDeAgua(doc, 'SIN VALIDEZ FISCAL')
      }
    }

    doc.end()
  })
}

function dibujarPie(doc: any, d: Datos, qr: string | null, pagina: number, paginas: number) {
  const W = doc.page.width
  const H = doc.page.height
  const yP = H - PIE + 4
  const { c } = d

  doc.fillColor(NEGRO).font('Helvetica-Bold').fontSize(8)
     .text(`Pág. ${pagina}/${paginas}`, 0, yP + 4, { width: W, align: 'center', lineBreak: false })

  if (qr) {
    const lado = 82
    dibujarQr(doc, qr, M, yP, lado)
    const xA = M + lado + 10
    doc.fillColor(NEGRO).font('Helvetica-Bold').fontSize(26).text('ARCA', xA, yP + 14, { lineBreak: false })
    doc.font('Helvetica-BoldOblique').fontSize(9).text('Comprobante Autorizado', xA, yP + 42, { lineBreak: false })
    doc.font('Helvetica-Oblique').fontSize(6).text(DESCARGO_ARCA, xA, yP + 56, { width: 250 })

    const xC = W - M - 190
    campo(doc, 'CAE N°', digitos(c.cae), xC, yP + 22, 190, 9.5)
    campo(doc, 'Fecha de Vto. de CAE', fFecha(c.cae_vencimiento), xC, yP + 38, 190, 9.5)
  } else {
    const texto = d.historico
      ? 'REGISTRO HISTÓRICO — SIN CAE REGISTRADO EN EL CRM'
      : 'SIN VALIDEZ FISCAL — NO AUTORIZADO POR ARCA'
    const detalle = d.historico
      ? 'Comprobante cargado antes de la emisión desde el CRM. Su validez fiscal se verifica en ARCA.'
      : `Comprobante interno #${c.id} (${ESTADO_LABEL[c.estado_fiscal] || c.estado_fiscal}): todavía no tiene número fiscal ni CAE.`
    doc.lineWidth(0.8).rect(M, yP + 22, W - M * 2, 40).stroke(NEGRO)
    doc.fillColor(NEGRO).font('Helvetica-Bold').fontSize(10)
       .text(texto, M, yP + 30, { width: W - M * 2, align: 'center', lineBreak: false })
    doc.font('Helvetica').fontSize(7.5)
       .text(detalle, M, yP + 46, { width: W - M * 2, align: 'center', lineBreak: false })
  }

  doc.moveTo(M, H - 22).lineTo(W - M, H - 22).lineWidth(0.8).stroke(NEGRO)
}

// Proyecto de homologación: un PDF de prueba con CAE y QR no tiene que poder pasar por uno real.
function dibujarFranjaHomologacion(doc: any) {
  const W = doc.page.width
  doc.save()
  doc.rect(M, 8, W - M * 2, 16).fill('#c00000')
  doc.fillColor('#ffffff').font('Helvetica-Bold').fontSize(8.5)
     .text('HOMOLOGACIÓN — COMPROBANTE DE PRUEBA SIN VALIDEZ FISCAL', M, 12.5, { width: W - M * 2, align: 'center', lineBreak: false })
  doc.restore()
}

function dibujarMarcaDeAgua(doc: any, texto: string) {
  const W = doc.page.width
  const H = doc.page.height
  doc.save()
  doc.rotate(-40, { origin: [W / 2, H / 2] })
  doc.fillColor('#000000', 0.1).font('Helvetica-Bold').fontSize(64)
     .text(texto, W / 2 - 400, H / 2 - 32, { width: 800, align: 'center', lineBreak: false })
  doc.restore()
}
