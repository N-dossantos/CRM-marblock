// src/views/Cuenta2/index.jsx
// Sección Cuenta 2 — circuito informal aislado del oficial (cuenta2.md).
// Una sola vista sirve Ventas y Compras vía `tipoSector`: el circuito es idéntico y sólo
// cambian la entidad (cliente/proveedor) y los textos, así que clonarla sería duplicar 400
// líneas. Misma idea que ComprobanteForm sirviendo presupuesto/remito/factura con `tipo`.
// Sub-tabs con useState (patrón de views/TesoreriaCuentas), no ruteo anidado.
import { useState, useEffect, useCallback } from 'react'
import { ClientesC2API, ProveedoresC2API, RemitosC2API, MovimientosC2API, InformesC2API } from '../../api/cuenta2'
import { ProductosAPI } from '../../api'
import { $ar, fFecha } from '../../utils'
import { Modal, Loading, EmptyState, ItemsTable } from '../../components/UI'
import RemitoXForm from '../../components/Forms/RemitoXForm'
import MovimientoC2Form from '../../components/Forms/MovimientoC2Form'
import EntidadC2Form from '../../components/Forms/EntidadC2Form'
import toast from 'react-hot-toast'

const TIPO_STYLE = {
  'REMITO X': { bg: '#fef3c7', color: '#92400e', label: 'Remito X' },
  COBRO:      { bg: '#d1fae5', color: '#065f46', label: 'Cobro' },
  PAGO:       { bg: '#d1fae5', color: '#065f46', label: 'Pago' },
  AJUSTE:     { bg: '#e0e7ff', color: '#3730a3', label: 'Ajuste' },
}

export default function Cuenta2({ tipoSector }) {
  const esVenta = tipoSector === 'venta'
  const [sub, setSub] = useState('remitos')

  const SUBTABS = [
    { id: 'remitos',   label: '📄 Remitos X' },
    { id: 'entidades', label: esVenta ? '👥 Clientes' : '🏭 Proveedores' },
    { id: 'ctacte',    label: '📒 Cuenta corriente' },
  ]

  return (
    <div>
      <div className="info-box" style={{ marginBottom: 16 }}>
        <span>
          <strong>Circuito Cuenta 2</strong> — sin impuestos, sin numeración fiscal y aislado de
          Cuenta 1: estos clientes, saldos y cheques no aparecen en el circuito oficial.
        </span>
      </div>

      <div style={{ display: 'flex', gap: 0, marginBottom: 20, borderBottom: '2px solid var(--gray-200)' }}>
        {SUBTABS.map(t => (
          <button key={t.id} onClick={() => setSub(t.id)} style={tabStyle(sub === t.id)}>{t.label}</button>
        ))}
      </div>

      {sub === 'remitos'   && <RemitosX  tipoSector={tipoSector} />}
      {sub === 'entidades' && <Entidades tipoSector={tipoSector} />}
      {sub === 'ctacte'    && <CtaCteC2  tipoSector={tipoSector} />}
    </div>
  )
}

function tabStyle(active) {
  return {
    padding: '10px 18px', background: 'transparent', border: 'none',
    borderBottom: active ? '2px solid var(--blue-600)' : '2px solid transparent', marginBottom: -2,
    color: active ? 'var(--blue-600)' : 'var(--gray-500)', fontWeight: active ? 700 : 400,
    fontSize: 13, cursor: 'pointer', fontFamily: 'inherit', whiteSpace: 'nowrap',
  }
}

// La entidad del sector: clientes en ventas, proveedores en compras.
const entidadAPIde = (tipoSector) => (tipoSector === 'venta' ? ClientesC2API : ProveedoresC2API)

