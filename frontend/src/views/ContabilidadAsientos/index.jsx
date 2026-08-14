// src/views/ContabilidadAsientos/index.jsx
// Listado + alta manual de asientos contables (Fase E). El listado sale de informe_libro_diario
// (cabecera + líneas + totales), que sólo devuelve asientos 'confirmado' — por eso un asiento
// anulado desaparece de la grilla en vez de mostrarse tachado.
// La generación automática desde comprobantes (generar_asiento_desde_*) sigue bloqueada en la
// matriz de imputación, así que acá sólo hay alta manual.
import { useState, useEffect, useCallback, Fragment } from 'react'
import { AsientosAPI, PlanCuentasAPI } from '../../api'
import { $ar, fFecha, hoy } from '../../utils'
import { Loading, EmptyState } from '../../components/UI'
import AsientoForm from '../../components/Forms/AsientoForm'
import toast from 'react-hot-toast'

const primerDiaMes = () => {
  const d = new Date(); d.setDate(1)
  return d.toISOString().split('T')[0]
}

export default function ContabilidadAsientos() {
  const [data, setData]       = useState(null)
  const [cuentas, setCuentas] = useState([])
  const [loading, setLoading] = useState(true)
  const [desde, setDesde]     = useState(primerDiaMes())
  const [hasta, setHasta]     = useState(hoy())
  const [showForm, setShowForm] = useState(false)
  const [abierto, setAbierto] = useState(null)   // id del asiento con las líneas desplegadas

  const load = useCallback(() => {
    setLoading(true)
    AsientosAPI.list({ desde, hasta }).then(setData).finally(() => setLoading(false))
  }, [desde, hasta])

  useEffect(() => { load() }, [load])
  // Sólo las cuentas imputables y activas pueden recibir líneas (lo valida crear_asiento).
  useEffect(() => { PlanCuentasAPI.list({ imputable: true, activo: true }).then(setCuentas) }, [])

  const anular = async (a) => {
    try {
      await AsientosAPI.anular(a.id)
      toast.success(`Asiento N° ${a.numero} anulado`)
      load()
    } catch {}
  }

  const asientos = data?.asientos || []
  const totales  = data?.totales  || { cantidad: 0, debe: 0, haber: 0 }

  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left" style={{ display: 'flex', gap: 10, alignItems: 'flex-end', flexWrap: 'wrap' }}>
          <div>
            <label className="lbl">Desde</label>
            <input type="date" className="inp" style={{ width: 150 }} value={desde} onChange={e => setDesde(e.target.value)} />
          </div>
          <div>
            <label className="lbl">Hasta</label>
            <input type="date" className="inp" style={{ width: 150 }} value={hasta} onChange={e => setHasta(e.target.value)} />
          </div>
        </div>
        <button className="btn btn-primary" onClick={() => setShowForm(true)}>+ Nuevo asiento</button>
      </div>

      {/* Totales del período */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 14, marginBottom: 20 }}>
        {[
          { label: 'Asientos',    val: totales.cantidad ?? 0,      color: 'var(--gray-700)' },
          { label: 'Total debe',  val: $ar(totales.debe  || 0),    color: 'var(--blue-600)' },
          { label: 'Total haber', val: $ar(totales.haber || 0),    color: 'var(--green-600)' },
        ].map(k => (
          <div key={k.label} className="card" style={{ padding: '12px 16px' }}>
            <div className="kpi-label">{k.label}</div>
            <div className="kpi-value" style={{ color: k.color, fontSize: 17, margin: '5px 0 0' }}>{k.val}</div>
          </div>
        ))}
      </div>

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th style={{ width: 90 }}>N°</th><th style={{ width: 110 }}>Fecha</th>
                <th>Descripción</th><th style={{ width: 100 }}>Origen</th>
                <th className="th-right" style={{ width: 130 }}>Debe</th>
                <th className="th-right" style={{ width: 130 }}>Haber</th>
                <th style={{ width: 150 }}></th>
              </tr>
            </thead>
            <tbody>
              {asientos.length === 0 ? <EmptyState icon="📘" message="Sin asientos confirmados en el período" /> : asientos.map(a => (
                <Fragment key={a.id}>
                  <tr>
                    <td><span className="code" style={{ fontWeight: 700 }}>{a.numero}</span></td>
                    <td>{fFecha(a.fecha)}</td>
                    <td className="td-bold">{a.descripcion}</td>
                    <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{a.origen}</td>
                    <td className="td-right">{$ar(a.total_debe || 0)}</td>
                    <td className="td-right">{$ar(a.total_haber || 0)}</td>
                    <td style={{ whiteSpace: 'nowrap' }}>
                      <button className="btn btn-ghost btn-sm" onClick={() => setAbierto(abierto === a.id ? null : a.id)}>
                        {abierto === a.id ? 'Ocultar' : 'Ver'}
                      </button>
                      <button className="btn btn-ghost btn-sm" style={{ color: 'var(--red-500)' }} onClick={() => anular(a)}>
                        Anular
                      </button>
                    </td>
                  </tr>
                  {abierto === a.id && (
                    <tr>
                      <td colSpan={7} style={{ background: 'var(--gray-50, #f9fafb)', padding: '10px 16px' }}>
                        <table style={{ width: '100%' }}>
                          <thead>
                            <tr>
                              <th style={{ width: 160 }}>Cuenta</th><th>Descripción</th><th>Detalle</th>
                              <th className="th-right" style={{ width: 130 }}>Debe</th>
                              <th className="th-right" style={{ width: 130 }}>Haber</th>
                            </tr>
                          </thead>
                          <tbody>
                            {(a.lineas || []).map((l, i) => (
                              <tr key={i}>
                                <td><span className="code">{l.codigo}</span></td>
                                <td>{l.cuenta}</td>
                                <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{l.detalle || '—'}</td>
                                <td className="td-right">{Number(l.debe)  > 0 ? $ar(l.debe)  : ''}</td>
                                <td className="td-right">{Number(l.haber) > 0 ? $ar(l.haber) : ''}</td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      </td>
                    </tr>
                  )}
                </Fragment>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {showForm && (
        <AsientoForm
          cuentas={cuentas}
          onClose={() => setShowForm(false)}
          onSaved={load}
        />
      )}
    </div>
  )
}
