// src/views/Cuenta2/index.jsx
// Sección Cuenta 2 — circuito informal aislado del oficial (cuenta2.md).
// Una sola vista sirve Ventas y Compras vía `tipoSector`: el circuito es idéntico y sólo
// cambian la entidad (cliente/proveedor) y los textos, así que clonarla sería duplicar 400
// líneas. Misma idea que ComprobanteForm sirviendo presupuesto/remito/factura con `tipo`.
// Sub-tabs con useState (patrón de views/TesoreriaCuentas), no ruteo anidado.
import { useState, useEffect, useCallback } from 'react'
import { ClientesC2API, ProveedoresC2API, RemitosC2API, MovimientosC2API, InformesC2API, pdfUrlC2, ctaCteC2PDF } from '../../api/cuenta2'
import { ProductosAPI, MaterialesAPI } from '../../api'
import { $ar, fFecha, telefonoWhatsApp } from '../../utils'
import { Modal, Loading, EmptyState, ItemsTable } from '../../components/UI'
import PDFModal from '../../components/PDFModal'
import RemitoXForm from '../../components/Forms/RemitoXForm'
import MovimientoC2Form from '../../components/Forms/MovimientoC2Form'
import EntidadC2Form from '../../components/Forms/EntidadC2Form'
import toast from 'react-hot-toast'

const TIPO_STYLE = {
  'REMITO X': { bg: 'var(--amber-100)', color: 'var(--amber-700)', label: 'Remito X' },
  COBRO:      { bg: 'var(--green-100)', color: 'var(--green-700)', label: 'Cobro' },
  PAGO:       { bg: 'var(--green-100)', color: 'var(--green-700)', label: 'Pago' },
  AJUSTE:     { bg: 'var(--indigo-100)', color: 'var(--indigo-700)', label: 'Ajuste' },
  'SALDO ANTERIOR': { bg: 'var(--gray-100)', color: 'var(--gray-700)', label: 'Saldo anterior' },
}

function TipoC2({ tipo }) {
  const ts = TIPO_STYLE[tipo] || { bg: 'var(--gray-100)', color: 'var(--gray-600)', label: tipo }
  return (
    <span style={{ background: ts.bg, color: ts.color, padding: '2px 9px', borderRadius: 10, fontSize: 'calc(11px * var(--font-scale))', fontWeight: 700 }}>
      {ts.label}
    </span>
  )
}

// Rojo = suma a la deuda, verde = la baja (mismo criterio que las columnas debe/haber/saldo).
const colorMonto = (v) => (v > 0 ? 'var(--red-500)' : v < 0 ? 'var(--green-600)' : 'var(--gray-600)')

export default function Cuenta2({ tipoSector }) {
  const esVenta = tipoSector === 'venta'
  const [sub, setSub] = useState('ctacte')

  // Orden pedido: la cuenta corriente primero (es la pantalla de consulta diaria), después la
  // carga de remitos y al final el ABM de la entidad, que casi no se toca.
  const SUBTABS = [
    { id: 'ctacte',    label: '📒 Cuenta corriente' },
    { id: 'remitos',   label: '📄 Remitos X' },
    { id: 'entidades', label: esVenta ? '👥 Clientes' : '🏭 Proveedores' },
  ]

  return (
    <div>
      <div className="info-box" style={{ marginBottom: 16 }}>
        <span>
          <strong>Circuito Cuenta 2</strong> — sin impuestos, sin numeración fiscal y aislado de
          Cuenta 1: estos clientes, saldos y cheques no aparecen en el circuito oficial.
        </span>
      </div>

      <div className="cuenta2-tabs">
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
    fontSize: 'calc(13px * var(--font-scale))', cursor: 'pointer', fontFamily: 'inherit', whiteSpace: 'nowrap',
  }
}

// La entidad del sector: clientes en ventas, proveedores en compras.
const entidadAPIde = (tipoSector) => (tipoSector === 'venta' ? ClientesC2API : ProveedoresC2API)

