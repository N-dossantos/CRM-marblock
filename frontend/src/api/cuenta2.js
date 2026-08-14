// src/api/cuenta2.js
// Capa de datos del circuito informal "Cuenta 2" (cuenta2.md). Mismo criterio que index.js:
//   * Listas/informes  -> RPC jsonb.
//   * Remitos X y movimientos de cta. cte. -> RPC SECURITY DEFINER (cabecera + ítems atómicos,
//     totales recalculados server-side).
//   * ABM de entidades y cartera de cheques -> PostgREST directo (no hay transacción que proteger).
// Vive aparte de index.js para que el aislamiento del módulo también se vea en el código.
import { supabase } from '../lib/supabase'
import { unwrap, rpc, one } from './base'

// Normalizador de entidades C2: clientes y proveedores tienen la misma forma simplificada.
const ent = (d) => ({
  nombre:               d.nombre?.trim(),
  descuento_porcentaje: parseFloat(d.descuento_porcentaje) || 0,
  telefono:             d.telefono?.trim() || null,
  notas:                d.notas ?? null,
  ...(d.activo !== undefined ? { activo: d.activo !== false } : {}),
})

// Fábrica del ABM de entidades: clientes y proveedores C2 sólo difieren en la tabla y la RPC.
const entidadAPI = (tabla, listRpc) => ({
  list: ({ q, activo } = {}) =>
    rpc(listRpc, {
      p_q: q || null,
      p_activo: activo === undefined ? null : (activo === true || activo === 'true'),
    }),
  get:    (id)       => supabase.from(tabla).select('*').eq('id', id).maybeSingle().then(unwrap),
  create: (data)     => supabase.from(tabla).insert(ent(data)).select().single().then(unwrap),
  update: (id, data) => supabase.from(tabla).update(ent(data)).eq('id', id).select().single().then(unwrap),
  // Baja lógica: las FK del ledger son RESTRICT, un borrado real fallaría con movimientos.
  delete: (id)       => supabase.from(tabla).update({ activo: false }).eq('id', id).then(unwrap).then(() => ({ ok: true })),
})

// ── ENTIDADES ────────────────────────────────────────────────────────
export const ClientesC2API    = entidadAPI('clientes_cuenta2',    'clientes_cuenta2_list')
export const ProveedoresC2API = entidadAPI('proveedores_cuenta2', 'proveedores_cuenta2_list')

// ── REMITOS X ────────────────────────────────────────────────────────
// Un solo comprobante para venta y compra; el número lo tipea el usuario.
export const RemitosC2API = {
  list: ({ tipo_sector, q, entidad_id, desde, hasta } = {}) =>
    rpc('remitos_cuenta2_list', {
      p_tipo_sector: tipo_sector || null,
      p_q:           q || null,
      p_entidad_id:  entidad_id || null,
      p_desde:       desde || null,
      p_hasta:       hasta || null,
    }),
  get: (id) => rpc('remitos_cuenta2_list', { p_id: id }).then(one),
  create: (data) => rpc('crear_remito_cuenta2', {
    p_tipo_sector:       data.tipo_sector,
    p_entidad_id:        data.entidad_id,
    p_numero:            data.numero,
    p_items:             data.items,
    p_fecha:             data.fecha || null,
    p_descuento_general: data.descuento_general || 0,
    p_observaciones:     data.observaciones ?? null,
  }),
  update: (id, data) => rpc('actualizar_remito_cuenta2', {
    p_id:                id,
    p_entidad_id:        data.entidad_id,
    p_numero:            data.numero,
    p_items:             data.items,
    p_fecha:             data.fecha || null,
    p_descuento_general: data.descuento_general || 0,
    p_observaciones:     data.observaciones ?? null,
  }),
  delete: (id) => rpc('eliminar_remito_cuenta2', { p_id: id }),
}

// ── MOVIMIENTOS DE CTA. CTE. (cobros / pagos / ajustes) ──────────────
// No hay recibo ni orden de pago: el movimiento impacta el saldo directo.
export const MovimientosC2API = {
  list: ({ tipo_sector, entidad_id, desde, hasta } = {}) =>
    rpc('movimientos_cuenta2_list', {
      p_tipo_sector: tipo_sector || null,
      p_entidad_id:  entidad_id || null,
      p_desde:       desde || null,
      p_hasta:       hasta || null,
    }),
  // cheque: { numero, tipo, banco, titular, cuit_titular, fecha_emision, fecha_vcto, monto }
  //         para dar de alta uno nuevo en la cartera C2.
  // cheque_id: para ENDOSAR uno que ya está en cartera (sólo en pagos a proveedor).
  create: (data) => rpc('registrar_movimiento_cuenta2', {
    p_tipo_sector: data.tipo_sector,
    p_entidad_id:  data.entidad_id,
    p_tipo:        data.tipo,
    p_monto:       parseFloat(data.monto) || 0,
    p_fecha:       data.fecha || null,
    p_medio:       data.medio ?? null,
    p_concepto:    data.concepto ?? null,
    p_cheque:      data.cheque ?? null,
    p_cheque_id:   data.cheque_id ?? null,
  }),
  delete: (id) => rpc('eliminar_movimiento_cuenta2', { p_id: id }),
}

// ── CARTERA DE CHEQUES CUENTA 2 ──────────────────────────────────────
// Aplana los embeds igual que ChequesAPI.list de Cuenta 1, para que las vistas sean tontas.
const flattenChequeC2 = ({ clientes_cuenta2, proveedores_cuenta2, ...rest }) => ({
  ...rest,
  cliente_nombre:   clientes_cuenta2?.nombre ?? null,
  proveedor_nombre: proveedores_cuenta2?.nombre ?? null,
})

export const ChequesC2API = {
  list: ({ estado } = {}) => {
    let query = supabase.from('cuenta2_cheques')
      .select('*, clientes_cuenta2(nombre), proveedores_cuenta2(nombre)')
      .order('fecha_vcto', { ascending: true })
      .order('estado', { ascending: true })
    if (estado) query = query.eq('estado', estado)
    return query.then(unwrap).then((rows) => rows.map(flattenChequeC2))
  },
  update: (id, data) => supabase.from('cuenta2_cheques').update({
    numero:        data.numero,
    tipo:          data.tipo || 'fisico',
    banco:         data.banco,
    titular:       data.titular ?? null,
    cuit_titular:  data.cuit_titular ?? null,
    fecha_emision: data.fecha_emision || null,
    fecha_vcto:    data.fecha_vcto,
    monto:         parseFloat(data.monto),
    observaciones: data.observaciones ?? null,
  }).eq('id', id).select().single().then(unwrap),
  // El único puente hacia Cuenta 1: crea la fila en `cheques` y marca ésta 'transferido_c1'.
  transferir: (id, datos) =>
    rpc('transferir_cheque_cuenta2_a_cuenta1', { p_id: id, p_datos: datos ?? null }),
  anular: (id) => rpc('anular_cheque_cuenta2', { p_id: id }),
}

// ── INFORMES ─────────────────────────────────────────────────────────
export const InformesC2API = {
  // Devuelve { entidad, movimientos: [{fecha, comprobante, tipo, debe, haber, saldo}], saldo_total }
  ctaCte: (tipo_sector, entidad_id, { desde, hasta } = {}) =>
    rpc('informe_cta_cte_cuenta2', {
      p_tipo_sector: tipo_sector,
      p_entidad_id:  entidad_id,
      p_desde:       desde || null,
      p_hasta:       hasta || null,
    }),
}
