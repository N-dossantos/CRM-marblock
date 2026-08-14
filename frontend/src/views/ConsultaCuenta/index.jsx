// src/views/ConsultaCuenta/index.jsx
// Consulta integral de CUENTA de tesorería (360°) — Fase D. Sólo lectura: una cuenta (banco/caja/
// valores), todo su detalle en un lugar (subdiario con saldo corrido, cheques propios/terceros que
// la tocan, transferencias, comprobantes, conciliación). No carga ni edita nada — para eso están los
// ABM de Tesorería. Reusa el shell Consulta360 (con accessors de cuenta) + el modal MovimientoDetalle.
// Toda la data sale de RPC ya existentes de Fase C (informe_subdiario_cuenta, informe_cheques_tesoreria,
// movimientos_tesoreria_list) + conciliaciones (PostgREST). Sin backend nuevo.
import { useState, useEffect, useCallback } from 'react'
import {
  CuentasBancariasAPI, InformesAPI, MovimientosTesoreriaAPI, ConciliacionAPI,
  AgrupacionesTesoreriaAPI, pdfUrl,
} from '../../api'
import { $ar, fFecha } from '../../utils'
import Consulta360 from '../../components/Consultas/Consulta360'
import MovimientoDetalle from '../../components/Consultas/MovimientoDetalle'
import PDFModal from '../../components/PDFModal'

const CLASE_LABEL = { banco: 'Banco', caja: 'Caja', valores: 'Valores' }

const ESTADO_CHEQUE = {
  en_cartera: { bg: '#dbeafe', color: '#1e40af', label: 'En cartera' },
  depositado: { bg: '#d1fae5', color: '#065f46', label: 'Depositado' },
  entregado:  { bg: '#e0e7ff', color: '#3730a3', label: 'Entregado' },
  emitido:    { bg: '#fef3c7', color: '#92400e', label: 'Emitido' },
  pagado:     { bg: '#d1fae5', color: '#065f46', label: 'Pagado' },
  rechazado:  { bg: '#fee2e2', color: '#991b1b', label: 'Rechazado' },
  rechazado_banco: { bg: '#fee2e2', color: '#991b1b', label: 'Rechazado' },
  anulado:    { bg: '#f1f5f9', color: '#64748b', label: 'Anulado' },
}

const chip = (bg, color, label) => (
  <span style={{ background: bg, color, padding: '2px 9px', borderRadius: 10, fontSize: 11, fontWeight: 700 }}>{label}</span>
)
const btnVer = (onClick) => <button className="btn btn-ghost btn-xs" onClick={onClick}>Ver</button>

