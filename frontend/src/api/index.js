// src/api/index.js
// Capa de datos sobre supabase-js. Reemplaza al cliente Axios (Express retirado):
//   * Lecturas de lista/informe   -> RPC jsonb (misma forma que devolvía el backend).
//   * Escrituras de comprobantes   -> RPC SECURITY DEFINER (numeración + ítems + estado atómicos).
//   * ABMs simples (clientes/productos/cheques/config) -> PostgREST directo.
// Se mantienen exactamente las MISMAS firmas por recurso, así los src/views/* no cambian.
import { supabase } from '../lib/supabase'
import { unwrap, rpc, one } from './base'

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
  codigo:               d.codigo?.trim().toUpperCase(),
  descripcion:          d.descripcion?.trim(),
  precio_sin_iva:       parseFloat(d.precio_sin_iva) || 0,
  unidades_por_pallet:  Math.max(1, parseInt(d.unidades_por_pallet, 10) || 1),
  ...(d.activo !== undefined ? { activo: d.activo !== false } : {}),
})

// Orden numérico cuando el código es un entero simple (catálogo productos.md: '1'..'25');
// cae a orden alfabético para códigos no numéricos. Number('') y Number(null) dan 0, así que el
// código vacío/nulo se compara como texto en vez de colarse delante del '1'.
const codigoNum = (c) => {
  const s = String(c ?? '').trim()
  return /^\d+$/.test(s) ? Number(s) : NaN
}
const sortByCodigo = (rows) => [...rows].sort((a, b) => {
  const na = codigoNum(a.codigo), nb = codigoNum(b.codigo)
  if (Number.isFinite(na) && Number.isFinite(nb)) return na - nb
  return String(a.codigo ?? '').localeCompare(String(b.codigo ?? ''))
})

// Normalizadores de Compras (equivalentes a cli/prod).
const prov = (d) => ({
  razon_social:                   d.razon_social?.trim(),
  cuit:                           d.cuit?.trim(),
  condicion_iva:                  d.condicion_iva || 'Resp. Inscripto',
  condicion_compra:               d.condicion_compra || 'Cuenta Corriente',
  actividad:                      d.actividad ?? null,
  numero_ingresos_brutos:         d.numero_ingresos_brutos ?? null,
  clasificacion_bienes_servicios: d.clasificacion_bienes_servicios || 'Bienes',
  direccion:                      d.direccion ?? null,
  localidad:                      d.localidad ?? null,
  provincia:                      d.provincia || 'Buenos Aires',
  telefono:                       d.telefono ?? null,
  email:                          d.email ?? null,
  notas:                          d.notas ?? null,
  ...(d.activo !== undefined ? { activo: d.activo !== false } : {}),
})

const mat = (d) => ({
  codigo:            d.codigo?.trim().toUpperCase(),
  descripcion:       d.descripcion?.trim(),
  unidad_medida:     d.unidad_medida?.trim() || 'unidad',
  precio_referencia: parseFloat(d.precio_referencia) || 0,
  ...(d.activo !== undefined ? { activo: d.activo !== false } : {}),
})

// Normalizador de plan de cuentas (Fase E). `nivel` e `imputable` los decide el usuario:
// sólo las cuentas imputables reciben asientos, las de agrupación son títulos del árbol.
const cta = (d) => ({
  codigo:          d.codigo?.trim(),
  descripcion:     d.descripcion?.trim(),
  tipo_cuenta:     d.tipo_cuenta || 'Activo',
  cuenta_padre_id: d.cuenta_padre_id ? Number(d.cuenta_padre_id) : null,
  nivel:           parseInt(d.nivel, 10) || 1,
  imputable:       d.imputable !== false,
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
    let query = supabase.from('productos').select('*')
    if (q) {
      const s = String(q).replace(/[,()]/g, ' ')
      query = query.or(`descripcion.ilike.%${s}%,codigo.ilike.%${s}%`)
    }
    if (activo !== undefined) query = query.eq('activo', activo === true || activo === 'true')
    return query.then(unwrap).then(sortByCodigo)
  },
  get:              (id)      => supabase.from('productos').select('*').eq('id', id).maybeSingle().then(unwrap),
  create:           (data)    => supabase.from('productos').insert(prod(data)).select().single().then(unwrap),
  update:           (id,data) => supabase.from('productos').update(prod(data)).eq('id', id).select().single().then(unwrap),
  actualizarPrecio: (pct)     => rpc('productos_actualizar_precios', { p_porcentaje: pct }),
}

