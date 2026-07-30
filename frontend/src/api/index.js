// src/api/index.js
// Capa de datos sobre supabase-js. Reemplaza al cliente Axios (Express retirado):
//   * Lecturas de lista/informe   -> RPC jsonb (misma forma que devolvía el backend).
//   * Escrituras de comprobantes   -> RPC SECURITY DEFINER (numeración + ítems + estado atómicos).
//   * ABMs simples (clientes/productos/cheques/config) -> PostgREST directo.
// Se mantienen exactamente las MISMAS firmas por recurso, así los src/views/* no cambian.
import { supabase } from '../lib/supabase'
import toast from 'react-hot-toast'

// ── Manejo de errores ────────────────────────────────────────────
// Replica el interceptor global del viejo Axios: togglea un toast por error, salvo
// PRESUPUESTO_VENCIDO, que ComprobanteForm detecta por err.response.status === 422.
function fail(error) {
  const raw = error?.message || 'Error de conexión'
  if (raw.includes('PRESUPUESTO_VENCIDO')) {
    const e = new Error('PRESUPUESTO_VENCIDO')
    e.response = { status: 422, data: { error: 'PRESUPUESTO_VENCIDO' } }
    return e // sin toast: lo maneja el formulario
  }
  toast.error(raw)
  return new Error(raw)
}

const unwrap = ({ data, error }) => { if (error) throw fail(error); return data }
const rpc    = (fn, args) => supabase.rpc(fn, args).then(unwrap)
const one    = (rows) => (Array.isArray(rows) ? (rows[0] ?? null) : (rows ?? null))

// Normalizadores (trim / defaults / tipos) equivalentes a los del backend.
const cli = (d) => ({
  razon_social:         d.razon_social?.trim(),
  cuit:                 d.cuit?.trim(),
  condicion_iva:        d.condicion_iva || 'Resp. Inscripto',
  direccion:            d.direccion ?? null,
  localidad:            d.localidad ?? null,
  provincia:            d.provincia || 'Buenos Aires',
  telefono:             d.telefono ?? null,
  email:                d.email ?? null,
  descuento_porcentaje: d.descuento_porcentaje || 0,
  notas:                d.notas ?? null,
  ...(d.activo !== undefined ? { activo: d.activo !== false } : {}),
})

const prod = (d) => ({
  codigo:         d.codigo?.trim().toUpperCase(),
  descripcion:    d.descripcion?.trim(),
  precio_sin_iva: parseFloat(d.precio_sin_iva) || 0,
  ...(d.activo !== undefined ? { activo: d.activo !== false } : {}),
})

// ── CLIENTES ────────────────────────────────────────────────────────
export const ClientesAPI = {
  list: ({ q, activo } = {}) =>
    rpc('clientes_list', {
      p_q: q || null,
      p_activo: activo === undefined ? null : (activo === true || activo === 'true'),
    }),
  get:    (id)      => supabase.from('clientes').select('*').eq('id', id).maybeSingle().then(unwrap),
  create: (data)    => supabase.from('clientes').insert(cli(data)).select().single().then(unwrap),
  update: (id,data) => supabase.from('clientes').update(cli(data)).eq('id', id).select().single().then(unwrap),
  delete: (id)      => supabase.from('clientes').update({ activo: false }).eq('id', id).then(unwrap).then(() => ({ ok: true })),
}

// ── PRODUCTOS ────────────────────────────────────────────────────────
export const ProductosAPI = {
  list: ({ q, activo } = {}) => {
    let query = supabase.from('productos').select('*').order('codigo')
    if (q) {
      const s = String(q).replace(/[,()]/g, ' ')
      query = query.or(`descripcion.ilike.%${s}%,codigo.ilike.%${s}%`)
    }
    if (activo !== undefined) query = query.eq('activo', activo === true || activo === 'true')
    return query.then(unwrap)
  },
  get:              (id)      => supabase.from('productos').select('*').eq('id', id).maybeSingle().then(unwrap),
  create:           (data)    => supabase.from('productos').insert(prod(data)).select().single().then(unwrap),
  update:           (id,data) => supabase.from('productos').update(prod(data)).eq('id', id).select().single().then(unwrap),
  actualizarPrecio: (pct)     => rpc('productos_actualizar_precios', { p_porcentaje: pct }),
}