// Entidades activas + catálogo para RemitoXForm (tab Remitos X y botón de la cta. cte.).
// Proveedores (sector 'compra') compran materiales del catálogo de Compras, no productos de
// Ventas — se adapta a la forma que espera ItemsTable/ProductoBuscador (id/codigo/descripcion/
// precio_sin_iva), sin concepto de pallets (unidades_por_pallet=1 → Pallets ≡ cantidad).
// `activo` = false no pide nada: la cta. cte. lo prende recién al abrir el formulario.
function useCatalogoC2(tipoSector, activo = true) {
  const [entidades, setEntidades] = useState([])
  const [productos, setProductos] = useState([])
  useEffect(() => {
    if (!activo) return
    entidadAPIde(tipoSector).list({ activo: true }).then(setEntidades)
    if (tipoSector === 'venta') {
      ProductosAPI.list({ activo: true }).then(setProductos)
    } else {
      MaterialesAPI.list({ activo: true }).then(mats => setProductos(mats.map(m => ({
        id: m.id, codigo: m.codigo, descripcion: m.descripcion,
        precio_sin_iva: m.precio_referencia, unidades_por_pallet: 1,
        es_pallet_vacio: false, es_transporte: false, activo: m.activo,
      }))))
    }
  }, [tipoSector, activo])
  return { entidades, productos }
}

// ══════════════════════ REMITOS X ══════════════════════
function RemitosX({ tipoSector }) {
  const esVenta = tipoSector === 'venta'
  const [rows, setRows]           = useState([])
  const { entidades, productos }  = useCatalogoC2(tipoSector)
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

      {detalle && <RemitoXDetalle remito={detalle} onClose={() => setDetalle(null)} />}
    </div>
  )
}