// ── PRESUPUESTOS ─────────────────────────────────────────────────────
export const PresupuestosAPI = {
  // A diferencia de remitos/facturas/notas/recibos, presupuestos_list no tiene filtro server-side
  // por cliente; para la Consulta integral (ConsultaCliente) se filtra en el cliente por cliente_id.
  list: ({ q, estado, cliente_id } = {}) =>
    rpc('presupuestos_list', { p_q: q || null, p_estado: estado || null })
      .then(rows => cliente_id ? rows.filter(r => r.cliente_id === Number(cliente_id)) : rows),
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
  // Fase C: depositar/rechazar impactan el ledger de Tesorería vía RPC (a diferencia de
  // cambiarEstado, que sólo cambia el estado para "entregar" o rechazos sin depósito).
  depositar: (id, cuenta_bancaria_id, fecha) =>
    rpc('depositar_cheque_tercero', { p_cheque_id: id, p_cuenta_bancaria_id: cuenta_bancaria_id, p_fecha: fecha ?? null }),
  rechazar:  (id) => rpc('rechazar_cheque_tercero', { p_cheque_id: id }),
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
  // ── Compras ──
  ctaCteProveedor: (id, { desde, hasta } = {}) =>
    rpc('informe_cta_cte_proveedor', { p_proveedor_id: id, p_desde: desde || null, p_hasta: hasta || null }),
  ivaCompras:        ({ desde, hasta } = {}) => rpc('informe_iva_compras', { p_desde: desde, p_hasta: hasta }),
  preciosCompra:     ({ q } = {})            => rpc('informe_precios_compra', { p_q: q || null }),
  nominaProveedores: ()                      => rpc('informe_nomina_proveedores'),
  // ── Tesorería (Fase C) ──
  saldosTesoreria:         ()                       => rpc('informe_saldos_tesoreria'),
  subdiarioCuenta:         (cuentaId, { desde, hasta } = {}) =>
    rpc('informe_subdiario_cuenta', { p_cuenta_id: cuentaId, p_desde: desde || null, p_hasta: hasta || null }),
  mayorTesoreria:          ({ desde, hasta } = {}) =>
    rpc('informe_mayor_tesoreria', { p_desde: desde || null, p_hasta: hasta || null }),
  movimientosPorOperacion: ({ desde, hasta } = {}) =>
    rpc('informe_movimientos_por_operacion', { p_desde: desde || null, p_hasta: hasta || null }),
  chequesTesoreria:        ({ estado, desde, hasta } = {}) =>
    rpc('informe_cheques_tesoreria', { p_estado: estado || null, p_desde: desde || null, p_hasta: hasta || null }),
  comprobantesTesoreria:   ({ desde, hasta } = {}) =>
    rpc('informe_comprobantes_tesoreria', { p_desde: desde || null, p_hasta: hasta || null }),
  // ── Contabilidad (Fase E) — sólo asientos 'confirmado' ──
  libroDiario:   ({ desde, hasta } = {}) =>
    rpc('informe_libro_diario', { p_desde: desde || null, p_hasta: hasta || null }),
  libroMayor:    (cuentaId, { desde, hasta } = {}) =>
    rpc('informe_libro_mayor', { p_cuenta_id: cuentaId, p_desde: desde || null, p_hasta: hasta || null }),
  sumasYSaldos:  ({ desde, hasta } = {}) =>
    rpc('informe_sumas_y_saldos', { p_desde: desde || null, p_hasta: hasta || null }),
}

// ═════════════════════════════════════════════════════════════════════
// COMPRAS (Fase A) — mismas convenciones rpc()/unwrap/one que arriba.
// ═════════════════════════════════════════════════════════════════════

// ── PROVEEDORES ──────────────────────────────────────────────────────
export const ProveedoresAPI = {
  list: ({ q, activo } = {}) =>
    rpc('proveedores_list', {
      p_q: q || null,
      p_activo: activo === undefined ? null : (activo === true || activo === 'true'),
    }),
  get:       (id)      => supabase.from('proveedores').select('*').eq('id', id).maybeSingle().then(unwrap),
  create:    (data)    => supabase.from('proveedores').insert(prov(data)).select().single().then(unwrap),
  update:    (id,data) => supabase.from('proveedores').update(prov(data)).eq('id', id).select().single().then(unwrap),
  delete:    (id)      => supabase.from('proveedores').update({ activo: false }).eq('id', id).then(unwrap).then(() => ({ ok: true })),
  alicuotas: (provId)  => supabase.from('proveedor_alicuotas').select('*').eq('proveedor_id', provId).order('tipo_retencion').then(unwrap),
}

