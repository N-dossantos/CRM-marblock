// supabase/functions/pdf/preimpreso.ts
// Sobreimpresión sobre el talonario de remitos PREIMPRESO (AGEE, A4, original blanco +
// duplicado color). A diferencia de los templates de ./templates.ts, acá NO se dibuja
// absolutamente nada de diseño: ni marco, ni logo, ni footer, ni caja de firma. Todo eso
// ya está impreso en el papel. Sólo se posiciona texto negro en coordenadas absolutas
// medidas sobre un escaneo del formulario real.
//
// Las coordenadas están en MILÍMETROS (no en puntos): son medibles con una regla contra
// el papel, que es como se corrigen. mm() las pasa a puntos para pdfkit.
// deno-lint-ignore-file no-explicit-any
import PDFDocument from 'npm:pdfkit@0.15.0'
import { Buffer } from 'node:buffer'

// 1 pulgada = 25.4 mm = 72 pt
export const mm = (n: number) => (n * 72) / 25.4

// dd/mm/aaaa con ceros a la izquierda. No se usa fFecha() de ./base.ts porque
// toLocaleDateString('es-AR') devuelve "20/8/2026" sin rellenar, y en un comprobante
// que se firma y se archiva el ancho fijo importa.
const fecha10 = (s: any) => {
  if (!s) return ''
  const d = new Date(String(s) + 'T12:00:00')
  if (isNaN(d.getTime())) return ''
  const p = (n: number) => String(n).padStart(2, '0')
  return `${p(d.getDate())}/${p(d.getMonth() + 1)}/${d.getFullYear()}`
}

// ─────────────────────────────────────────────────────────────────────────────
// MAPA DEL FORMULARIO — todo en mm desde el borde superior izquierdo de la hoja.
//
// Derivado de un escaneo A4 del talonario en blanco (1131x1600 px => 5.386 px/mm),
// detectando los bordes de los recuadros por densidad de píxeles oscuros. Los bordes
// medidos, como referencia para futuros ajustes:
//   caja Señor(es)  y  54.6 -> 85.9    caja Condiciones  y 87.6 -> 102.1
//   área de ítems   y 110.6 -> 251.9   Domicilio|Teléfono y 259.3 -> 268.0
//   márgenes laterales de las cajas: x 16.2 -> 206.5, tabique domic./tel. en x 111
// ─────────────────────────────────────────────────────────────────────────────
export const MAPA = {
  fecha:             { x: 140, y: 33 },
  cliente:           { x: 35,  y: 60, ancho: 95 },
  direccion:         { x: 20,  y: 68, ancho: 110 },
  localidad:         { x: 20,  y: 74, ancho: 110 },
  iva:               { x: 133, y: 60, ancho: 70 },
  cuit:              { x: 133, y: 67, ancho: 70 },
  condiciones_venta: { x: 53,  y: 93, ancho: 140 },
  domicilio_obra:    { x: 20,  y: 260, ancho: 88 },
  telefono:          { x: 116, y: 260, ancho: 88 },

  // Ítems: el papel tiene UNA sola caja rotulada "Descripción", sin líneas de columna.
  // Las columnas son invisibles — se arman por posición: la cantidad termina alineada
  // a la derecha en x=38 y la descripción arranca en x=52.
  items: {
    y_inicial:   113,
    alto_renglon: 6,
    // En la caja entrarían 23 renglones ((251.9 - 110.6) / 6), pero un remito real nunca
    // los usa: se corta en 19 (último renglón en y=221) para dejar libre la leyenda de
    // y=230. Si se cambia, actualizar RENGLONES_TALONARIO en
    // frontend/src/components/Forms/ComprobanteForm.jsx, que valida lo mismo antes de grabar.
    renglones:    19,
    cant_x:       18,
    cant_ancho:   20,   // termina en x=38, alineada a la derecha
    desc_x:       52,
    desc_ancho:   153,  // hasta x=205
  },

  // Leyenda fija al pie del área de ítems, centrada en el ancho de la caja (x 16.2 -> 206.5).
  leyenda: { x: 20, y: 230, ancho: 186 },
} as const

