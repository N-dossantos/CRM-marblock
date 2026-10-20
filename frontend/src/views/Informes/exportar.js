// src/views/Informes/exportar.js
// Qué columnas lleva el .xlsx de cada informe (M12). Cada entrada recibe los mismos `data` que
// dibuja la pantalla y los filtros, y devuelve { archivo, hojas } para exportarXlsx(). Las columnas
// siguen las de la tabla en pantalla; los libros IVA suman lo que el contador necesita (neto e IVA
// por alícuota, percepciones por tipo).
import { $ar, fFecha, fDocNro } from '../../utils'
import { nombreArchivo } from '../../utils/excel'

const periodo = ({ desde, hasta }) =>
  `Período: ${desde ? fFecha(desde) : 'inicio'} al ${hasta ? fFecha(hasta) : 'hoy'}`

const col = (titulo, valor, tipo = 'texto', ancho) => ({ titulo, valor, tipo, ancho })

// Libro IVA Compras: neto e IVA por alícuota en columnas propias (las alícuotas que aparezcan en el
// período), como lo pide el contador para el F.2002. Las NC/ND no tienen desglose por alícuota:
// su neto e IVA van a la columna "sin desglose" (si hay alguna en el período).
function libroIvaCompras(data, f) {
  const comps = data.comprobantes || []
  const alicuotas = [...new Set(comps.flatMap(c => (c.iva_detalle || []).map(d => Number(d.porcentaje))))].sort((a, b) => b - a)
  const porAlic = (c, p, campo) => (c.iva_detalle || [])
    .filter(d => Number(d.porcentaje) === p).reduce((a, d) => a + Number(d[campo] || 0), 0)
  const sinDetalle = comps.some(c => !(c.iva_detalle || []).length)
  const cols = [
    col('Fecha',        c => c.fecha, 'fecha'),
    col('Comprobante',  c => c.comprobante, 'texto', 8),
    col('Letra',        c => c.tipo, 'texto', 6),
    col('Número',       c => c.numero, 'texto', 16),
    col('Proveedor',    c => c.razon_social, 'texto', 34),
    col('CUIT',         c => c.cuit, 'texto', 14),
    // Alícuota 0 = conceptos exentos / no gravados: sólo neto, el IVA es siempre 0.
    ...alicuotas.flatMap(p => (p === 0
      ? [col('Exento / no gravado', c => porAlic(c, 0, 'neto_gravado'), 'importe', 17)]
      : [col(`Neto ${p}%`, c => porAlic(c, p, 'neto_gravado'), 'importe'),
         col(`IVA ${p}%`,  c => porAlic(c, p, 'iva_monto'), 'importe')])),
    ...(sinDetalle ? [
      col('Neto sin desglose', c => ((c.iva_detalle || []).length ? 0 : c.neto_gravado), 'importe'),
      col('IVA sin desglose',  c => ((c.iva_detalle || []).length ? 0 : c.iva_monto), 'importe'),
    ] : []),
    col('Neto gravado',    c => c.neto_gravado, 'importe'),
    col('IVA total',       c => c.iva_monto, 'importe'),
    col('Percep. IVA',     c => c.percepcion_iva, 'importe'),
    col('Percep. IIBB',    c => c.percepcion_iibb, 'importe'),
    col('Otras percep.',   c => c.percepcion_otros, 'importe'),
    col('Total',           c => c.total, 'importe'),
  ]
  const hojas = [{
    nombre: 'Libro IVA Compras',
    encabezado: ['Libro IVA Compras', periodo(f), 'Las notas de crédito restan (importes negativos).'],
    columnas: cols, filas: comps,
    total: { titulo: 'Totales', columnas: cols.filter(c => c.tipo === 'importe').map(c => c.titulo) },
  }]
  if (data.percepciones_resumen?.length) {
    const pc = [
      col('Tipo',         r => r.tipo, 'texto', 14),
      col('Jurisdicción', r => r.jurisdiccion || '—', 'texto', 18),
      col('Comprobantes', r => r.comprobantes, 'numero', 13),
      col('Monto',        r => r.monto, 'importe'),
    ]
    hojas.push({ nombre: 'Percepciones', encabezado: ['Percepciones sufridas', periodo(f)], columnas: pc,
      filas: data.percepciones_resumen, total: { titulo: 'Total', columnas: ['Monto'] } })
  }
  if (data.retenciones?.length) {
    const rc = [
      col('Fecha',        r => r.fecha, 'fecha'),
      col('Proveedor',    r => r.razon_social, 'texto', 34),
      col('CUIT',         r => r.cuit, 'texto', 14),
      col('Tipo',         r => r.tipo_retencion, 'texto', 14),
      col('Jurisdicción', r => r.jurisdiccion, 'texto', 16),
      col('Certificado',  r => r.numero_certificado, 'texto', 18),
      col('Monto',        r => r.monto, 'importe'),
    ]
    hojas.push({ nombre: 'Retenciones', encabezado: ['Retenciones practicadas', periodo(f)], columnas: rc,
      filas: data.retenciones, total: { titulo: 'Total', columnas: ['Monto'] } })
  }
  return { archivo: nombreArchivo('Libro_IVA_Compras', f.desde, f.hasta), hojas }
}

