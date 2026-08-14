// src/views/ConsultaProveedor/index.jsx
// Consulta integral de PROVEEDOR (360°) — Fase B. Sólo lectura: un proveedor, todo lo suyo en un
// lugar (datos, saldo cta cte, facturas/remitos/notas/pagos con drill-down, retenciones config).
// No carga ni edita nada — para eso están los ABM de Compras. Reutiliza el shell Consulta360 y el
// modal CompraDetalle. Toda la data ya existe vía las RPC *_compra_list / informe_cta_cte_proveedor.
import { useState, useEffect, useCallback } from 'react'
import {
  ProveedoresAPI, InformesAPI, FacturasCompraAPI, RemitosCompraAPI, NotasCompraAPI, PagosProveedorAPI,
} from '../../api'
import { $ar, fFecha } from '../../utils'
import { Badge } from '../../components/UI'
import Consulta360 from '../../components/Consultas/Consulta360'
import CompraDetalle from '../../components/Consultas/CompraDetalle'

const MOV_STYLE = {
  FACTURA:      { bg: '#fef3c7', color: '#92400e', label: 'Factura' },
  PAGO:         { bg: '#d1fae5', color: '#065f46', label: 'Pago' },
  'NOTA CRED.': { bg: '#e0e7ff', color: '#3730a3', label: 'NC' },
  'NOTA DEB.':  { bg: '#fce7f3', color: '#9d174d', label: 'ND' },
  'RETENCIÓN':  { bg: '#f1f5f9', color: '#334155', label: 'Retención' },
}

const btnVer = (onClick) => (
  <button className="btn btn-ghost btn-xs" onClick={onClick}>Ver</button>
)

export default function ConsultaProveedor() {
  const [proveedores, setProveedores] = useState([])
  const [selId, setSelId]   = useState('')
  const [data, setData]     = useState(null)
  const [loading, setLoading] = useState(false)
  const [detalle, setDetalle] = useState(null)  // { _doc, ...row } para CompraDetalle

  useEffect(() => { ProveedoresAPI.list().then(setProveedores) }, [])

  const load = useCallback((id) => {
    setLoading(true)
    setData(null)
    Promise.all([
      ProveedoresAPI.get(id),
      InformesAPI.ctaCteProveedor(id),
      FacturasCompraAPI.list({ proveedor_id: id }),
      RemitosCompraAPI.list({ proveedor_id: id }),
      NotasCompraAPI.list({ proveedor_id: id }),
      PagosProveedorAPI.list({ proveedor_id: id }),
      ProveedoresAPI.alicuotas(id),
    ])
      .then(([prov, cta, facturas, remitos, notas, pagos, alicuotas]) =>
        setData({ prov, cta, facturas, remitos, notas, pagos, alicuotas }))
      .finally(() => setLoading(false))
  }, [])

  useEffect(() => { if (selId) load(selId) }, [selId, load])

  const abrir = (docType) => (row) => setDetalle({ _doc: docType, ...row })

  const header = data && (
    <div className="card" style={{ marginBottom: 8 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <h2 style={{ fontSize: 17, fontWeight: 700, color: 'var(--gray-800)' }}>{data.prov.razon_social}</h2>
          <div style={{ fontSize: 13, color: 'var(--gray-500)', marginTop: 4 }}>
            CUIT: {data.prov.cuit} · {data.prov.condicion_iva} · {data.prov.condicion_compra}
          </div>
          <div style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 4, display: 'flex', gap: 14, flexWrap: 'wrap' }}>
            {data.prov.actividad && <span>🏷️ {data.prov.actividad}</span>}
            {(data.prov.direccion || data.prov.localidad) && <span>📍 {[data.prov.direccion, data.prov.localidad].filter(Boolean).join(', ')}</span>}
            {data.prov.telefono && <span>📞 {data.prov.telefono}</span>}
            {data.prov.email && <span>✉️ {data.prov.email}</span>}
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px', marginBottom: 4 }}>Saldo actual</div>
          <div style={{ fontSize: 28, fontWeight: 800, lineHeight: 1, color: data.cta.saldo_total > 0 ? 'var(--red-500)' : data.cta.saldo_total < 0 ? '#10b981' : 'var(--gray-400)' }}>
            {$ar(data.cta.saldo_total)}
          </div>
          <div style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 4 }}>
            {data.cta.saldo_total > 0 ? '⬆ Le debemos' : data.cta.saldo_total < 0 ? '⬇ Saldo a favor' : '✓ Cuenta balanceada'}
          </div>
          {!data.prov.activo && <div style={{ fontSize: 11, color: 'var(--red-500)', marginTop: 4, fontWeight: 700 }}>Proveedor inactivo</div>}
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

  const tabPagos = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr><th>Número</th><th>Fecha</th><th>Facturas</th><th className="th-right">Total</th><th></th></tr></thead>
        <tbody>
          {data.pagos.length === 0
            ? <tr><td colSpan={5} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin pagos</td></tr>
            : data.pagos.map(p => (
              <tr key={p.id}>
                <td><span className="code" style={{ fontWeight: 700 }}>{p.numero}</span></td>
                <td>{fFecha(p.fecha)}</td>
                <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{(p.facturas || []).map(f => f.numero).join(', ') || '—'}</td>
                <td className="td-right td-bold">{$ar(p.total)}</td>
                <td>{btnVer(() => abrir('pago')(p))}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  const tabRetenciones = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr><th>Tipo</th><th>Jurisdicción</th><th className="th-right">Alícuota</th><th>Vigente desde</th></tr></thead>
        <tbody>
          {(data.alicuotas || []).length === 0
            ? <tr><td colSpan={4} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin retenciones configuradas</td></tr>
            : data.alicuotas.map(a => (
              <tr key={a.id}>
                <td className="td-bold">{a.tipo_retencion}</td>
                <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{a.jurisdiccion || '—'}</td>
                <td className="td-right td-bold">{a.alicuota}%</td>
                <td>{fFecha(a.vigente_desde)}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  const tabs = data ? [
    { id: 'ctacte',   label: '📒 Cta. corriente', render: tabCtaCte },
    { id: 'facturas', label: '🧾 Facturas',  count: data.facturas.length, render: tabFacturas },
    { id: 'remitos',  label: '🚚 Remitos',   count: data.remitos.length,  render: tabRemitos },
    { id: 'notas',    label: '📝 Notas',     count: data.notas.length,    render: tabNotas },
    { id: 'pagos',    label: '💸 Pagos',     count: data.pagos.length,    render: tabPagos },
    { id: 'retenciones', label: '📑 Retenciones', count: (data.alicuotas || []).length, render: tabRetenciones },
  ] : []

  return (
    <>
      <Consulta360
        entities={proveedores}
        selId={selId}
        onSelect={setSelId}
        searchPlaceholder="Buscar proveedor…"
        emptyText="Seleccione un proveedor para ver su ficha completa"
        selSaldo={data?.cta?.saldo_total ?? null}
        saldoLabels={{ pos: '▲ Le debemos', neg: '▼ A favor', zero: '✓ Sin saldo' }}
        loading={loading}
        data={data}
        header={header}
        tabs={tabs}
      />
      {detalle && <CompraDetalle doc={detalle} onClose={() => setDetalle(null)} />}
    </>
  )
}