// ── MATERIALES (ABM simple, como productos) ──────────────────────────
export const MaterialesAPI = {
  list: ({ q, activo } = {}) => {
    let query = supabase.from('materiales').select('*').order('codigo')
    if (q) {
      const s = String(q).replace(/[,()]/g, ' ')
      query = query.or(`descripcion.ilike.%${s}%,codigo.ilike.%${s}%`)
    }
    if (activo !== undefined) query = query.eq('activo', activo === true || activo === 'true')
    return query.then(unwrap)
  },
  get:    (id)      => supabase.from('materiales').select('*').eq('id', id).maybeSingle().then(unwrap),
  create: (data)    => supabase.from('materiales').insert(mat(data)).select().single().then(unwrap),
  update: (id,data) => supabase.from('materiales').update(mat(data)).eq('id', id).select().single().then(unwrap),
}

// ── ALÍCUOTAS IVA (catálogo p/ selects) ──────────────────────────────
export const AlicuotasIvaAPI = {
  list: () => supabase.from('alicuotas_iva').select('*').eq('activo', true).order('porcentaje').then(unwrap),
}

// ── FACTURAS DE COMPRA ───────────────────────────────────────────────
export const FacturasCompraAPI = {
  list: ({ q, estado, proveedor_id, desde, hasta } = {}) => rpc('facturas_compra_list', {
    p_q: q || null, p_estado: estado || null, p_proveedor_id: proveedor_id || null,
    p_desde: desde || null, p_hasta: hasta || null,
  }),
  get:    (id) => rpc('facturas_compra_list', { p_id: id }).then(one),
  create: (data) => rpc('crear_factura_compra', {
    p_proveedor_id:          data.proveedor_id,
    p_punto_venta:           data.punto_venta,
    p_numero_comp:           data.numero_comp,
    p_fecha:                 data.fecha,
    p_items:                 data.items,
    p_tipo:                  data.tipo || 'A',
    p_descuento_general:     data.descuento_general || 0,
    p_fecha_recepcion:       data.fecha_recepcion ?? null,
    p_remito_compra_id:      data.remito_compra_id ?? null,
    p_cae:                   data.cae ?? null,
    p_afip_tipo_comprobante: data.afip_tipo_comprobante ?? null,
    p_observaciones:         data.observaciones ?? null,
  }),
  update: (id, data) => rpc('actualizar_factura_compra', {
    p_id: id,
    p_proveedor_id:          data.proveedor_id,
    p_punto_venta:           data.punto_venta,
    p_numero_comp:           data.numero_comp,
    p_fecha:                 data.fecha,
    p_items:                 data.items,
    p_tipo:                  data.tipo || 'A',
    p_descuento_general:     data.descuento_general || 0,
    p_fecha_recepcion:       data.fecha_recepcion ?? null,
    p_cae:                   data.cae ?? null,
    p_afip_tipo_comprobante: data.afip_tipo_comprobante ?? null,
    p_observaciones:         data.observaciones ?? null,
  }),
  anular: (id) => rpc('factura_compra_anular', { p_id: id }),
}

// ── REMITOS DE COMPRA ────────────────────────────────────────────────
export const RemitosCompraAPI = {
  list: ({ q, estado, proveedor_id } = {}) =>
    rpc('remitos_compra_list', { p_q: q || null, p_estado: estado || null, p_proveedor_id: proveedor_id || null }),
  pendientes: (provId) => rpc('remitos_compra_list', { p_estado: 'pendiente', p_proveedor_id: provId }),
  get:        (id)     => rpc('remitos_compra_list', { p_id: id }).then(one),
  create: (data) => rpc('crear_remito_compra', {
    p_proveedor_id: data.proveedor_id, p_punto_venta: data.punto_venta, p_numero_comp: data.numero_comp,
    p_fecha: data.fecha, p_items: data.items, p_observaciones: data.observaciones ?? null,
  }),
  update: (id, data) => rpc('actualizar_remito_compra', {
    p_id: id, p_proveedor_id: data.proveedor_id, p_punto_venta: data.punto_venta, p_numero_comp: data.numero_comp,
    p_fecha: data.fecha, p_items: data.items, p_observaciones: data.observaciones ?? null,
  }),
  anular: (id) => rpc('remito_compra_anular', { p_id: id }),
}

