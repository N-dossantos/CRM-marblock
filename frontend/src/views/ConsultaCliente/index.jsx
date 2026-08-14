// src/views/ConsultaCliente/index.jsx
// Consulta integral de CLIENTE (360°) — Fase B. Sólo lectura: un cliente, todo lo suyo en un
// lugar (datos, saldo cta cte, presupuestos/facturas/remitos/notas/recibos con drill-down).
// No carga ni edita nada — para eso están los ABM de Ventas. Simétrico a ConsultaProveedor:
// reutiliza el shell Consulta360 y el modal VentaDetalle (que sí tiene PDF, a diferencia de Compras).
// Toda la data ya existe vía las RPC *_list / informe_cta_cte.
import { useState, useEffect, useCallback } from 'react'
import {
  ClientesAPI, InformesAPI, PresupuestosAPI, FacturasAPI, RemitosAPI, NotasAPI, RecibosAPI,
} from '../../api'
import { $ar, fFecha } from '../../utils'
import { Badge } from '../../components/UI'
import Consulta360 from '../../components/Consultas/Consulta360'
import VentaDetalle from '../../components/Consultas/VentaDetalle'

const MOV_STYLE = {
  FACTURA:      { bg: '#fef3c7', color: '#92400e', label: 'Factura' },
  RECIBO:       { bg: '#d1fae5', color: '#065f46', label: 'Recibo' },
  'NOTA CRED.': { bg: '#e0e7ff', color: '#3730a3', label: 'NC' },
  'NOTA DEB.':  { bg: '#fce7f3', color: '#9d174d', label: 'ND' },
}

const btnVer = (onClick) => (
  <button className="btn btn-ghost btn-xs" onClick={onClick}>Ver</button>
)