// ══════════════════════ REMITOS X ══════════════════════
function RemitosX({ tipoSector }) {
  const esVenta = tipoSector === 'venta'
  const [rows, setRows]           = useState([])
  const [entidades, setEntidades] = useState([])
  const [productos, setProductos] = useState([])
  const [loading, setLoading]     = useState(true)
  const [search, setSearch]       = useState('')
  const [form, setForm]           = useState(null)
  const [detalle, setDetalle]     = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    RemitosC2API.list({ tipo_sector: tipoSector, q: search })
      .then(setRows).finally(() => setLoading(false))
  }, [tipoSector, search])

  useEffect(() => { load() }, [load])
  useEffect(() => {
    entidadAPIde(tipoSector).list({ activo: true }).then(setEntidades)
    ProductosAPI.list({ activo: true }).then(setProductos)
  }, [tipoSector])

  const save = async (payload) => {
    if (form.isNew) await RemitosC2API.create(payload)
    else            await RemitosC2API.update(form.data.id, payload)
    toast.success('Remito X guardado')
    setForm(null); load()
  }

  const eliminar = async (r) => {
    if (!confirm(`¿Eliminar el Remito X ${r.numero}? Se descuenta de la cuenta corriente.`)) return
    try {
      await RemitosC2API.delete(r.id)
      toast.success('Remito X eliminado')
      load()
    } catch { /* el toast ya lo emitió la capa API */ }
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input
            className="search-inp"
            placeholder={`Buscar remito o ${esVenta ? 'cliente' : 'proveedor'}…`}
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <button className="btn btn-primary" onClick={() => setForm({ data: {}, isNew: true })}>
          + Nuevo Remito X
        </button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th>
                <th>Fecha</th>
                <th>{esVenta ? 'Cliente' : 'Proveedor'}</th>
                <th className="th-right">Dto. %</th>
                <th className="th-right">Total ($)</th>
                <th style={{ width: 200 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="📄" message="Sin remitos X" /> : rows.map(r => (
                <tr key={r.id}>
                  <td><span className="code">{r.numero}</span></td>
                  <td>{fFecha(r.fecha)}</td>
                  <td>{r.entidad_nombre}</td>
                  <td className="td-right">{+r.descuento_porcentaje > 0 ? `${r.descuento_porcentaje}%` : '—'}</td>
                  <td className="td-right td-bold">{$ar(r.total)}</td>
                  <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                    <button className="btn btn-secondary btn-xs" onClick={() => setDetalle(r)}>Ver</button>
                    {' '}
                    <button className="btn btn-secondary btn-xs" onClick={() => setForm({ data: r, isNew: false })}>
                      Editar
                    </button>
                    {' '}
                    <button className="btn btn-danger btn-xs" onClick={() => eliminar(r)}>Eliminar</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {form && (
        <RemitoXForm
          title={form.isNew ? 'Nuevo Remito X' : `Remito X ${form.data?.numero || ''}`}
          tipoSector={tipoSector}
          initial={form.data || {}}
          entidades={entidades}
          productos={productos}
          onSave={save}
          onClose={() => setForm(null)}
        />
      )}

      {detalle && (
        <Modal title={`Remito X ${detalle.numero}`} size="lg" onClose={() => setDetalle(null)}>
          <div className="info-box" style={{ marginBottom: 14 }}>
            <span>
              {detalle.entidad_nombre} · {fFecha(detalle.fecha)}
              {+detalle.descuento_porcentaje > 0 && ` · Descuento ${detalle.descuento_porcentaje}%`}
            </span>
          </div>
          <ItemsTable items={detalle.items || []} readonly />
          <div className="totales-box">
            <div className="totales-row"><span>Subtotal</span><span>{$ar(detalle.subtotal)}</span></div>
            {+detalle.descuento_monto > 0 && (
              <div className="totales-row">
                <span>Descuento</span>
                <span style={{ color: 'var(--red-500)' }}>— {$ar(detalle.descuento_monto)}</span>
              </div>
            )}
            <hr className="totales-divider" />
            <div className="totales-row total"><span>TOTAL</span><span className="val">{$ar(detalle.total)}</span></div>
          </div>
          {detalle.observaciones && (
            <p style={{ marginTop: 12, fontSize: 13, color: 'var(--gray-600)' }}>{detalle.observaciones}</p>
          )}
        </Modal>
      )}
    </div>
  )
}

// ══════════════════════ ENTIDADES (ABM) ══════════════════════
function Entidades({ tipoSector }) {
  const esVenta = tipoSector === 'venta'
  const API = entidadAPIde(tipoSector)
  const [rows, setRows]       = useState([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch]   = useState('')
  const [form, setForm]       = useState(null)

  const load = useCallback(() => {
    setLoading(true)
    API.list({ q: search }).then(setRows).finally(() => setLoading(false))
  }, [API, search])

  useEffect(() => { load() }, [load])

  const save = async (data) => {
    if (form.isNew) await API.create(data)
    else            await API.update(form.data.id, data)
    toast.success(esVenta ? 'Cliente guardado' : 'Proveedor guardado')
    setForm(null); load()
  }

  const baja = async (e) => {
    if (!confirm(`¿Dar de baja a ${e.nombre}?`)) return
    await API.delete(e.id)
    toast.success('Dado de baja')
    load()
  }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input
            className="search-inp"
            placeholder={`Buscar ${esVenta ? 'cliente' : 'proveedor'}…`}
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <button className="btn btn-primary" onClick={() => setForm({ data: {}, isNew: true })}>
          + Nuevo {esVenta ? 'cliente' : 'proveedor'}
        </button>
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Nombre</th>
                <th>Teléfono</th>
                <th className="th-right">Dto. %</th>
                <th className="th-right">Saldo ($)</th>
                <th>Estado</th>
                <th style={{ width: 150 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 ? <EmptyState icon="👥" message="Sin registros" /> : rows.map(e => (
                <tr key={e.id} style={{ opacity: e.activo === false ? 0.5 : 1 }}>
                  <td className="td-bold">{e.nombre}</td>
                  <td>{e.telefono || '—'}</td>
                  <td className="td-right">{+e.descuento_porcentaje > 0 ? `${e.descuento_porcentaje}%` : '—'}</td>
                  <td className="td-right td-bold" style={{ color: +e.saldo > 0 ? 'var(--red-500)' : +e.saldo < 0 ? '#10b981' : 'var(--gray-400)' }}>
                    {$ar(e.saldo)}
                  </td>
                  <td>{e.activo === false ? <span className="badge badge-anulada">Baja</span> : <span className="badge badge-aceptado">Activo</span>}</td>
                  <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                    <button className="btn btn-secondary btn-xs" onClick={() => setForm({ data: e, isNew: false })}>Editar</button>
                    {e.activo !== false && (
                      <> <button className="btn btn-danger btn-xs" onClick={() => baja(e)}>Baja</button></>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {form && (
        <EntidadC2Form
          tipoSector={tipoSector}
          initial={form.data || {}}
          onSave={save}
          onClose={() => setForm(null)}
        />
      )}
    </div>
  )
}

// ══════════════════════ CUENTA CORRIENTE ══════════════════════
// Espeja views/CtaCte (master/detail 270px + tabla debe/haber/saldo), con dos diferencias:
// el alto se ajusta porque va dentro de una tab, y suma el registro de cobros/pagos.
function CtaCteC2({ tipoSector }) {
  const esVenta = tipoSector === 'venta'
  const [entidades, setEntidades] = useState([])
  const [selId, setSelId]         = useState('')
  const [data, setData]           = useState(null)
  const [loading, setLoading]     = useState(false)
  const [search, setSearch]       = useState('')
  const [desde, setDesde]         = useState('')
  const [hasta, setHasta]         = useState('')
  const [movForm, setMovForm]     = useState(null)

  const loadEntidades = useCallback(() => {
    entidadAPIde(tipoSector).list().then(setEntidades)
  }, [tipoSector])

  useEffect(() => { loadEntidades() }, [loadEntidades])

  const cargar = useCallback(() => {
    if (!selId) return
    setLoading(true)
    const params = {}
    if (desde) params.desde = desde
    if (hasta) params.hasta = hasta
    InformesC2API.ctaCte(tipoSector, selId, params).then(setData).finally(() => setLoading(false))
  }, [tipoSector, selId, desde, hasta])

  useEffect(() => { if (selId) cargar() }, [selId, tipoSector])

  const guardarMov = async (payload) => {
    await MovimientosC2API.create(payload)
    toast.success(esVenta ? 'Cobro registrado' : 'Pago registrado')
    setMovForm(null); cargar(); loadEntidades()
  }

  const eliminarMov = async (m) => {
    if (!confirm('¿Eliminar el movimiento? Se recalcula el saldo.')) return
    try {
      await MovimientosC2API.delete(m.id)
      toast.success('Movimiento eliminado')
      cargar(); loadEntidades()
    } catch { /* el toast ya lo emitió la capa API */ }
  }

  const filtradas = entidades.filter(e =>
    !search || e.nombre.toLowerCase().includes(search.toLowerCase()) || (e.telefono || '').includes(search)
  )
  const saldo = data?.saldo_total ?? 0

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '270px 1fr', gap: 18, height: 'calc(100vh - 54px - 48px - 130px)', overflow: 'hidden' }}>
      {/* Panel izquierdo: entidades */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 0, overflow: 'hidden' }}>
        <div className="card" style={{ padding: '14px', marginBottom: 0, borderBottom: 'none', borderBottomLeftRadius: 0, borderBottomRightRadius: 0 }}>
          <input
            className="search-inp"
            style={{ width: '100%' }}
            placeholder={`Buscar ${esVenta ? 'cliente' : 'proveedor'}…`}
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <div style={{ flex: 1, overflowY: 'auto', background: '#fff', border: '1px solid var(--gray-200)', borderTopLeftRadius: 0, borderTopRightRadius: 0, borderRadius: '0 0 12px 12px' }}>
          {filtradas.map(e => (
            <div
              key={e.id}
              onClick={() => setSelId(e.id)}
              style={{
                padding: '10px 14px',
                cursor: 'pointer',
                borderBottom: '1px solid var(--gray-100)',
                background: selId === e.id ? 'var(--blue-50)' : 'transparent',
                borderLeft: selId === e.id ? '3px solid var(--blue-600)' : '3px solid transparent',
                transition: 'background .12s',
              }}
            >
              <div style={{ fontWeight: selId === e.id ? 700 : 500, fontSize: 13, color: 'var(--gray-800)' }}>
                {e.nombre.length > 28 ? e.nombre.slice(0, 28) + '…' : e.nombre}
              </div>
              <div style={{ fontSize: 12, fontWeight: 700, color: +e.saldo > 0 ? 'var(--red-500)' : +e.saldo < 0 ? '#10b981' : 'var(--gray-400)', marginTop: 2 }}>
                {$ar(e.saldo)} {+e.saldo > 0 ? (esVenta ? '▲ Debe' : '▲ Le debemos') : +e.saldo < 0 ? '▼ A favor' : '✓ Sin saldo'}
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Panel derecho: movimientos */}
      <div style={{ overflowY: 'auto' }}>
        {!selId ? (
          <div className="card" style={{ textAlign: 'center', padding: '60px 20px' }}>
            <div style={{ fontSize: 40, marginBottom: 12 }}>📒</div>
            <p style={{ color: 'var(--gray-400)', fontSize: 14 }}>
              Seleccione un {esVenta ? 'cliente' : 'proveedor'} para ver su cuenta corriente
            </p>
          </div>
        ) : loading ? (
          <Loading />
        ) : data ? (
          <div>
            <div className="card" style={{ marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <h2 style={{ fontSize: 17, fontWeight: 700, color: 'var(--gray-800)' }}>{data.entidad.nombre}</h2>
                  <div style={{ fontSize: 13, color: 'var(--gray-500)', marginTop: 4 }}>
                    {data.entidad.telefono || 'Sin teléfono'}
                    {+data.entidad.descuento_porcentaje > 0 && ` · Descuento ${data.entidad.descuento_porcentaje}%`}
                  </div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px', marginBottom: 4 }}>Saldo actual</div>
                  <div style={{ fontSize: 28, fontWeight: 800, color: saldo > 0 ? 'var(--red-500)' : saldo < 0 ? '#10b981' : 'var(--gray-400)', lineHeight: 1 }}>
                    {$ar(saldo)}
                  </div>
                  <div style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 4 }}>
                    {saldo > 0 ? (esVenta ? '⬆ Saldo deudor' : '⬆ Le debemos') : saldo < 0 ? '⬇ Saldo a favor' : '✓ Cuenta balanceada'}
                  </div>
                  <button
                    className="btn btn-primary btn-sm"
                    style={{ marginTop: 10 }}
                    onClick={() => setMovForm({ entidad: data.entidad, saldo })}
                  >
                    + Registrar {esVenta ? 'cobro' : 'pago'}
                  </button>
                </div>
              </div>

              <div style={{ display: 'flex', gap: 10, marginTop: 14, paddingTop: 14, borderTop: '1px solid var(--gray-100)', alignItems: 'center' }}>
                <span style={{ fontSize: 12, color: 'var(--gray-500)', fontWeight: 600 }}>Filtrar por período:</span>
                <input type="date" className="inp" style={{ width: 150 }} value={desde} onChange={e => setDesde(e.target.value)} />
                <span style={{ color: 'var(--gray-400)' }}>al</span>
                <input type="date" className="inp" style={{ width: 150 }} value={hasta} onChange={e => setHasta(e.target.value)} />
                <button className="btn btn-secondary btn-sm" onClick={cargar}>Aplicar</button>
                <button className="btn btn-ghost btn-sm" onClick={() => { setDesde(''); setHasta(''); setTimeout(cargar, 0) }}>Limpiar</button>
              </div>
            </div>

            <div className="tbl-wrap">
              <table>
                <thead>
                  <tr>
                    <th>Fecha</th>
                    <th>Comprobante / Concepto</th>
                    <th>Tipo</th>
                    <th className="th-right">Debe ($)</th>
                    <th className="th-right">Haber ($)</th>
                    <th className="th-right">Saldo ($)</th>
                    <th style={{ width: 90 }}></th>
                  </tr>
                </thead>
                <tbody>
                  {data.movimientos.length === 0 ? (
                    <tr><td colSpan={7} style={{ textAlign: 'center', padding: '40px', color: 'var(--gray-400)' }}>Sin movimientos en el período</td></tr>
                  ) : data.movimientos.map((m, i) => {
                    const ts = TIPO_STYLE[m.tipo] || { bg: 'var(--gray-100)', color: 'var(--gray-600)', label: m.tipo }
                    const esRemito = m.tipo === 'REMITO X'
                    return (
                      <tr key={`${m.tipo}-${m.id}-${i}`}>
                        <td>{fFecha(m.fecha)}</td>
                        <td><span className="code">{m.comprobante}</span></td>
                        <td>
                          <span style={{ background: ts.bg, color: ts.color, padding: '2px 9px', borderRadius: 10, fontSize: 11, fontWeight: 700 }}>
                            {ts.label}
                          </span>
                        </td>
                        <td className="td-right" style={{ color: parseFloat(m.debe) > 0 ? 'var(--red-500)' : 'var(--gray-300)', fontWeight: parseFloat(m.debe) > 0 ? 600 : 400 }}>
                          {parseFloat(m.debe) > 0 ? $ar(m.debe) : '—'}
                        </td>
                        <td className="td-right" style={{ color: parseFloat(m.haber) > 0 ? '#10b981' : 'var(--gray-300)', fontWeight: parseFloat(m.haber) > 0 ? 600 : 400 }}>
                          {parseFloat(m.haber) > 0 ? $ar(m.haber) : '—'}
                        </td>
                        <td className="td-right" style={{ fontWeight: 700, color: parseFloat(m.saldo) > 0 ? 'var(--red-500)' : parseFloat(m.saldo) < 0 ? '#10b981' : 'var(--gray-600)' }}>
                          {$ar(m.saldo)}
                        </td>
                        <td style={{ textAlign: 'right' }}>
                          {!esRemito && (
                            <button className="btn btn-danger btn-xs" onClick={() => eliminarMov(m)}>Eliminar</button>
                          )}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          </div>
        ) : null}
      </div>

      {movForm && (
        <MovimientoC2Form
          tipoSector={tipoSector}
          entidad={movForm.entidad}
          saldo={movForm.saldo}
          onSave={guardarMov}
          onClose={() => setMovForm(null)}
        />
      )}
    </div>
  )
}