const LEYENDA = 'LA MERCADERIA VIAJA POR CUENTA Y RIESGO DEL COMPRADOR'

const FUENTE       = 'Helvetica'
const FUENTE_NEGRA = 'Helvetica-Bold'

// Dos escalas distintas a propósito: los ítems tienen que entrar en renglones de 6 mm, los
// datos de la cabecera no — sus cajas son mucho más altas y se leen a distancia (el remito se
// firma en la obra, muchas veces con mala luz), así que van más grandes.
const ITEM       = 11
const DATOS      = 13   // cliente, fecha, condiciones
const DATOS_MIN  = 12   // los campos que comparten renglón o caen en cajas angostas

/**
 * Dibuja el contenido de UNA hoja del talonario.
 * `off` es el corrimiento global de la impresora, en mm (ver `?dx=&dy=`).
 */
function dibujarHoja(doc: any, remito: any, off: { dx: number; dy: number }) {
  const X = (v: number) => mm(v + off.dx)
  const Y = (v: number) => mm(v + off.dy)

  const poner = (txt: any, pos: { x: number; y: number; ancho?: number },
                 opts: { size?: number; align?: string; font?: string } = {}) => {
    const s = txt == null ? '' : String(txt).trim()
    if (!s) return
    doc.font(opts.font ?? FUENTE).fontSize(opts.size ?? DATOS).fillColor('#000')
       .text(s, X(pos.x), Y(pos.y), {
         width:     pos.ancho ? mm(pos.ancho) : undefined,
         align:     opts.align ?? 'left',
         lineBreak: false,   // nunca partir: cada campo tiene su renglón en el papel
         ellipsis:  true,
       })
  }

  poner(fecha10(remito.fecha),       MAPA.fecha)
  poner(remito.razon_social,         MAPA.cliente)
  poner(remito.direccion,            MAPA.direccion, { size: DATOS_MIN })
  poner(remito.localidad,            MAPA.localidad, { size: DATOS_MIN })
  poner(remito.condicion_iva,        MAPA.iva,  { size: DATOS_MIN })
  poner(remito.cuit,                 MAPA.cuit, { size: DATOS_MIN })
  poner(remito.condiciones_venta,    MAPA.condiciones_venta)
  poner(remito.domicilio_obra,       MAPA.domicilio_obra,  { size: DATOS_MIN })
  poner(remito.telefono_entrega,     MAPA.telefono,        { size: DATOS_MIN })

  // ── Ítems ──────────────────────────────────────────────────────────────────
  const it    = MAPA.items
  const items = remito.items ?? []
  // Si no entran, se imprimen los que caben menos uno y el último renglón avisa cuántos
  // faltan. Truncar en silencio sería peor: el remito firmado diría menos de lo entregado.
  const desborda = items.length > it.renglones
  const visibles = desborda ? it.renglones - 1 : items.length

  for (let i = 0; i < visibles; i++) {
    const item = items[i]
    const y    = it.y_inicial + i * it.alto_renglon
    poner(item.cantidad, { x: it.cant_x, y, ancho: it.cant_ancho }, { size: ITEM, align: 'right' })
    poner(item.descripcion, { x: it.desc_x, y, ancho: it.desc_ancho }, { size: ITEM })
  }

  if (desborda) {
    const y = it.y_inicial + visibles * it.alto_renglon
    poner(`… y ${items.length - visibles} ítem(s) más — no entran en el formulario`,
          { x: it.desc_x, y, ancho: it.desc_ancho }, { size: ITEM })
  }

  // Leyenda legal al pie del área de ítems: va siempre, haya un ítem o diecinueve.
  poner(LEYENDA, MAPA.leyenda, { size: ITEM, align: 'center', font: FUENTE_NEGRA })
}

/**
 * Remito sobre formulario preimpreso: DOS páginas idénticas, para que el original blanco
 * y el duplicado color cargados juntos en la bandeja salgan en una sola pasada.
 */
export async function generarRemitoPreimpreso(
  remito: any,
  off: { dx: number; dy: number } = { dx: 0, dy: 0 },
): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0 })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    dibujarHoja(doc, remito, off)   // original (blanco)
    doc.addPage()
    dibujarHoja(doc, remito, off)   // duplicado (color)

    doc.end()
  })
}