export default function ConsultaCliente() {
  const [clientes, setClientes] = useState([])
  const [selId, setSelId]     = useState('')
  const [data, setData]       = useState(null)
  const [loading, setLoading] = useState(false)
  const [detalle, setDetalle] = useState(null)  // { _doc, ...row } para VentaDetalle

  useEffect(() => { ClientesAPI.list().then(setClientes) }, [])

  const load = useCallback((id) => {
    setLoading(true)
    setData(null)
    Promise.all([
      ClientesAPI.get(id),
      InformesAPI.ctaCte(id),
      PresupuestosAPI.list({ cliente_id: id }),
      FacturasAPI.list({ cliente_id: id }),
      RemitosAPI.list({ cliente_id: id }),
      NotasAPI.list({ cliente_id: id }),
      RecibosAPI.list({ cliente_id: id }),
    ])
      .then(([cli, cta, presupuestos, facturas, remitos, notas, recibos]) =>
        setData({ cli, cta, presupuestos, facturas, remitos, notas, recibos }))
      .finally(() => setLoading(false))
  }, [])

  useEffect(() => { if (selId) load(selId) }, [selId, load])

  const abrir = (docType) => (row) => setDetalle({ _doc: docType, ...row })

  const header = data && (
    <div className="card" style={{ marginBottom: 8 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <h2 style={{ fontSize: 17, fontWeight: 700, color: 'var(--gray-800)' }}>{data.cli.razon_social}</h2>
          <div style={{ fontSize: 13, color: 'var(--gray-500)', marginTop: 4 }}>
            CUIT: {data.cli.cuit} · {data.cli.condicion_iva}
            {+data.cli.descuento_porcentaje > 0 && ` · Dto. ${data.cli.descuento_porcentaje}%`}
          </div>
          <div style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 4, display: 'flex', gap: 14, flexWrap: 'wrap' }}>
            {(data.cli.direccion || data.cli.localidad) && <span>📍 {[data.cli.direccion, data.cli.localidad].filter(Boolean).join(', ')}</span>}
            {data.cli.telefono && <span>📞 {data.cli.telefono}</span>}
            {data.cli.email && <span>✉️ {data.cli.email}</span>}
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px', marginBottom: 4 }}>Saldo actual</div>
          <div style={{ fontSize: 28, fontWeight: 800, lineHeight: 1, color: data.cta.saldo_total > 0 ? 'var(--red-500)' : data.cta.saldo_total < 0 ? '#10b981' : 'var(--gray-400)' }}>
            {$ar(data.cta.saldo_total)}
          </div>
          <div style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 4 }}>
            {data.cta.saldo_total > 0 ? '⬆ Saldo deudor' : data.cta.saldo_total < 0 ? '⬇ Saldo a favor' : '✓ Cuenta balanceada'}
          </div>
          {!data.cli.activo && <div style={{ fontSize: 11, color: 'var(--red-500)', marginTop: 4, fontWeight: 700 }}>Cliente inactivo</div>}
        </div>
      </div>
    </div>
  )

  const tabCtaCte = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr>
          <th>Fecha</th><th>Comprobante</th><th>Tipo</th>
          <th className="th-right">Debe</th><th className="th-right">Haber</th><th className="th-right">Saldo</th>
        </tr></thead>
        <tbody>
          {data.cta.movimientos.length === 0
            ? <tr><td colSpan={6} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin movimientos</td></tr>
            : data.cta.movimientos.map((m, i) => {
              const s = MOV_STYLE[m.tipo] || { bg: 'var(--gray-100)', color: 'var(--gray-600)', label: m.tipo }
              return (
                <tr key={i}>
                  <td>{fFecha(m.fecha)}</td>
                  <td><span className="code">{m.comprobante}</span></td>
                  <td><span style={{ background: s.bg, color: s.color, padding: '2px 9px', borderRadius: 10, fontSize: 11, fontWeight: 700 }}>{s.label}</span></td>
                  <td className="td-right" style={{ color: +m.debe > 0 ? 'var(--red-500)' : 'var(--gray-300)' }}>{+m.debe > 0 ? $ar(m.debe) : '—'}</td>
                  <td className="td-right" style={{ color: +m.haber > 0 ? '#10b981' : 'var(--gray-300)' }}>{+m.haber > 0 ? $ar(m.haber) : '—'}</td>
                  <td className="td-right" style={{ fontWeight: 700, color: +m.saldo > 0 ? 'var(--red-500)' : +m.saldo < 0 ? '#10b981' : 'var(--gray-600)' }}>{$ar(m.saldo)}</td>
                </tr>
              )
            })}
        </tbody>
      </table>
    </div>
  )

  const tabPresupuestos = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr><th>Número</th><th>Fecha</th><th>Vence</th><th>Estado</th><th className="th-right">Total</th><th></th></tr></thead>
        <tbody>
          {data.presupuestos.length === 0
            ? <tr><td colSpan={6} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin presupuestos</td></tr>
            : data.presupuestos.map(p => (
              <tr key={p.id}>
                <td><span className="code" style={{ fontWeight: 700 }}>{p.numero}</span></td>
                <td>{fFecha(p.fecha)}</td>
                <td>{fFecha(p.fecha_vcto)}</td>
                <td><Badge estado={p.estado} /></td>
                <td className="td-right td-bold">{$ar(p.total)}</td>
                <td>{btnVer(() => abrir('presupuesto')(p))}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  const tabFacturas = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr>
          <th>Número</th><th>Tipo</th><th>Fecha</th>
          <th className="th-right">Neto</th><th className="th-right">IVA</th><th className="th-right">Total</th>
          <th>Estado</th><th></th>
        </tr></thead>
        <tbody>
          {data.facturas.length === 0
            ? <tr><td colSpan={8} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin facturas</td></tr>
            : data.facturas.map(f => (
              <tr key={f.id}>
                <td><span className="code" style={{ fontWeight: 700 }}>{f.numero}</span></td>
                <td><span className={`badge badge-${f.tipo}`}>Fac {f.tipo}</span></td>
                <td>{fFecha(f.fecha)}</td>
                <td className="td-right" style={{ color: 'var(--gray-500)' }}>{$ar(f.neto_gravado)}</td>
                <td className="td-right" style={{ color: 'var(--gray-500)' }}>{$ar(f.iva_monto)}</td>
                <td className="td-right td-bold">{$ar(f.total)}</td>
                <td><Badge estado={f.estado} /></td>
                <td>{btnVer(() => abrir('factura')(f))}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  const tabRemitos = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr><th>Número</th><th>Fecha</th><th>Factura vinc.</th><th>Estado</th><th></th></tr></thead>
        <tbody>
          {data.remitos.length === 0
            ? <tr><td colSpan={5} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin remitos</td></tr>
            : data.remitos.map(r => (
              <tr key={r.id}>
                <td><span className="code" style={{ fontWeight: 700 }}>{r.numero}</span></td>
                <td>{fFecha(r.fecha)}</td>
                <td>{r.factura_numero ? <span className="code" style={{ color: 'var(--green-600)' }}>{r.factura_numero}</span> : <span style={{ color: 'var(--gray-400)' }}>—</span>}</td>
                <td><Badge estado={r.estado} /></td>
                <td>{btnVer(() => abrir('remito')(r))}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  const tabNotas = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr><th>Número</th><th>Tipo</th><th>Fecha</th><th>Factura vinc.</th><th className="th-right">Total</th><th></th></tr></thead>
        <tbody>
          {data.notas.length === 0
            ? <tr><td colSpan={6} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin notas</td></tr>
            : data.notas.map(n => (
              <tr key={n.id}>
                <td><span className="code" style={{ fontWeight: 700 }}>{n.numero}</span></td>
                <td><Badge estado={n.tipo} /></td>
                <td>{fFecha(n.fecha)}</td>
                <td><span className="code">{n.factura_numero}</span></td>
                <td className="td-right td-bold">{$ar(n.total)}</td>
                <td>{btnVer(() => abrir('nota')(n))}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  const tabRecibos = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr><th>Número</th><th>Fecha</th><th>Facturas imputadas</th><th className="th-right">Total</th><th></th></tr></thead>
        <tbody>
          {data.recibos.length === 0
            ? <tr><td colSpan={5} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin recibos</td></tr>
            : data.recibos.map(r => (
              <tr key={r.id}>
                <td><span className="code" style={{ fontWeight: 700 }}>{r.numero}</span></td>
                <td>{fFecha(r.fecha)}</td>
                <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{(r.facturas || []).map(f => f.numero).join(', ') || '— (a cuenta)'}</td>
                <td className="td-right td-bold">{$ar(r.total)}</td>
                <td>{btnVer(() => abrir('recibo')(r))}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  const tabs = data ? [
    { id: 'ctacte',       label: '📒 Cta. corriente', render: tabCtaCte },
    { id: 'presupuestos', label: '📋 Presupuestos', count: data.presupuestos.length, render: tabPresupuestos },
    { id: 'facturas',     label: '🧾 Facturas',  count: data.facturas.length, render: tabFacturas },
    { id: 'remitos',      label: '🚚 Remitos',   count: data.remitos.length,  render: tabRemitos },
    { id: 'notas',        label: '📝 Notas',     count: data.notas.length,    render: tabNotas },
    { id: 'recibos',      label: '💵 Recibos',   count: data.recibos.length,  render: tabRecibos },
  ] : []

  return (
    <>
      <Consulta360
        entities={clientes}
        selId={selId}
        onSelect={setSelId}
        searchPlaceholder="Buscar cliente…"
        emptyText="Seleccione un cliente para ver su ficha completa"
        selSaldo={data?.cta?.saldo_total ?? null}
        saldoLabels={{ pos: '▲ Debe', neg: '▼ A favor', zero: '✓ Sin saldo' }}
        loading={loading}
        data={data}
        header={header}
        tabs={tabs}
      />
      {detalle && <VentaDetalle doc={detalle} onClose={() => setDetalle(null)} />}
    </>
  )
}