// Vista de sólo lectura de un Remito X: la usan la solapa Remitos X y la cta. cte. en el celular.
function RemitoXDetalle({ remito, onClose }) {
  return (
    <Modal title={`Remito X ${remito.numero}`} size="lg" onClose={onClose}>
      <div className="info-box" style={{ marginBottom: 14 }}>
        <span>
          {remito.entidad_nombre} · {fFecha(remito.fecha)}
          {+remito.descuento_porcentaje > 0 && ` · Descuento ${remito.descuento_porcentaje}%`}
        </span>
      </div>
      <ItemsTable items={remito.items || []} readonly />
      <div className="totales-box">
        <div className="totales-row"><span>Subtotal</span><span>{$ar(remito.subtotal)}</span></div>
        {+remito.descuento_monto > 0 && (
          <div className="totales-row">
            <span>Descuento</span>
            <span style={{ color: 'var(--red-500)' }}>— {$ar(remito.descuento_monto)}</span>
          </div>
        )}
        <hr className="totales-divider" />
        <div className="totales-row total"><span>TOTAL</span><span className="val">{$ar(remito.total)}</span></div>
      </div>
      {remito.observaciones && (
        <p style={{ marginTop: 12, fontSize: 'calc(13px * var(--font-scale))', color: 'var(--gray-600)' }}>{remito.observaciones}</p>
      )}
    </Modal>
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
                  <td className="td-right td-bold" style={{ color: +e.saldo > 0 ? 'var(--red-500)' : +e.saldo < 0 ? 'var(--green-600)' : 'var(--gray-400)' }}>
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
  const [pdfModal, setPdfModal]   = useState(null)
  const [remitoForm, setRemitoForm] = useState(false)
  const [enviandoWA, setEnviandoWA] = useState(false)
  const [abierto, setAbierto]     = useState(null)   // movimiento desplegado en la lista del celular
  const [remitoDetalle, setRemitoDetalle] = useState(null)
  const catalogo = useCatalogoC2(tipoSector, remitoForm)

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

  const guardarRemito = async (payload) => {
    await RemitosC2API.create(payload)
    toast.success('Remito X guardado')
    setRemitoForm(false); cargar(); loadEntidades()
  }

  const verRemito = (id) => {
    RemitosC2API.get(id).then(setRemitoDetalle).catch(() => { /* el toast ya lo emitió la capa API */ })
  }

  // wa.me no adjunta archivos: se descarga el PDF (con el filtro aplicado) y se abre el chat con
  // un mensaje corto; el archivo se arrastra a mano. La ventana se abre en el clic: si se abre
  // después del fetch, el navegador la bloquea como popup.
  const enviarWhatsApp = async () => {
    const numero = telefonoWhatsApp(data.entidad.telefono)
    if (!numero) {
      toast.error(data.entidad.telefono
        ? `No se puede armar un celular con "${data.entidad.telefono}". Cargalo con código de área, ej. 11 2345-6789.`
        : 'El cliente no tiene teléfono cargado (solapa Clientes → Editar).')
      return
    }
    const ventana = window.open('', '_blank')
    setEnviandoWA(true)
    try {
      const blob = await ctaCteC2PDF(tipoSector, selId, desde, hasta)
      const a = document.createElement('a')
      a.href = URL.createObjectURL(blob)
      // Sin "C2" en el nombre: este archivo lo recibe el cliente.
      a.download = `Cuenta_corriente-${data.entidad.nombre.replace(/[^\p{L}\p{N}]+/gu, '_')}.pdf`
      a.click()
      setTimeout(() => URL.revokeObjectURL(a.href), 10000)
      const wa = `https://wa.me/${numero}?text=${encodeURIComponent('Hola! Te paso el resumen de tu cuenta corriente.')}`
      if (ventana) ventana.location.href = wa
      else window.location.href = wa
      toast.success('PDF descargado: arrastralo al chat de WhatsApp')
    } catch (e) {
      ventana?.close()
      toast.error(e.message || 'No se pudo generar el PDF')
    } finally {
      setEnviandoWA(false)
    }
  }

  const filtradas = entidades.filter(e =>
    !search || e.nombre.toLowerCase().includes(search.toLowerCase()) || (e.telefono || '').includes(search)
  )
  const saldo = data?.saldo_total ?? 0

  return (
    <div className="cuenta2-ctacte">
      {/* Panel izquierdo: entidades */}
      <div className="cuenta2-entidades">
        <div className="card" style={{ padding: '14px', marginBottom: 0, borderBottom: 'none', borderBottomLeftRadius: 0, borderBottomRightRadius: 0 }}>
          <input
            className="search-inp"
            style={{ width: '100%' }}
            placeholder={`Buscar ${esVenta ? 'cliente' : 'proveedor'}…`}
            value={search}
            onChange={e => setSearch(e.target.value)}
          />
        </div>
        <div className="cuenta2-entidades-lista">
          {search.trim() && filtradas.length === 0 && (
            <p className="cuenta2-sin-resultados">No se encontraron {esVenta ? 'clientes' : 'proveedores'}.</p>
          )}
          {filtradas.map(e => (
            <button type="button"
              key={e.id}
              className={`cuenta2-entidad${selId === e.id ? ' is-selected' : ''}`}
              onClick={() => {
                setSelId(e.id)
                if (window.matchMedia('(max-width: 760px)').matches) setSearch('')
              }}
            >
              <div style={{ fontWeight: selId === e.id ? 700 : 500, fontSize: 'calc(13px * var(--font-scale))', color: 'var(--gray-800)' }}>
                {e.nombre.length > 28 ? e.nombre.slice(0, 28) + '…' : e.nombre}
              </div>
              <div className="cuenta2-entidad-saldo" style={{ fontSize: 'calc(12px * var(--font-scale))', fontWeight: 700, color: +e.saldo > 0 ? 'var(--red-500)' : +e.saldo < 0 ? 'var(--green-600)' : 'var(--gray-400)', marginTop: 2 }}>
                {$ar(e.saldo)} {+e.saldo > 0 ? (esVenta ? '▲ Debe' : '▲ Le debemos') : +e.saldo < 0 ? '▼ A favor' : '✓ Sin saldo'}
              </div>
            </button>
          ))}
        </div>
      </div>

      {/* Panel derecho: movimientos */}
      <div className={`cuenta2-detalle${search.trim() ? ' is-searching' : ''}`}>
        {!selId ? (
          <div className="card" style={{ textAlign: 'center', padding: '60px 20px' }}>
            <div style={{ fontSize: 'calc(40px * var(--font-scale))', marginBottom: 12 }}>📒</div>
            <p style={{ color: 'var(--gray-400)', fontSize: 'calc(14px * var(--font-scale))' }}>
              Seleccione un {esVenta ? 'cliente' : 'proveedor'} para ver su cuenta corriente
            </p>
          </div>
        ) : loading ? (
          <Loading />
        ) : data ? (
          <div>
            <div className="card" style={{ marginBottom: 14 }}>
              <div className="cuenta2-resumen">
                <div>
                  <h2 style={{ fontSize: 'calc(17px * var(--font-scale))', fontWeight: 700, color: 'var(--gray-800)' }}>{data.entidad.nombre}</h2>
                  <div style={{ fontSize: 'calc(13px * var(--font-scale))', color: 'var(--gray-500)', marginTop: 4 }}>
                    {data.entidad.telefono || 'Sin teléfono'}
                    {+data.entidad.descuento_porcentaje > 0 && ` · Descuento ${data.entidad.descuento_porcentaje}%`}
                  </div>
                </div>
                <div className="cuenta2-resumen-saldo">
                  <div style={{ fontSize: 'calc(11px * var(--font-scale))', fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px', marginBottom: 4 }}>Saldo actual</div>
                  <div style={{ fontSize: 'calc(28px * var(--font-scale))', fontWeight: 800, color: saldo > 0 ? 'var(--red-500)' : saldo < 0 ? 'var(--green-600)' : 'var(--gray-400)', lineHeight: 1 }}>
                    {$ar(saldo)}
                  </div>
                  <div style={{ fontSize: 'calc(12px * var(--font-scale))', color: 'var(--gray-400)', marginTop: 4 }}>
                    {saldo > 0 ? (esVenta ? '⬆ Saldo deudor' : '⬆ Le debemos') : saldo < 0 ? '⬇ Saldo a favor' : '✓ Cuenta balanceada'}
                  </div>
                  <div className="cuenta2-acciones">
                    <button
                      className="btn btn-secondary btn-sm"
                      onClick={() => setPdfModal({
                        url: pdfUrlC2.ctaCte(tipoSector, selId, desde, hasta),
                        titulo: `Cuenta Corriente C2 — ${data.entidad.nombre}`,
                      })}
                    >
                      📄 Generar PDF
                    </button>
                    {esVenta && (
                      <button
                        className="btn btn-secondary btn-sm"
                        onClick={enviarWhatsApp}
                        disabled={enviandoWA}
                        title={data.entidad.telefono ? `Enviar a ${data.entidad.telefono}` : 'Sin teléfono cargado'}
                      >
                        {enviandoWA ? 'Generando…' : '💬 WhatsApp'}
                      </button>
                    )}
                    <button className="btn btn-secondary btn-sm" onClick={() => setRemitoForm(true)}>
                      + Nuevo Remito X
                    </button>
                    <button
                      className="btn btn-primary btn-sm"
                      onClick={() => setMovForm({ entidad: data.entidad, saldo })}
                    >
                      + Registrar {esVenta ? 'cobro' : 'pago'}
                    </button>
                  </div>
                </div>
              </div>

              <div className="cuenta2-filtros">
                <span style={{ fontSize: 'calc(12px * var(--font-scale))', color: 'var(--gray-500)', fontWeight: 600 }}>Filtrar por período:</span>
                <input type="date" className="inp" style={{ width: 150 }} value={desde} onChange={e => setDesde(e.target.value)} />
                <span style={{ color: 'var(--gray-400)' }}>al</span>
                <input type="date" className="inp" style={{ width: 150 }} value={hasta} onChange={e => setHasta(e.target.value)} />
                <button className="btn btn-secondary btn-sm" onClick={cargar}>Aplicar</button>
                <button className="btn btn-ghost btn-sm" onClick={() => { setDesde(''); setHasta(''); setTimeout(cargar, 0) }}>Limpiar</button>
              </div>
            </div>

            <div className="tbl-wrap cuenta2-movs-tabla">
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
                    // Remitos se borran desde su solapa; la fila de saldo anterior es sintética (id null).
                    const sinEliminar = m.tipo === 'REMITO X' || m.tipo === 'SALDO ANTERIOR'
                    return (
                      <tr key={`${m.tipo}-${m.id}-${i}`}>
                        <td>{fFecha(m.fecha)}</td>
                        <td><span className="code">{m.comprobante}</span></td>
                        <td><TipoC2 tipo={m.tipo} /></td>
                        <td className="td-right" style={{ color: parseFloat(m.debe) > 0 ? 'var(--red-500)' : 'var(--gray-300)', fontWeight: parseFloat(m.debe) > 0 ? 600 : 400 }}>
                          {parseFloat(m.debe) > 0 ? $ar(m.debe) : '—'}
                        </td>
                        <td className="td-right" style={{ color: parseFloat(m.haber) > 0 ? 'var(--green-600)' : 'var(--gray-300)', fontWeight: parseFloat(m.haber) > 0 ? 600 : 400 }}>
                          {parseFloat(m.haber) > 0 ? $ar(m.haber) : '—'}
                        </td>
                        <td className="td-right" style={{ fontWeight: 700, color: parseFloat(m.saldo) > 0 ? 'var(--red-500)' : parseFloat(m.saldo) < 0 ? 'var(--green-600)' : 'var(--gray-600)' }}>
                          {$ar(m.saldo)}
                        </td>
                        <td style={{ textAlign: 'right' }}>
                          {!sinEliminar && (
                            <button className="btn btn-danger btn-xs" onClick={() => eliminarMov(m)}>Eliminar</button>
                          )}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>

            {/* Celular: en lugar de la tabla de 7 columnas, una fila compacta por movimiento
                (fecha, tipo, importe y saldo) que se despliega para ver el resto. */}
            <div className="cuenta2-movs-lista">
              {data.movimientos.length === 0 ? (
                <p className="cuenta2-movs-vacio">Sin movimientos en el período</p>
              ) : data.movimientos.map((m, i) => {
                const clave = `${m.tipo}-${m.id}`
                const esSaldoAnterior = m.tipo === 'SALDO ANTERIOR'
                const sinEliminar = m.tipo === 'REMITO X' || esSaldoAnterior
                const debe = parseFloat(m.debe), haber = parseFloat(m.haber), saldoMov = parseFloat(m.saldo)
                const neto = debe - haber
                const estaAbierto = abierto === clave
                return (
                  <div key={`${clave}-${i}`} className={`cuenta2-mov${estaAbierto ? ' is-open' : ''}`}>
                    <div className="cuenta2-mov-resumen">
                      <div className="cuenta2-mov-datos-cortos">
                        <div className="cuenta2-mov-linea">
                          <span className="cuenta2-mov-fecha">{fFecha(m.fecha)}</span>
                          <TipoC2 tipo={m.tipo} />
                          {!esSaldoAnterior && (
                            <span className="cuenta2-mov-importe" style={{ color: colorMonto(neto) }}>
                              {neto < 0 ? `− ${$ar(-neto)}` : neto > 0 ? $ar(neto) : '—'}
                            </span>
                          )}
                        </div>
                        <div className="cuenta2-mov-linea">
                          <span className="cuenta2-mov-comp">{esSaldoAnterior ? 'Saldo al inicio del período' : m.comprobante}</span>
                          <span className="cuenta2-mov-saldo">
                            Saldo <strong style={{ color: colorMonto(saldoMov) }}>{$ar(m.saldo)}</strong>
                          </span>
                        </div>
                      </div>
                      {!esSaldoAnterior && (
                        <button
                          type="button"
                          className="btn btn-secondary cuenta2-mov-toggle"
                          aria-expanded={estaAbierto}
                          aria-controls={`cuenta2-mov-${i}`}
                          aria-label={estaAbierto ? 'Ocultar detalle' : 'Ver detalle'}
                          onClick={() => setAbierto(estaAbierto ? null : clave)}
                        >
                          <span aria-hidden="true">▾</span>
                        </button>
                      )}
                    </div>
                    {estaAbierto && (
                      <div className="cuenta2-mov-detalle" id={`cuenta2-mov-${i}`}>
                        <dl className="cuenta2-mov-campos">
                          <dt>Comprobante / concepto</dt>
                          <dd className="cuenta2-mov-concepto">{m.comprobante}</dd>
                          <dt>Fecha</dt>
                          <dd>{fFecha(m.fecha)}</dd>
                          <dt>Debe</dt>
                          <dd style={{ color: debe > 0 ? 'var(--red-500)' : 'var(--gray-400)' }}>{debe > 0 ? $ar(m.debe) : '—'}</dd>
                          <dt>Haber</dt>
                          <dd style={{ color: haber > 0 ? 'var(--green-600)' : 'var(--gray-400)' }}>{haber > 0 ? $ar(m.haber) : '—'}</dd>
                          <dt>Saldo</dt>
                          <dd style={{ color: colorMonto(saldoMov), fontWeight: 700 }}>{$ar(m.saldo)}</dd>
                        </dl>
                        <div className="cuenta2-mov-acciones">
                          {m.tipo === 'REMITO X' && (
                            <button type="button" className="btn btn-secondary btn-sm" onClick={() => verRemito(m.id)}>Ver remito</button>
                          )}
                          {!sinEliminar && (
                            <button type="button" className="btn btn-danger btn-sm" onClick={() => eliminarMov(m)}>Eliminar movimiento</button>
                          )}
                        </div>
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          </div>
        ) : null}
      </div>

      {remitoDetalle && <RemitoXDetalle remito={remitoDetalle} onClose={() => setRemitoDetalle(null)} />}

      {remitoForm && (
        <RemitoXForm
          title={`Nuevo Remito X — ${data.entidad.nombre}`}
          tipoSector={tipoSector}
          initial={{ entidad_id: data.entidad.id, descuento_porcentaje: data.entidad.descuento_porcentaje }}
          entidades={catalogo.entidades}
          productos={catalogo.productos}
          onSave={guardarRemito}
          onClose={() => setRemitoForm(false)}
        />
      )}

      {movForm && (
        <MovimientoC2Form
          tipoSector={tipoSector}
          entidad={movForm.entidad}
          saldo={movForm.saldo}
          onSave={guardarMov}
          onClose={() => setMovForm(null)}
        />
      )}

      {pdfModal && <PDFModal url={pdfModal.url} titulo={pdfModal.titulo} onClose={() => setPdfModal(null)} />}
    </div>
  )
}