function libroIvaVentas(data, f) {
  const cols = [
    col('Fecha',          c => c.fecha, 'fecha'),
    col('Comprobante',    c => c.comprobante, 'texto', 8),
    col('Letra',          c => c.letra, 'texto', 6),
    col('Número',         c => c.numero, 'texto', 16),
    col('Cliente',        c => c.razon_social, 'texto', 34),
    col('CUIT / DNI',      c => fDocNro(c.doc_tipo, c.doc_nro), 'texto', 14),
    col('Condición IVA',  c => c.condicion_iva, 'texto', 16),
    col('Neto gravado',   c => c.neto_gravado, 'importe'),
    col('IVA 21%',        c => c.iva_monto, 'importe'),
    col('Percepciones',   c => c.percepciones_monto, 'importe'),
    col('Total',          c => c.total, 'importe'),
    col('Anulada',        c => (c.anulada ? 'Sí' : ''), 'texto', 8),
  ]
  const rc = [
    col('Comprobante',  r => `${r.comprobante} ${r.letra || ''}`.trim(), 'texto', 12),
    col('Cantidad',     r => r.cantidad, 'numero'),
    col('Neto gravado', r => r.neto_gravado, 'importe'),
    col('IVA 21%',      r => r.iva_monto, 'importe'),
    col('Percepciones', r => r.percepciones_monto, 'importe'),
    col('Total',        r => r.total, 'importe'),
  ]
  const importes = ['Neto gravado', 'IVA 21%', 'Percepciones', 'Total']
  return {
    archivo: nombreArchivo('Libro_IVA_Ventas', f.desde, f.hasta),
    hojas: [
      { nombre: 'Libro IVA Ventas', encabezado: ['Libro IVA Ventas', periodo(f), 'Las notas de crédito restan (importes negativos).'],
        columnas: cols, filas: data.comprobantes || [], total: { titulo: 'Totales', columnas: importes } },
      { nombre: 'Resumen', encabezado: ['Libro IVA Ventas — resumen por comprobante', periodo(f)],
        columnas: rc, filas: data.resumen || [], total: { titulo: 'Totales', columnas: importes } },
    ],
  }
}