// ── NOTAS DE COMPRA (NC/ND) ──────────────────────────────────────────
export const NotasCompraAPI = {
  list: ({ q, tipo, proveedor_id } = {}) =>
    rpc('notas_compra_list', { p_q: q || null, p_tipo: tipo || null, p_proveedor_id: proveedor_id || null }),
  get:    (id)   => rpc('notas_compra_list', { p_id: id }).then(one),
  create: (data) => rpc('crear_nota_compra', {
    p_factura_compra_id: data.factura_compra_id, p_tipo: data.tipo,
    p_punto_venta: data.punto_venta, p_numero_comp: data.numero_comp, p_fecha: data.fecha,
    p_items: data.items, p_tipo_letra: data.tipo_letra || 'A',
    p_motivo: data.motivo ?? null, p_observaciones: data.observaciones ?? null,
  }),
}

// ── PAGOS A PROVEEDOR ────────────────────────────────────────────────
export const PagosProveedorAPI = {
  list: ({ q, proveedor_id, desde, hasta } = {}) =>
    rpc('pagos_proveedor_list', { p_q: q || null, p_proveedor_id: proveedor_id || null, p_desde: desde || null, p_hasta: hasta || null }),
  get:    (id)   => rpc('pagos_proveedor_list', { p_id: id }).then(one),
  create: (data) => rpc('crear_pago_proveedor', {
    p_proveedor_id: data.proveedor_id, p_medios: data.medios,
    p_factura_ids: data.factura_ids ?? [], p_fecha: data.fecha ?? null,
    p_retenciones: data.retenciones ?? [], p_observaciones: data.observaciones ?? null,
  }),
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
  // Setter genérico clave/valor (p. ej. tesoreria_caja_default_id, Fase C).
  set: (clave, valor) =>
    supabase.from('config_empresa').upsert({ clave, valor: String(valor ?? '') }, { onConflict: 'clave' })
      .then(unwrap).then(() => ({ ok: true })),
}

// ═════════════════════════════════════════════════════════════════════
// TESORERÍA (Fase C) — mismas convenciones rpc()/unwrap/one.
// El ledger central (movimientos_tesoreria) y transferencias/cheques/conciliación van por
// RPC SECURITY DEFINER; los catálogos (cuentas/agrupaciones/tipos) por PostgREST directo.
// ═════════════════════════════════════════════════════════════════════

// ── CUENTAS (banco / caja / valores) — dimensión "cuenta" del ledger ──
const cuentaTes = (d) => ({
  descripcion:         d.descripcion?.trim(),
  clase:               d.clase || 'banco',
  banco:               d.banco ?? null,
  tipo_cuenta:         d.tipo_cuenta ?? null,
  numero:              d.numero ?? null,
  cbu:                 d.cbu ?? null,
  alias:               d.alias ?? null,
  agrupacion_id:       d.agrupacion_id ? Number(d.agrupacion_id) : null,
  saldo_inicial:       parseFloat(d.saldo_inicial) || 0,
  fecha_saldo_inicial: d.fecha_saldo_inicial || null,
  ...(d.activo !== undefined ? { activo: d.activo !== false } : {}),
})

export const CuentasBancariasAPI = {
  list: ({ activo } = {}) => {
    let q = supabase.from('cuentas_bancarias').select('*').order('id')
    if (activo !== undefined) q = q.eq('activo', activo === true || activo === 'true')
    return q.then(unwrap)
  },
  get:    (id)      => supabase.from('cuentas_bancarias').select('*').eq('id', id).maybeSingle().then(unwrap),
  create: (data)    => supabase.from('cuentas_bancarias').insert(cuentaTes(data)).select().single().then(unwrap),
  update: (id,data) => supabase.from('cuentas_bancarias').update(cuentaTes(data)).eq('id', id).select().single().then(unwrap),
  delete: (id)      => supabase.from('cuentas_bancarias').update({ activo: false }).eq('id', id).then(unwrap).then(() => ({ ok: true })),
  saldos: ()        => rpc('informe_saldos_tesoreria'),
}