/**
 * Página de calibración: se imprime UNA vez sobre un formulario real del talonario y se
 * lee directamente dónde cayó cada cruz respecto del recuadro que le toca. Evita ajustar
 * las coordenadas por prueba y error.
 */
export async function generarCalibracion(
  off: { dx: number; dy: number } = { dx: 0, dy: 0 },
): Promise<Uint8Array> {
  return await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: 0 })
    const buffers: any[] = []
    doc.on('data', (b: any) => buffers.push(b))
    doc.on('end',  () => resolve(Buffer.concat(buffers)))
    doc.on('error', reject)

    const W = 210, H = 297

    // Grilla cada 5 mm; la de cada 10 mm más marcada para poder contar de a diez.
    for (let x = 0; x <= W; x += 5) {
      doc.moveTo(mm(x), 0).lineTo(mm(x), mm(H))
         .lineWidth(x % 10 === 0 ? 0.4 : 0.15)
         .strokeColor(x % 10 === 0 ? '#888' : '#ccc').stroke()
    }
    for (let y = 0; y <= H; y += 5) {
      doc.moveTo(0, mm(y)).lineTo(mm(W), mm(y))
         .lineWidth(y % 10 === 0 ? 0.4 : 0.15)
         .strokeColor(y % 10 === 0 ? '#888' : '#ccc').stroke()
    }

    // Números de referencia cada 10 mm, sobre ambos bordes.
    doc.font('Helvetica').fontSize(5).fillColor('#555')
    for (let x = 10; x < W; x += 10) {
      doc.text(String(x), mm(x) + 1, mm(2),      { lineBreak: false })
      doc.text(String(x), mm(x) + 1, mm(H - 4),  { lineBreak: false })
    }
    for (let y = 10; y < H; y += 10) {
      doc.text(String(y), mm(1),       mm(y) + 1, { lineBreak: false })
      doc.text(String(y), mm(W - 6),   mm(y) + 1, { lineBreak: false })
    }

    // Una cruz roja en cada campo del MAPA, con su nombre al lado.
    const cruz = (x: number, y: number, etiqueta: string) => {
      const cx = mm(x + off.dx), cy = mm(y + off.dy)
      doc.lineWidth(0.5).strokeColor('#d00')
         .moveTo(cx - mm(2), cy).lineTo(cx + mm(2), cy).stroke()
         .moveTo(cx, cy - mm(2)).lineTo(cx, cy + mm(2)).stroke()
      doc.font('Helvetica').fontSize(5).fillColor('#d00')
         .text(etiqueta, cx + mm(2.5), cy - mm(1), { lineBreak: false })
    }

    for (const [nombre, pos] of Object.entries(MAPA)) {
      if (nombre === 'items') continue
      cruz((pos as any).x, (pos as any).y, nombre)
    }

    // La leyenda se dibuja tal cual saldrá (misma fuente/cuerpo/ancho), en rojo: es texto
    // fijo, así que en la hoja de calibración se verifica el renglón, no la posición de una cruz.
    doc.font('Helvetica-Bold').fontSize(ITEM).fillColor('#d00')
       .text(LEYENDA, mm(MAPA.leyenda.x + off.dx), mm(MAPA.leyenda.y + off.dy),
             { width: mm(MAPA.leyenda.ancho), align: 'center', lineBreak: false })

    // Primer, medio y último renglón de la tabla de ítems.
    const it = MAPA.items
    for (const i of [0, Math.floor(it.renglones / 2), it.renglones - 1]) {
      const y = it.y_inicial + i * it.alto_renglon
      cruz(it.cant_x, y, `item[${i}].cant`)
      cruz(it.desc_x, y, `item[${i}].desc`)
    }

    doc.font('Helvetica-Bold').fontSize(8).fillColor('#000')
       .text(`CALIBRACIÓN REMITO — grilla 5 mm — offset aplicado dx=${off.dx} dy=${off.dy} mm`,
             mm(20), mm(287), { lineBreak: false })

    doc.end()
  })
}
