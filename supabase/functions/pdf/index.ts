// supabase/functions/pdf/index.ts
// Edge Function que reemplaza a backend/src/routes/pdf.js. Enruta sobre la MISMA estructura de
// paths que el Express viejo (/pdf/factura/:id, /pdf/ventas?…, etc.), así el frontend sólo cambia
// la base URL. Lee los datos a través de las RPC ya existentes (0011/0012), reenviando el JWT del
// usuario, de modo que RLS aplica: sólo `authenticated` puede generar comprobantes.
// deno-lint-ignore-file no-explicit-any
import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import { createClient } from 'npm:@supabase/supabase-js@2'
import {
  generarFactura, generarRemito, generarPresupuesto,
  generarNota, generarRecibo, generarCtaCte, generarCtaCteCuenta2,
  generarComprobanteTesoreria, generarCheque,
} from './templates.ts'
import {
  generarRankingDeudores, generarResumenVentas,
  generarSubdiario, generarSaldos, generarMayorTesoreria,
} from './reportes.ts'
import { generarRemitoPreimpreso, generarCalibracion } from './preimpreso.ts'

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}

function enviarPDF(buffer: Uint8Array, nombre: string) {
  return new Response(buffer, {
    headers: {
      ...CORS,
      'Content-Type':        'application/pdf',
      'Content-Disposition': `inline; filename="${nombre}.pdf"`,
      'Cache-Control':       'no-cache',
    },
  })
}

// Corrimiento global de la impresora, en mm (?dx=1.5&dy=-2). Toda impresora desplaza uno o
// dos milímetros; esto lo compensa sin redeploy. Se acota a ±20 mm para que un parámetro
// mal escrito no mande el texto fuera de la hoja.
function leerOffset(q: URLSearchParams) {
  const num = (v: string | null) => {
    const n = parseFloat(v ?? '')
    return Number.isFinite(n) ? Math.max(-20, Math.min(20, n)) : 0
  }
  return { dx: num(q.get('dx')), dy: num(q.get('dy')) }
}