// ── AGRUPACIONES ──
export const AgrupacionesTesoreriaAPI = {
  list:   ()        => supabase.from('agrupaciones_tesoreria').select('*').order('orden').then(unwrap),
  create: (data)    => supabase.from('agrupaciones_tesoreria').insert({
    codigo: data.codigo?.trim().toUpperCase(), descripcion: data.descripcion?.trim(), orden: Number(data.orden) || 0,
  }).select().single().then(unwrap),
  update: (id,data) => supabase.from('agrupaciones_tesoreria').update({
    codigo: data.codigo?.trim().toUpperCase(), descripcion: data.descripcion?.trim(), orden: Number(data.orden) || 0,
    ...(data.activo !== undefined ? { activo: data.activo !== false } : {}),
  }).eq('id', id).select().single().then(unwrap),
}

// ── TIPOS DE COMPROBANTE ──
export const TiposComprobanteTesoreriaAPI = {
  list:   ()        => supabase.from('tipos_comprobante_tesoreria').select('*').order('codigo').then(unwrap),
  create: (data)    => supabase.from('tipos_comprobante_tesoreria').insert({
    codigo: data.codigo?.trim().toUpperCase(), descripcion: data.descripcion?.trim(), signo: Number(data.signo) || 0,
  }).select().single().then(unwrap),
  update: (id,data) => supabase.from('tipos_comprobante_tesoreria').update({
    codigo: data.codigo?.trim().toUpperCase(), descripcion: data.descripcion?.trim(), signo: Number(data.signo) || 0,
    ...(data.activo !== undefined ? { activo: data.activo !== false } : {}),
  }).eq('id', id).select().single().then(unwrap),
}

// ── MOVIMIENTOS (ledger central) — incluye transferencia (backend Fase C) ──
export const MovimientosTesoreriaAPI = {
  list: ({ cuenta_id, desde, hasta, tipo_id, q } = {}) =>
    rpc('movimientos_tesoreria_list', {
      p_cuenta_id: cuenta_id || null, p_desde: desde || null, p_hasta: hasta || null,
      p_tipo_id: tipo_id || null, p_q: q || null,
    }),
  create: (data) => rpc('crear_movimiento_tesoreria', {
    p_cuenta_bancaria_id: data.cuenta_bancaria_id, p_tipo_id: data.tipo_id, p_signo: data.signo,
    p_monto: data.monto, p_fecha: data.fecha ?? null, p_concepto: data.concepto ?? null,
  }),
  anular:        (id)   => rpc('anular_movimiento_tesoreria', { p_id: id }),
  transferencia: (data) => rpc('crear_transferencia', {
    p_cuenta_origen_id: data.cuenta_origen_id, p_cuenta_destino_id: data.cuenta_destino_id,
    p_monto: data.monto, p_fecha: data.fecha ?? null, p_concepto: data.concepto ?? null,
  }),
}

// ── CHEQUES PROPIOS (emitidos por nosotros) ──
const flattenCP = ({ cuentas_bancarias, proveedores, ...rest }) => ({
  ...rest,
  cuenta_descripcion:     cuentas_bancarias?.descripcion ?? null,
  proveedor_razon_social: proveedores?.razon_social ?? null,
})

export const ChequesPropiosAPI = {
  list: ({ estado } = {}) => {
    let q = supabase.from('cheques_propios')
      .select('*, cuentas_bancarias(descripcion), proveedores(razon_social)')
      .order('fecha_pago', { ascending: true })
    if (estado) q = q.eq('estado', estado)
    return q.then(unwrap).then(rows => rows.map(flattenCP))
  },
  create: (data) => rpc('crear_cheque_propio', {
    p_cuenta_bancaria_id: data.cuenta_bancaria_id, p_numero: data.numero, p_monto: parseFloat(data.monto),
    p_fecha_pago: data.fecha_pago, p_tipo: data.tipo || 'fisico', p_beneficiario: data.beneficiario ?? null,
    p_proveedor_id: data.proveedor_id ? Number(data.proveedor_id) : null,
    p_fecha_emision: data.fecha_emision ?? null, p_pago_proveedor_id: data.pago_proveedor_id ?? null,
    p_observaciones: data.observaciones ?? null,
  }),
  cambiarEstado: (id, estado) => rpc('actualizar_estado_cheque_propio', { p_id: id, p_nuevo_estado: estado }),
}