// ── PRESUPUESTOS ─────────────────────────────────────────────────────
export const PresupuestosAPI = {
  list: ({ q, estado } = {}) => rpc('presupuestos_list', { p_q: q || null, p_estado: estado || null }),
  get:  (id) => rpc('presupuestos_list', { p_id: id }).then(one),
  create: (data) => rpc('crear_presupuesto', {
    p_cliente_id:        data.cliente_id,
    p_items:             data.items,
    p_descuento_general: data.descuento_general || 0,
    p_observaciones:     data.observaciones ?? null,
  }),
  update: (id, data) => rpc('actualizar_presupuesto', {
    p_id:                id,
    p_cliente_id:        data.cliente_id,
    p_items:             data.items,
    p_descuento_general: data.descuento_general || 0,
    p_observaciones:     data.observaciones ?? null,
    p_estado:            data.estado ?? null,
    p_forzar_vencido:    data.forzar_vencido ?? false,
  }),
  cambiarEstado: (id, estado) => rpc('presupuesto_set_estado', { p_id: id, p_estado: estado }),
}

// ── REMITOS ─────────────────────────────────────────────────────────
export const RemitosAPI = {
  list: ({ q, estado, cliente_id } = {}) =>
    rpc('remitos_list', { p_q: q || null, p_estado: estado || null, p_cliente_id: cliente_id || null }),
  pendientes: (cliId) => rpc('remitos_list', { p_estado: 'pendiente', p_cliente_id: cliId }),
  get:        (id)    => rpc('remitos_list', { p_id: id }).then(one),
  create: (data) => rpc('crear_remito', {
    p_cliente_id:     data.cliente_id,
    p_items:          data.items,
    p_observaciones:  data.observaciones ?? null,
    p_presupuesto_id: data.presupuesto_id ?? null,
  }),
  update: (id, data) => rpc('actualizar_remito', {
    p_id: id, p_cliente_id: data.cliente_id, p_items: data.items, p_observaciones: data.observaciones ?? null,
  }),
  anular: (id) => rpc('remito_anular', { p_id: id }),
}

// ── FACTURAS ─────────────────────────────────────────────────────────
export const FacturasAPI = {
  list: ({ q, estado, tipo, cliente_id, desde, hasta } = {}) => rpc('facturas_list', {
    p_q: q || null, p_estado: estado || null, p_tipo: tipo || null,
    p_cliente_id: cliente_id || null, p_desde: desde || null, p_hasta: hasta || null,
  }),
  pendientesRemitir: () => rpc('facturas_list', { p_solo_sin_remito: true }),
  get:               (id) => rpc('facturas_list', { p_id: id }).then(one),
  create: (data) => rpc('crear_factura', {
    p_cliente_id:        data.cliente_id,
    p_items:             data.items,
    p_tipo:              data.tipo || 'A',
    p_descuento_general: data.descuento_general || 0,
    p_remito_id:         data.remito_id ?? null,
    p_presupuesto_id:    data.presupuesto_id ?? null,
    p_observaciones:     data.observaciones ?? null,
  }),
  update: (id, data) => rpc('actualizar_factura', {
    p_id: id, p_cliente_id: data.cliente_id, p_items: data.items,
    p_descuento_general: data.descuento_general || 0, p_observaciones: data.observaciones ?? null,
  }),
  anular: (id) => rpc('factura_anular', { p_id: id }),
}

// ── NOTAS ────────────────────────────────────────────────────────────
export const NotasAPI = {
  list: ({ q, tipo, cliente_id } = {}) =>
    rpc('notas_list', { p_q: q || null, p_tipo: tipo || null, p_cliente_id: cliente_id || null }),
  get:    (id)   => rpc('notas_list', { p_id: id }).then(one),
  create: (data) => rpc('crear_nota', {
    p_factura_id: data.factura_id, p_tipo: data.tipo, p_items: data.items,
    p_motivo: data.motivo ?? null, p_observaciones: data.observaciones ?? null,
  }),
}

// ── RECIBOS ──────────────────────────────────────────────────────────
export const RecibosAPI = {
  list: ({ q, cliente_id, desde, hasta } = {}) =>
    rpc('recibos_list', { p_q: q || null, p_cliente_id: cliente_id || null, p_desde: desde || null, p_hasta: hasta || null }),
  get:    (id)   => rpc('recibos_list', { p_id: id }).then(one),
  create: (data) => rpc('crear_recibo', {
    p_cliente_id: data.cliente_id, p_medios: data.medios,
    p_factura_ids: data.factura_ids ?? [], p_observaciones: data.observaciones ?? null,
  }),
}

// ── CHEQUES ──────────────────────────────────────────────────────────
const flattenCheque = ({ clientes, ...rest }) => ({ ...rest, cliente_razon_social: clientes?.razon_social ?? null })