function jsonError(mensaje: string, status = 400) {
  return new Response(JSON.stringify({ error: mensaje }), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })

  try {
    const url = new URL(req.url)
    // pathname llega como /functions/v1/pdf/<resource>/<id> — tomamos lo que sigue al segmento 'pdf'
    const parts = url.pathname.split('/').filter(Boolean)
    const idx   = parts.indexOf('pdf')
    const segs  = idx >= 0 ? parts.slice(idx + 1) : parts
    const [resource, id] = segs
    const q = url.searchParams

    // Cliente Supabase con el JWT del usuario -> las RPC corren como `authenticated` (RLS aplica).
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } },
    )

    const getEmpresa = async () => {
      const { data, error } = await supabase.from('config_empresa').select('clave,valor')
      if (error) throw error
      return (data ?? []).reduce((acc: any, r: any) => ({ ...acc, [r.clave]: r.valor }), {})
    }

    const rpcOne = async (fn: string, args: any) => {
      const { data, error } = await supabase.rpc(fn, args)
      if (error) throw error
      return Array.isArray(data) ? (data[0] ?? null) : (data ?? null)
    }

    switch (resource) {
      // ─── COMPROBANTES ──────────────────────────────────────────────────────
      case 'factura': {
        const factura = await rpcOne('facturas_list', { p_id: Number(id) })
        if (!factura) return jsonError('Factura no encontrada', 404)
        const buffer = await generarFactura(factura, await getEmpresa())
        return enviarPDF(buffer, `Factura-${factura.numero}`)
      }
      case 'remito': {
        // `id` = 'calibracion' imprime la grilla milimetrada en vez de un remito: se pasa
        // una vez sobre un formulario en blanco para leer las coordenadas reales.
        if (id === 'calibracion') {
          const buffer = await generarCalibracion(leerOffset(q))
          return enviarPDF(buffer, 'Calibracion-Remito')
        }
        const remito = await rpcOne('remitos_list', { p_id: Number(id) })
        if (!remito) return jsonError('Remito no encontrado', 404)
        // ?preimpreso=1 -> sobreimpresión sobre el talonario (2 páginas, sin diseño).
        // Sin el flag sigue saliendo el PDF completo de siempre, que es el que se manda por mail.
        if (q.get('preimpreso') === '1') {
          const buffer = await generarRemitoPreimpreso(remito, leerOffset(q))
          return enviarPDF(buffer, `Remito-${remito.numero}-talonario`)
        }
        const buffer = await generarRemito(remito, await getEmpresa())
        return enviarPDF(buffer, `Remito-${remito.numero}`)
      }
      case 'presupuesto': {
        const presupuesto = await rpcOne('presupuestos_list', { p_id: Number(id) })
        if (!presupuesto) return jsonError('Presupuesto no encontrado', 404)
        const buffer = await generarPresupuesto(presupuesto, await getEmpresa())
        return enviarPDF(buffer, `Presupuesto-${presupuesto.numero}`)
      }
      case 'nota': {
        const nota = await rpcOne('notas_list', { p_id: Number(id) })
        if (!nota) return jsonError('Nota no encontrada', 404)
        const buffer = await generarNota(nota, await getEmpresa())
        const tipo   = nota.tipo === 'NC' ? 'NotaCredito' : 'NotaDebito'
        return enviarPDF(buffer, `${tipo}-${nota.numero}`)
      }
      case 'recibo': {
        const recibo = await rpcOne('recibos_list', { p_id: Number(id) })
        if (!recibo) return jsonError('Recibo no encontrado', 404)
        const buffer = await generarRecibo(recibo, await getEmpresa())
        return enviarPDF(buffer, `Recibo-${recibo.numero}`)
      }

      // ─── INFORMES ──────────────────────────────────────────────────────────
      case 'cta-cte': {
        const desde = q.get('desde') || null
        const hasta = q.get('hasta') || null
        const data  = await rpcOne('informe_cta_cte', {
          p_cliente_id: Number(id), p_desde: desde, p_hasta: hasta,
        })
        if (!data || !data.cliente) return jsonError('Cliente no encontrado', 404)
        const buffer = await generarCtaCte(data, await getEmpresa(), { desde, hasta })
        const nombre = String(data.cliente.razon_social || 'Cliente').replace(/\s+/g, '_')
        return enviarPDF(buffer, `CtaCte-${nombre}`)
      }
      case 'cta-cte-cuenta2': {
        const desde  = q.get('desde') || null
        const hasta  = q.get('hasta') || null
        const sector = q.get('sector')
        if (sector !== 'venta' && sector !== 'compra') return jsonError('Parámetro sector inválido.')
        const data = await rpcOne('informe_cta_cte_cuenta2', {
          p_tipo_sector: sector, p_entidad_id: Number(id), p_desde: desde, p_hasta: hasta,
        })
        if (!data || !data.entidad) return jsonError('Cliente/proveedor no encontrado', 404)
        const buffer = await generarCtaCteCuenta2(data, await getEmpresa(), { desde, hasta })
        const nombre = String(data.entidad.nombre || 'Entidad').replace(/\s+/g, '_')
        return enviarPDF(buffer, `CtaCte-C2-${nombre}`)
      }
      case 'ranking-deudores': {
        const { data, error } = await supabase.rpc('informe_ranking_deudores')
        if (error) throw error
        const buffer = await generarRankingDeudores(data ?? [], await getEmpresa())
        return enviarPDF(buffer, `Ranking-Deudores-${new Date().toISOString().split('T')[0]}`)
      }
      case 'ventas': {
        const desde = q.get('desde')
        const hasta = q.get('hasta')
        if (!desde || !hasta) return jsonError('Parámetros desde y hasta son obligatorios.')
        const cliente_id = q.get('cliente_id')
        const data = await rpcOne('informe_ventas', {
          p_desde: desde, p_hasta: hasta, p_cliente_id: cliente_id ? Number(cliente_id) : null,
        })
        const buffer = await generarResumenVentas(data, await getEmpresa(), desde, hasta)
        return enviarPDF(buffer, `Ventas-${desde}-a-${hasta}`)
      }

      // ─── TESORERÍA (Fase D) — comprobantes internos + informes ──────────────
      // Lecturas directas por PostgREST (como getEmpresa); RLS aplica igual (JWT reenviado).
      case 'movimiento-tesoreria': {
        const { data, error } = await supabase.from('movimientos_tesoreria')
          .select('*, cuenta:cuentas_bancarias(*), tipo:tipos_comprobante_tesoreria(*)')
          .eq('id', Number(id)).single()
        if (error || !data) return jsonError('Movimiento no encontrado', 404)
        const buffer = await generarComprobanteTesoreria(data, await getEmpresa())
        return enviarPDF(buffer, `Movimiento-${data.numero || id}`)
      }
      case 'cheque-propio': {
        const { data, error } = await supabase.from('cheques_propios')
          .select('*, cuenta:cuentas_bancarias(descripcion,banco), proveedor:proveedores(razon_social)')
          .eq('id', Number(id)).single()
        if (error || !data) return jsonError('Cheque propio no encontrado', 404)
        const buffer = await generarCheque(data, await getEmpresa(), 'propio')
        return enviarPDF(buffer, `ChequePropio-${data.numero || id}`)
      }
      case 'cheque': {
        const { data, error } = await supabase.from('cheques')
          .select('*, cliente:clientes(razon_social)')
          .eq('id', Number(id)).single()
        if (error || !data) return jsonError('Cheque no encontrado', 404)
        const buffer = await generarCheque(data, await getEmpresa(), 'tercero')
        return enviarPDF(buffer, `Cheque-${data.numero || id}`)
      }
      case 'subdiario-tesoreria': {
        const desde = q.get('desde') || null
        const hasta = q.get('hasta') || null
        const data  = await rpcOne('informe_subdiario_cuenta', {
          p_cuenta_id: Number(id), p_desde: desde, p_hasta: hasta,
        })
        if (!data || !data.cuenta) return jsonError('Cuenta no encontrada', 404)
        const buffer = await generarSubdiario(data, await getEmpresa(), { desde, hasta })
        const nombre = String(data.cuenta.descripcion || 'Cuenta').replace(/\s+/g, '_')
        return enviarPDF(buffer, `Subdiario-${nombre}`)
      }
      case 'saldos-tesoreria': {
        const data = await rpcOne('informe_saldos_tesoreria', {})
        const buffer = await generarSaldos(data ?? { agrupaciones: [], total_general: 0 }, await getEmpresa())
        return enviarPDF(buffer, `Saldos-Tesoreria-${new Date().toISOString().split('T')[0]}`)
      }
      case 'mayor-tesoreria': {
        const desde = q.get('desde') || null
        const hasta = q.get('hasta') || null
        const data  = await rpcOne('informe_mayor_tesoreria', { p_desde: desde, p_hasta: hasta })
        const buffer = await generarMayorTesoreria(data ?? { cuentas: [], totales: {} }, await getEmpresa(), { desde, hasta })
        return enviarPDF(buffer, `Mayor-Tesoreria-${new Date().toISOString().split('T')[0]}`)
      }

      default:
        return jsonError(`Ruta de PDF desconocida: ${resource ?? '(vacía)'}`, 404)
    }
  } catch (e) {
    const msg = (e as any)?.message ?? 'Error al generar PDF'
    return jsonError(msg, 500)
  }
})