// ── CONCILIACIÓN BANCARIA ──
export const ConciliacionAPI = {
  list: (cuentaId) => {
    let q = supabase.from('conciliaciones_bancarias').select('*').order('id', { ascending: false })
    if (cuentaId) q = q.eq('cuenta_bancaria_id', cuentaId)
    return q.then(unwrap)
  },
  abrir:  (data)               => rpc('abrir_conciliacion', {
    p_cuenta_bancaria_id: data.cuenta_bancaria_id, p_desde: data.desde, p_hasta: data.hasta, p_saldo_extracto: data.saldo_extracto,
  }),
  marcar: (id, movimientoIds)  => rpc('marcar_conciliado', { p_conciliacion_id: id, p_movimiento_ids: movimientoIds }),
  cerrar: (id)                 => rpc('cerrar_conciliacion', { p_conciliacion_id: id }),
}

// ═════════════════════════════════════════════════════════════════════
// CONTABILIDAD (Fase E) — plan de cuentas + asientos manuales.
// La generación automática (generar_asiento_desde_*) sigue siendo un stub en la base: hasta que
// se valide la matriz de imputación, el único alta posible es la manual vía crear_asiento.
// ═════════════════════════════════════════════════════════════════════

// ── PLAN DE CUENTAS (ABM simple, como materiales/productos) ──────────
export const PlanCuentasAPI = {
  list: ({ q, imputable, activo } = {}) => {
    let query = supabase.from('plan_de_cuentas').select('*').order('codigo')
    if (q) {
      const s = String(q).replace(/[,()]/g, ' ')
      query = query.or(`descripcion.ilike.%${s}%,codigo.ilike.%${s}%`)
    }
    if (imputable !== undefined) query = query.eq('imputable', imputable === true || imputable === 'true')
    if (activo !== undefined)    query = query.eq('activo', activo === true || activo === 'true')
    return query.then(unwrap)
  },
  get:    (id)      => supabase.from('plan_de_cuentas').select('*').eq('id', id).maybeSingle().then(unwrap),
  create: (data)    => supabase.from('plan_de_cuentas').insert(cta(data)).select().single().then(unwrap),
  update: (id,data) => supabase.from('plan_de_cuentas').update(cta(data)).eq('id', id).select().single().then(unwrap),
}

// ── ASIENTOS CONTABLES ───────────────────────────────────────────────
// El listado sale de informe_libro_diario, que ya devuelve cabecera + líneas + totales
// (sólo asientos 'confirmado'); no hace falta un *_list propio.
export const AsientosAPI = {
  list:   (opts)  => InformesAPI.libroDiario(opts),
  crear:  (data)  => rpc('crear_asiento', {
    p_fecha:           data.fecha,
    p_descripcion:     data.descripcion,
    p_lineas:          data.lineas,
    p_origen:          data.origen || 'manual',
    p_referencia_tipo: data.referencia_tipo || null,
    p_referencia_id:   data.referencia_id || null,
  }),
  anular: (id)    => rpc('anular_asiento', { p_id: id }),
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
  // ── Tesorería (Fase D) — comprobantes internos e informes ──
  movimientoTesoreria: (id)         => `/api/pdf/movimiento-tesoreria/${id}`,
  chequePropio:        (id)         => `/api/pdf/cheque-propio/${id}`,
  cheque:              (id)         => `/api/pdf/cheque/${id}`,
  subdiarioTesoreria:  (cuentaId, desde, hasta) => {
    const p = new URLSearchParams()
    if (desde) p.set('desde', desde)
    if (hasta) p.set('hasta', hasta)
    const qs = p.toString() ? `?${p.toString()}` : ''
    return `/api/pdf/subdiario-tesoreria/${cuentaId}${qs}`
  },
  saldosTesoreria:     ()           => `/api/pdf/saldos-tesoreria`,
  mayorTesoreria:      (desde, hasta) => {
    const p = new URLSearchParams()
    if (desde) p.set('desde', desde)
    if (hasta) p.set('hasta', hasta)
    const qs = p.toString() ? `?${p.toString()}` : ''
    return `/api/pdf/mayor-tesoreria${qs}`
  },
}