export const ChequesAPI = {
  list: ({ estado, vencen_pronto } = {}) => {
    let query = supabase.from('cheques')
      .select('*, clientes(razon_social)')
      .order('fecha_vcto', { ascending: true })
      .order('estado', { ascending: true })
    if (estado) query = query.eq('estado', estado)
    if (vencen_pronto === 'true' || vencen_pronto === true) {
      const hoy = new Date(); const en7 = new Date(); en7.setDate(en7.getDate() + 7)
      query = query.eq('estado', 'en_cartera')
        .gte('fecha_vcto', hoy.toISOString().split('T')[0])
        .lte('fecha_vcto', en7.toISOString().split('T')[0])
    }
    return query.then(unwrap).then((rows) => rows.map(flattenCheque))
  },
  create: (data) => supabase.from('cheques').insert({
    numero:        data.numero,
    tipo:          data.tipo || 'fisico',
    banco:         data.banco,
    titular:       data.titular ?? null,
    cuit_titular:  data.cuit_titular ?? null,
    fecha_emision: data.fecha_emision || null,
    fecha_vcto:    data.fecha_vcto,
    monto:         parseFloat(data.monto),
    cliente_id:    data.cliente_id ?? null,
    observaciones: data.observaciones ?? null,
    estado:        'en_cartera',
  }).select().single().then(unwrap),
  cambiarEstado: (id, estado, proveedor_destino) => {
    const patch = { estado }
    if (proveedor_destino) patch.proveedor_destino = proveedor_destino
    return supabase.from('cheques').update(patch).eq('id', id).select().single().then(unwrap)
  },
}

// ── INFORMES ─────────────────────────────────────────────────────────
export const InformesAPI = {
  dashboard:             ()        => rpc('informe_dashboard'),
  ventas:          ({ desde, hasta, cliente_id } = {}) =>
    rpc('informe_ventas', { p_desde: desde, p_hasta: hasta, p_cliente_id: cliente_id || null }),
  rankingClientes: ({ desde, hasta } = {}) =>
    rpc('informe_ranking_clientes', { p_desde: desde || null, p_hasta: hasta || null }),
  rankingDeudores:       ()        => rpc('informe_ranking_deudores'),
  remPendientesFacturar: ()        => rpc('informe_remitos_pendientes_facturar'),
  facPendientesRemitir:  ()        => rpc('informe_facturas_pendientes_remitir'),
  ctaCte:          (id, { desde, hasta } = {}) =>
    rpc('informe_cta_cte', { p_cliente_id: id, p_desde: desde || null, p_hasta: hasta || null }),
}

// ── CONFIG ───────────────────────────────────────────────────────────
export const ConfigAPI = {
  empresa: () => supabase.from('config_empresa').select('clave,valor').then(unwrap)
    .then((rows) => rows.reduce((acc, r) => ({ ...acc, [r.clave]: r.valor }), {})),
  updateEmpresa: (data) => {
    const campos = ['razon_social','cuit','direccion','condicion_iva','ingresos_brutos','inicio_actividades']
    const rows = Object.entries(data)
      .filter(([k]) => campos.includes(k))
      .map(([clave, valor]) => ({ clave, valor: String(valor) }))
    if (!rows.length) return Promise.resolve({ ok: true })
    return supabase.from('config_empresa').upsert(rows, { onConflict: 'clave' }).then(unwrap).then(() => ({ ok: true }))
  },
  cuentasBancarias: () => supabase.from('cuentas_bancarias').select('*').eq('activo', true).order('id').then(unwrap),
  contadores:       () => supabase.from('contadores').select('*').order('tipo').then(unwrap),
}

// ── PDF URLS (se usan con PDFModal) ──────────────────────────────────
// Fase 6 hecha: los PDF los genera la Edge Function `pdf` (supabase/functions/pdf). Estas rutas
// estilo Express ("/api/pdf/...") las remapea PDFModal a {SUPABASE_URL}/functions/v1/pdf/<path>
// con el JWT de la sesión; no pegan más contra Express.
export const pdfUrl = {
  factura:         (id)                       => `/api/pdf/factura/${id}`,
  remito:          (id)                       => `/api/pdf/remito/${id}`,
  presupuesto:     (id)                       => `/api/pdf/presupuesto/${id}`,
  nota:            (id)                       => `/api/pdf/nota/${id}`,
  recibo:          (id)                       => `/api/pdf/recibo/${id}`,
  ctaCte:          (clienteId, desde, hasta)  => {
    const p = new URLSearchParams()
    if (desde) p.set('desde', desde)
    if (hasta) p.set('hasta', hasta)
    const qs = p.toString() ? `?${p.toString()}` : ''
    return `/api/pdf/cta-cte/${clienteId}${qs}`
  },
  rankingDeudores: ()                         => `/api/pdf/ranking-deudores`,
  ventas:          (desde, hasta, cliId)      => {
    const p = new URLSearchParams({ desde, hasta })
    if (cliId) p.set('cliente_id', cliId)
    return `/api/pdf/ventas?${p.toString()}`
  },
}