export default function ConsultaCuenta() {
  const [cuentas, setCuentas] = useState([])
  const [agrup, setAgrup]     = useState({})   // id -> descripcion
  const [selId, setSelId]     = useState('')
  const [data, setData]       = useState(null)
  const [loading, setLoading] = useState(false)
  const [mov, setMov]         = useState(null)  // MovimientoDetalle
  const [pdf, setPdf]         = useState(null)  // PDFModal para cheques

  useEffect(() => {
    CuentasBancariasAPI.list().then(setCuentas)
    AgrupacionesTesoreriaAPI.list().then(gs =>
      setAgrup(Object.fromEntries(gs.map(g => [g.id, g.descripcion]))))
  }, [])

  const load = useCallback((id) => {
    setLoading(true)
    setData(null)
    Promise.all([
      InformesAPI.subdiarioCuenta(id),
      InformesAPI.chequesTesoreria(),
      MovimientosTesoreriaAPI.list({ cuenta_id: id }),
      ConciliacionAPI.list(id),
    ])
      .then(([sub, cheques, movimientos, conciliaciones]) =>
        setData({
          cuenta: sub.cuenta,
          sub,
          cheques: cheques?.cheques || [],
          movimientos: movimientos || [],
          conciliaciones: conciliaciones || [],
        }))
      .finally(() => setLoading(false))
  }, [])

  useEffect(() => { if (selId) load(selId) }, [selId, load])

  // Abre el drill-down de un movimiento, enriqueciendo con datos de la cuenta (las filas del
  // subdiario no traen cuenta_descripcion/clase porque son todas de esta cuenta).
  const abrirMov = (row) => setMov({
    ...row,
    cuenta_descripcion: row.cuenta_descripcion ?? data.cuenta.descripcion,
    cuenta_clase:       row.cuenta_clase ?? data.cuenta.clase,
  })

  // Derivados por cuenta (todo cliente-side, sin backend nuevo — §2.3)
  const chequesPropios   = data ? data.cheques.filter(c => c.origen === 'propio' && c.banco === data.cuenta.descripcion) : []
  const chequesTerceros  = data ? data.movimientos.filter(m => m.origen === 'cheque') : []
  const transferencias   = data ? data.movimientos.filter(m => m.origen === 'transferencia') : []

  const header = data && (
    <div className="card" style={{ marginBottom: 8 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <h2 style={{ fontSize: 17, fontWeight: 700, color: 'var(--gray-800)' }}>{data.cuenta.descripcion}</h2>
          <div style={{ fontSize: 13, color: 'var(--gray-500)', marginTop: 4 }}>
            {CLASE_LABEL[data.cuenta.clase] || data.cuenta.clase}
            {data.cuenta.banco ? ` · ${data.cuenta.banco}` : ''}
            {data.cuenta.agrupacion_id && agrup[data.cuenta.agrupacion_id] ? ` · ${agrup[data.cuenta.agrupacion_id]}` : ''}
          </div>
          <div style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 4, display: 'flex', gap: 14, flexWrap: 'wrap' }}>
            {data.cuenta.numero && <span>N°: {data.cuenta.numero}</span>}
            {data.cuenta.cbu && <span>CBU: {data.cuenta.cbu}</span>}
            {data.cuenta.alias && <span>Alias: {data.cuenta.alias}</span>}
            <span>Saldo inicial: {$ar(data.cuenta.saldo_inicial)}</span>
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.5px', marginBottom: 4 }}>Saldo actual</div>
          <div style={{ fontSize: 28, fontWeight: 800, lineHeight: 1, color: data.sub.saldo_final < 0 ? 'var(--red-500)' : '#10b981' }}>
            {$ar(data.sub.saldo_final)}
          </div>
          <div style={{ fontSize: 12, color: 'var(--gray-400)', marginTop: 4 }}>
            {data.sub.saldo_final < 0 ? '⚠ Saldo negativo' : '● Disponible'}
          </div>
          {!data.cuenta.activo && <div style={{ fontSize: 11, color: 'var(--red-500)', marginTop: 4, fontWeight: 700 }}>Cuenta inactiva</div>}
        </div>
      </div>
    </div>
  )

  // ── Movimientos (subdiario con saldo corrido) ──
  const tabMovimientos = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr>
          <th>Fecha</th><th>Comprobante</th><th>Tipo</th><th>Concepto</th>
          <th className="th-right">Entrada</th><th className="th-right">Salida</th><th className="th-right">Saldo</th><th></th>
        </tr></thead>
        <tbody>
          {data.sub.movimientos.length === 0
            ? <tr><td colSpan={8} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin movimientos</td></tr>
            : data.sub.movimientos.map(m => (
              <tr key={m.id} style={{ opacity: m.anulado ? 0.5 : 1 }}>
                <td>{fFecha(m.fecha)}</td>
                <td><span className="code">{m.numero || `#${m.id}`}</span></td>
                <td style={{ fontSize: 12 }}>{m.tipo_descripcion}</td>
                <td style={{ fontSize: 12, color: 'var(--gray-600)' }}>{m.concepto || '—'}</td>
                <td className="td-right" style={{ color: m.signo === 1 ? '#10b981' : 'var(--gray-300)' }}>{m.signo === 1 ? $ar(m.monto) : '—'}</td>
                <td className="td-right" style={{ color: m.signo === -1 ? 'var(--red-500)' : 'var(--gray-300)' }}>{m.signo === -1 ? $ar(m.monto) : '—'}</td>
                <td className="td-right" style={{ fontWeight: 700, color: +m.saldo_corrido < 0 ? 'var(--red-500)' : 'var(--gray-700)' }}>{$ar(m.saldo_corrido)}</td>
                <td>{btnVer(() => abrirMov(m))}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  // ── Cheques de terceros (movimientos origen='cheque' por esta cuenta) ──
  const tabChequesTerceros = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr>
          <th>Fecha</th><th>Comprobante</th><th>Concepto</th><th className="th-right">Monto</th><th></th>
        </tr></thead>
        <tbody>
          {chequesTerceros.length === 0
            ? <tr><td colSpan={5} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin cheques de terceros por esta cuenta</td></tr>
            : chequesTerceros.map(m => (
              <tr key={m.id} style={{ opacity: m.anulado ? 0.5 : 1 }}>
                <td>{fFecha(m.fecha)}</td>
                <td><span className="code">{m.numero || `#${m.id}`}</span></td>
                <td style={{ fontSize: 12, color: 'var(--gray-600)' }}>{m.concepto || '—'}</td>
                <td className="td-right td-bold" style={{ color: m.signo === 1 ? '#10b981' : 'var(--red-500)' }}>{m.signo === -1 ? '− ' : ''}{$ar(m.monto)}</td>
                <td style={{ display: 'flex', gap: 6 }}>
                  {btnVer(() => abrirMov(m))}
                  {m.referencia_id != null && m.referencia_tipo === 'cheques' && (
                    <button className="btn btn-ghost btn-xs" onClick={() => setPdf({ url: pdfUrl.cheque(m.referencia_id), titulo: `Cheque ${m.referencia_id}` })}>📄</button>
                  )}
                </td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  // ── Cheques propios (emitidos desde esta cuenta) ──
  const tabChequesPropios = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr>
          <th>Número</th><th>Fecha pago</th><th>Beneficiario</th><th>Tipo</th><th>Estado</th><th className="th-right">Monto</th><th></th>
        </tr></thead>
        <tbody>
          {chequesPropios.length === 0
            ? <tr><td colSpan={7} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin cheques propios emitidos desde esta cuenta</td></tr>
            : chequesPropios.map(c => {
              const e = ESTADO_CHEQUE[c.estado] || { bg: 'var(--gray-100)', color: 'var(--gray-600)', label: c.estado }
              return (
                <tr key={`p${c.id}`}>
                  <td><span className="code" style={{ fontWeight: 700 }}>{c.numero}</span></td>
                  <td>{fFecha(c.fecha_venc)}</td>
                  <td style={{ fontSize: 12 }}>{c.entidad || '—'}</td>
                  <td style={{ fontSize: 12 }}>{c.tipo === 'echeq' ? 'E-Cheq' : 'Físico'}</td>
                  <td>{chip(e.bg, e.color, e.label)}</td>
                  <td className="td-right td-bold">{$ar(c.monto)}</td>
                  <td><button className="btn btn-ghost btn-xs" onClick={() => setPdf({ url: pdfUrl.chequePropio(c.id), titulo: `Cheque propio ${c.numero}` })}>📄</button></td>
                </tr>
              )
            })}
        </tbody>
      </table>
    </div>
  )

  // ── Transferencias (patas que tocan esta cuenta) ──
  const tabTransferencias = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr>
          <th>Fecha</th><th>Comprobante</th><th>Dirección</th><th>Concepto</th><th className="th-right">Monto</th><th></th>
        </tr></thead>
        <tbody>
          {transferencias.length === 0
            ? <tr><td colSpan={6} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin transferencias</td></tr>
            : transferencias.map(m => (
              <tr key={m.id} style={{ opacity: m.anulado ? 0.5 : 1 }}>
                <td>{fFecha(m.fecha)}</td>
                <td><span className="code">{m.numero || `#${m.id}`}</span></td>
                <td>{m.signo === 1 ? chip('#d1fae5', '#065f46', '▲ Recibida') : chip('#fee2e2', '#991b1b', '▼ Enviada')}</td>
                <td style={{ fontSize: 12, color: 'var(--gray-600)' }}>{m.concepto || '—'}</td>
                <td className="td-right td-bold" style={{ color: m.signo === 1 ? '#10b981' : 'var(--red-500)' }}>{m.signo === -1 ? '− ' : ''}{$ar(m.monto)}</td>
                <td>{btnVer(() => abrirMov(m))}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  // ── Comprobantes (todos los movimientos de la cuenta) ──
  const tabComprobantes = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr>
          <th>Fecha</th><th>Comprobante</th><th>Tipo</th><th>Concepto</th>
          <th className="th-right">Entrada</th><th className="th-right">Salida</th><th>Estado</th><th></th>
        </tr></thead>
        <tbody>
          {data.movimientos.length === 0
            ? <tr><td colSpan={8} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin comprobantes</td></tr>
            : data.movimientos.map(m => (
              <tr key={m.id} style={{ opacity: m.anulado ? 0.5 : 1 }}>
                <td>{fFecha(m.fecha)}</td>
                <td><span className="code">{m.numero || `#${m.id}`}</span></td>
                <td style={{ fontSize: 12 }}>{m.tipo_descripcion}</td>
                <td style={{ fontSize: 12, color: 'var(--gray-600)' }}>{m.concepto || '—'}</td>
                <td className="td-right" style={{ color: m.signo === 1 ? '#10b981' : 'var(--gray-300)' }}>{m.signo === 1 ? $ar(m.monto) : '—'}</td>
                <td className="td-right" style={{ color: m.signo === -1 ? 'var(--red-500)' : 'var(--gray-300)' }}>{m.signo === -1 ? $ar(m.monto) : '—'}</td>
                <td>
                  {m.anulado
                    ? <span className="badge badge-anulada">Anulado</span>
                    : m.conciliado ? <span className="badge badge-cobrada">Conciliado</span> : <span className="badge badge-pendiente">Vigente</span>}
                </td>
                <td>{btnVer(() => abrirMov(m))}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  // ── Conciliación ──
  const tabConciliacion = () => (
    <div className="tbl-wrap">
      <table>
        <thead><tr>
          <th>#</th><th>Desde</th><th>Hasta</th><th className="th-right">Saldo extracto</th><th>Estado</th>
        </tr></thead>
        <tbody>
          {data.conciliaciones.length === 0
            ? <tr><td colSpan={5} style={{ textAlign: 'center', padding: 40, color: 'var(--gray-400)' }}>Sin conciliaciones</td></tr>
            : data.conciliaciones.map(c => (
              <tr key={c.id}>
                <td><span className="code">#{c.id}</span></td>
                <td>{fFecha(c.desde)}</td>
                <td>{fFecha(c.hasta)}</td>
                <td className="td-right td-bold">{$ar(c.saldo_extracto)}</td>
                <td>{c.estado === 'cerrada' ? chip('#d1fae5', '#065f46', 'Cerrada') : chip('#fef3c7', '#92400e', 'Abierta')}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )

  const tabContabilidad = () => (
    <div className="card" style={{ textAlign: 'center', padding: '48px 20px', color: 'var(--gray-400)' }}>
      <div style={{ fontSize: 34, marginBottom: 10 }}>🔒</div>
      <p style={{ fontSize: 14 }}>Imputación contable — bloqueado hasta Fase E</p>
    </div>
  )

  const tabs = data ? [
    { id: 'movimientos',  label: '📖 Movimientos',  count: data.sub.movimientos.length, render: tabMovimientos },
    { id: 'chq_terceros', label: '💳 Cheques terceros', count: chequesTerceros.length, render: tabChequesTerceros },
    { id: 'chq_propios',  label: '🖊️ Cheques propios',  count: chequesPropios.length,  render: tabChequesPropios },
    { id: 'transfer',     label: '🔀 Transferencias',   count: transferencias.length,  render: tabTransferencias },
    { id: 'comprobantes', label: '🧾 Comprobantes',     count: data.movimientos.length, render: tabComprobantes },
    { id: 'concil',       label: '⚖️ Conciliación',     count: data.conciliaciones.length, render: tabConciliacion },
    { id: 'contab',       label: '📚 Contabilidad',     render: tabContabilidad },
  ] : []

  return (
    <>
      <Consulta360
        entities={cuentas}
        selId={selId}
        onSelect={setSelId}
        searchPlaceholder="Buscar cuenta…"
        emptyIcon="🏛️"
        emptyText="Seleccione una cuenta para ver su ficha completa"
        loading={loading}
        data={data}
        header={header}
        tabs={tabs}
        getLabel={(c) => c.descripcion}
        getSubtitle={(c) => c.banco || CLASE_LABEL[c.clase] || c.clase}
        matchFn={(c, s) => {
          const q = s.toLowerCase()
          return (c.descripcion || '').toLowerCase().includes(q) || (c.banco || '').toLowerCase().includes(q)
        }}
      />
      {mov && <MovimientoDetalle mov={mov} onClose={() => setMov(null)} />}
      {pdf && <PDFModal url={pdf.url} titulo={pdf.titulo} onClose={() => setPdf(null)} />}
    </>
  )
}