export const EXCEL = {
  iva_compras: libroIvaCompras,
  iva_ventas:  libroIvaVentas,

  // ── Tesorería ──
  mayor_tes: (data, f) => {
    const cols = [
      col('Cuenta',          c => c.descripcion, 'texto', 30),
      col('Clase',           c => c.clase, 'texto', 12),
      col('Entradas (Debe)', c => c.creditos, 'importe', 16),
      col('Salidas (Haber)', c => c.debitos, 'importe', 16),
      col('Diferencia',      c => (+c.creditos || 0) - (+c.debitos || 0), 'importe'),
    ]
    return {
      archivo: nombreArchivo('Mayor_Tesoreria', f.desde, f.hasta),
      hojas: [{ nombre: 'Mayor tesorería', encabezado: ['Mayor de Tesorería', periodo(f)], columnas: cols,
        filas: (data.cuentas || []).filter(c => +c.creditos || +c.debitos),
        total: { titulo: 'Totales del período', columnas: ['Entradas (Debe)', 'Salidas (Haber)', 'Diferencia'] } }],
    }
  },
  saldos_tes: (data) => {
    const filas = (data.agrupaciones || []).flatMap(g => (g.cuentas || []).map(c => ({ ...c, agrupacion: g.descripcion })))
    const cols = [
      col('Agrupación',    c => c.agrupacion, 'texto', 20),
      col('Cuenta',        c => c.descripcion, 'texto', 30),
      col('Clase',         c => c.clase, 'texto', 12),
      col('Saldo inicial', c => c.saldo_inicial, 'importe'),
      col('Entradas',      c => c.entradas, 'importe'),
      col('Salidas',       c => c.salidas, 'importe'),
      col('Saldo actual',  c => c.saldo_actual, 'importe'),
    ]
    return {
      archivo: nombreArchivo('Saldos_Tesoreria', new Date().toISOString().slice(0, 10)),
      hojas: [{ nombre: 'Saldos tesorería', encabezado: ['Saldos de Tesorería', `Al ${fFecha(new Date().toISOString().slice(0, 10))}`],
        columnas: cols, filas, total: { titulo: 'Total general', columnas: ['Saldo actual'] } }],
    }
  },
  subdiario_tes: (data, f) => {
    const cols = [
      col('Fecha',       m => m.fecha, 'fecha'),
      col('Comprobante', m => m.numero || `#${m.id}`, 'texto', 16),
      col('Tipo',        m => [m.tipo_codigo, m.tipo_descripcion].filter(Boolean).join(' '), 'texto', 24),
      col('Concepto',    m => (m.anulado ? `${m.concepto || ''} (anulado)` : m.concepto), 'texto', 40),
      col('Entrada',     m => (m.signo === 1 ? m.monto : null), 'importe'),
      col('Salida',      m => (m.signo === -1 ? m.monto : null), 'importe'),
      col('Saldo',       m => m.saldo_corrido, 'importe'),
    ]
    const cuenta = data.cuenta?.descripcion || 'Cuenta'
    return {
      archivo: nombreArchivo('Subdiario', cuenta, f.desde, f.hasta),
      hojas: [{ nombre: 'Subdiario', columnas: cols, filas: data.movimientos || [],
        encabezado: [`Subdiario — ${cuenta}`, periodo(f), `Saldo inicial: ${$ar(data.saldo_inicial)}  ·  Saldo final: ${$ar(data.saldo_final)}`],
        total: { titulo: 'Totales', columnas: ['Entrada', 'Salida'] } }],
    }
  },
  oper_tes: (data, f) => {
    const cols = [
      col('Código',    o => o.codigo, 'texto', 10),
      col('Operación', o => o.descripcion, 'texto', 34),
      col('Cantidad',  o => o.cantidad, 'numero'),
      col('Entradas',  o => o.entradas, 'importe'),
      col('Salidas',   o => o.salidas, 'importe'),
      col('Neto',      o => o.neto, 'importe'),
    ]
    return {
      archivo: nombreArchivo('Movimientos_por_operacion', f.desde, f.hasta),
      hojas: [{ nombre: 'Por operación', encabezado: ['Movimientos por operación', periodo(f)], columnas: cols,
        filas: data.operaciones || [], total: { titulo: 'Totales', columnas: ['Entradas', 'Salidas', 'Neto'] } }],
    }
  },
  cheques_tes: (data, f) => {
    const cols = [
      col('Origen',      c => c.origen, 'texto', 9),
      col('Número',      c => c.numero, 'texto', 14),
      col('Banco',       c => c.banco, 'texto', 22),
      col('Tipo',        c => c.tipo, 'texto', 10),
      col('Entidad',     c => c.entidad, 'texto', 30),
      col('Emisión',     c => c.fecha_emision, 'fecha'),
      col('Vencimiento', c => c.fecha_venc, 'fecha', 12),
      col('Estado',      c => c.estado, 'texto', 14),
      col('Monto',       c => c.monto, 'importe'),
    ]
    return {
      archivo: nombreArchivo('Cheques', f.estado, f.desde, f.hasta),
      hojas: [{ nombre: 'Cheques', encabezado: ['Cheques', periodo(f)], columnas: cols,
        filas: data.cheques || [], total: { titulo: 'Total', columnas: ['Monto'] } }],
    }
  },
  comprob_tes: (data, f) => {
    const cols = [
      col('Fecha',    m => m.fecha, 'fecha'),
      col('Número',   m => m.numero, 'texto', 16),
      col('Cuenta',   m => m.cuenta, 'texto', 26),
      col('Tipo',     m => m.tipo_codigo, 'texto', 8),
      col('Concepto', m => m.concepto, 'texto', 40),
      col('Origen',   m => m.origen, 'texto', 12),
      col('Importe',  m => m.monto_con_signo, 'importe'),
      col('Anulado',  m => (m.anulado ? 'Sí' : ''), 'texto', 8),
    ]
    return {
      archivo: nombreArchivo('Comprobantes_tesoreria', f.desde, f.hasta),
      hojas: [{ nombre: 'Comprobantes', encabezado: ['Comprobantes de tesorería', periodo(f)], columnas: cols,
        filas: data.movimientos || [], total: { titulo: 'Neto', columnas: ['Importe'] } }],
    }
  },
  historico_tes: (data, f) => {
    const cols = [
      col('Fecha',      m => m.fecha, 'fecha'),
      col('Número',     m => m.numero, 'texto', 16),
      col('Cuenta',     m => m.cuenta_descripcion, 'texto', 26),
      col('Tipo',       m => m.tipo_codigo, 'texto', 8),
      col('Concepto',   m => m.concepto, 'texto', 40),
      col('Origen',     m => m.origen, 'texto', 12),
      col('Importe',    m => m.monto_con_signo, 'importe'),
      col('Anulado',    m => (m.anulado ? 'Sí' : ''), 'texto', 8),
      col('Conciliado', m => (m.conciliado ? 'Sí' : ''), 'texto', 10),
    ]
    return {
      archivo: nombreArchivo('Historico_tesoreria', f.desde, f.hasta),
      hojas: [{ nombre: 'Histórico', encabezado: ['Histórico de tesorería', periodo(f)], columnas: cols,
        filas: Array.isArray(data) ? data : [], total: { titulo: 'Neto', columnas: ['Importe'] } }],
    }
  },

  // ── Contabilidad ──
  // El diario va una línea por renglón de asiento, con los datos del asiento repetidos, para que se
  // pueda filtrar por cuenta o por asiento en Excel.
  libro_diario: (data, f) => {
    const filas = (data.asientos || []).flatMap(a => (a.lineas || []).map(l => ({ ...l, asiento: a })))
    const cols = [
      col('Asiento',     l => l.asiento.numero, 'texto', 10),
      col('Fecha',       l => l.asiento.fecha, 'fecha'),
      col('Descripción', l => l.asiento.descripcion, 'texto', 36),
      col('Origen',      l => l.asiento.origen, 'texto', 12),
      col('Código',      l => l.codigo, 'texto', 14),
      col('Cuenta',      l => l.cuenta, 'texto', 30),
      col('Detalle',     l => l.detalle, 'texto', 30),
      col('Debe',        l => (Number(l.debe) > 0 ? l.debe : null), 'importe'),
      col('Haber',       l => (Number(l.haber) > 0 ? l.haber : null), 'importe'),
    ]
    return {
      archivo: nombreArchivo('Libro_Diario', f.desde, f.hasta),
      hojas: [{ nombre: 'Libro Diario', encabezado: ['Libro Diario', periodo(f)], columnas: cols, filas,
        total: { titulo: 'Totales', columnas: ['Debe', 'Haber'] } }],
    }
  },
  libro_mayor: (data, f) => {
    const cuenta = `${data.cuenta?.codigo || ''} ${data.cuenta?.descripcion || ''}`.trim() || 'Cuenta'
    const cols = [
      col('Fecha',       m => m.fecha, 'fecha'),
      col('Asiento',     m => m.numero, 'texto', 10),
      col('Descripción', m => m.descripcion, 'texto', 36),
      col('Detalle',     m => m.detalle, 'texto', 30),
      col('Debe',        m => (Number(m.debe) > 0 ? m.debe : null), 'importe'),
      col('Haber',       m => (Number(m.haber) > 0 ? m.haber : null), 'importe'),
      col('Saldo',       m => m.saldo, 'importe'),
    ]
    return {
      archivo: nombreArchivo('Libro_Mayor', data.cuenta?.codigo, f.desde, f.hasta),
      hojas: [{ nombre: 'Libro Mayor', columnas: cols, filas: data.movimientos || [],
        encabezado: [`Libro Mayor — ${cuenta}`, periodo(f), `Saldo inicial: ${$ar(data.saldo_inicial)}  ·  Saldo final: ${$ar(data.totales?.saldo_final)}`],
        total: { titulo: 'Totales', columnas: ['Debe', 'Haber'] } }],
    }
  },
  sumas_saldos: (data, f) => {
    const cols = [
      col('Código',        c => c.codigo, 'texto', 14),
      col('Cuenta',        c => c.descripcion, 'texto', 34),
      col('Tipo',          c => c.tipo_cuenta, 'texto', 12),
      col('Saldo inicial', c => c.saldo_inicial, 'importe'),
      col('Debe',          c => c.debe, 'importe'),
      col('Haber',         c => c.haber, 'importe'),
      col('Saldo final',   c => c.saldo_final, 'importe'),
    ]
    return {
      archivo: nombreArchivo('Sumas_y_Saldos', f.desde, f.hasta),
      hojas: [{ nombre: 'Sumas y Saldos', encabezado: ['Balance de Sumas y Saldos', periodo(f)], columnas: cols,
        filas: data.cuentas || [], total: { titulo: 'Totales', columnas: ['Debe', 'Haber', 'Saldo final'] } }],
    }
  },
}
