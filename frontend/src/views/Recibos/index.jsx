// src/views/Recibos/index.jsx
import { useState, useEffect } from 'react'
import { useListaPaginada, POR_PAGINA } from '../../hooks/useListaPaginada'
import { RecibosAPI, ClientesAPI } from '../../api'
import { $ar, fFecha, fDoc } from '../../utils'
import { Loading, EmptyState, Modal, Paginador } from '../../components/UI'
import ReciboForm from '../../components/Forms/ReciboForm'
import PDFModal from '../../components/PDFModal'
import toast from 'react-hot-toast'

const TIPO_LABEL = { efectivo: 'Caja', transferencia: 'Transferencia', cheque: 'Cheque físico', echeq: 'E-Cheq' }
const TIPO_COLOR = { efectivo: 'var(--green-600)', transferencia: 'var(--blue-600)', cheque: 'var(--purple-600)', echeq: 'var(--orange-500)' }

export default function Recibos() {
  const [clientes, setClientes] = useState([])
  const [search, setSearch]     = useState('')
  const [filtroCli, setFiltroCli] = useState('')
  const [nuevo, setNuevo]       = useState(false)
  const [detalle, setDetalle]   = useState(null)
  const [pdfModal, setPdfModal] = useState(null)
  const [certificado, setCertificado] = useState(null)
  const [guardandoCertificado, setGuardandoCertificado] = useState(false)

  const { rows, total, totalImporte, loading, pagina, setPagina, recargar: load } =
    useListaPaginada(RecibosAPI.list, { q: search, cliente_id: filtroCli })
  useEffect(() => { ClientesAPI.list().then(setClientes) }, [])

  const save = async (payload) => {
    const r = await RecibosAPI.create(payload)
    toast.success(r?.numero ? `Recibo ${r.numero} registrado` : 'Recibo registrado correctamente')
    setNuevo(false)
    load()
  }

  const openDetalle = (id) => RecibosAPI.get(id).then(setDetalle)

  const guardarCertificado = async () => {
    setGuardandoCertificado(true)
    try {
      const actualizado = await RecibosAPI.completarCertificado(certificado)
      setDetalle(d => ({ ...d, retenciones: d.retenciones.map(r => r.id === actualizado.id ? actualizado : r) }))
      setCertificado(null)
      load()
      toast.success('Certificado registrado')
    } catch { /* La API muestra el error y el formulario del certificado queda abierto. */
    } finally {
      setGuardandoCertificado(false)
    }
  }


  return (
    <div>
      <div className="page-toolbar">
        <div className="toolbar-left">
          <input className="search-inp" placeholder="Buscar recibo o cliente…" value={search} onChange={e => setSearch(e.target.value)} />
          <select className="sel" style={{ width: 220 }} value={filtroCli} onChange={e => setFiltroCli(e.target.value)}>
            <option value="">Todos los clientes</option>
            {clientes.map(c => <option key={c.id} value={c.id}>{c.razon_social}</option>)}
          </select>
        </div>
        <button className="btn btn-success" onClick={() => setNuevo(true)}>+ Nuevo recibo de cobro</button>
      </div>

      {/* Resumen rápido */}
      {rows.length > 0 && (
        <div style={{ display: 'flex', gap: 12, marginBottom: 16, flexWrap: 'wrap' }}>
          <div className="card" style={{ padding: '12px 18px', borderLeft: '4px solid var(--green-600)', flex: 1, minWidth: 180 }}>
            <div className="kpi-label">Total de recibos (incluye retenciones)</div>
            <div className="kpi-value" style={{ color: 'var(--green-600)', fontSize: 20 }}>{$ar(totalImporte)}</div>
          </div>
          <div className="card" style={{ padding: '12px 18px', borderLeft: '4px solid var(--blue-600)', flex: 1, minWidth: 180 }}>
            <div className="kpi-label">Cantidad de recibos</div>
            <div className="kpi-value" style={{ color: 'var(--blue-600)', fontSize: 20 }}>{total.toLocaleString('es-AR')}</div>
          </div>
        </div>
      )}

      <div className="tbl-wrap">
        {loading ? <Loading /> : (
          <table>
            <thead>
              <tr>
                <th>Número</th><th>Fecha</th><th>Cliente</th>
                <th>Facturas imputadas</th><th>Medios de cobro</th>
                <th className="th-right">Total del recibo</th><th style={{ width: 80 }}></th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0
                ? <EmptyState icon="💵" message="Sin recibos registrados" />
                : rows.map(r => (
                  <tr key={r.id}>
                    <td><span className="code" style={{ fontWeight: 700 }}>{r.numero}</span></td>
                    <td>{fFecha(r.fecha)}</td>
                    <td className="td-bold">{r.razon_social}</td>
                    <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>
                      {r.facturas?.length > 0
                        ? r.facturas.map(f => <span key={f.factura_id} className="code" style={{ marginRight: 4 }}>{f.numero}</span>)
                        : <span style={{ color: 'var(--amber-600)' }}>Pago a cuenta</span>
                      }
                    </td>
                    <td>
                      <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
                        {r.medios?.map((m, i) => (
                          <span key={i} style={{ background: `${TIPO_COLOR[m.tipo]}18`, color: TIPO_COLOR[m.tipo], padding: '2px 8px', borderRadius: 10, fontSize: 11, fontWeight: 700 }}>
                            {TIPO_LABEL[m.tipo]}{m.detalle ? ` · ${m.detalle}` : ''} {$ar(m.monto)}
                          </span>
                        ))}
                        {r.retenciones?.map((ret, i) => (
                          <span key={`ret-${i}`} style={{ background: 'var(--amber-100)', color: 'var(--amber-700)', padding: '2px 8px', borderRadius: 10, fontSize: 11, fontWeight: 700 }}>
                            Ret. {ret.tipo_retencion}{ret.pendiente_documentacion ? ' · certificado pendiente' : ''} {$ar(ret.monto)}
                          </span>
                        ))}
                      </div>
                    </td>
                    <td className="td-right" style={{ color: 'var(--green-600)', fontWeight: 700, fontSize: 14 }}>{$ar(r.total)}</td>
                    <td><div style={{ display: 'flex', gap: 4 }}>
                      <button className="btn btn-ghost btn-xs" onClick={() => openDetalle(r.id)}>Ver</button>
                      <button className="btn btn-secondary btn-xs" style={{ background: 'var(--red-50)', color: 'var(--red-600)', borderColor: 'var(--red-100)' }} onClick={() => setPdfModal({ url: `/api/pdf/recibo/${r.id}`, titulo: `Recibo ${r.numero}` })}>📄 PDF</button>
                    </div></td>
                  </tr>
                ))
              }
            </tbody>
          </table>
        )}
        <Paginador pagina={pagina} total={total} porPagina={POR_PAGINA} onChange={setPagina} disabled={loading} />
      </div>

      {nuevo && (
        <ReciboForm
          clientes={clientes}
          initial={{}}
          onSave={save}
          onClose={() => setNuevo(false)}
        />
      )}

      {detalle && (
        <Modal title={`Recibo ${detalle.numero}`} size="md" onClose={() => { setDetalle(null); setCertificado(null) }}
          footer={
            <div style={{ display: 'flex', gap: 8, width: '100%', justifyContent: 'space-between', alignItems: 'center' }}>
              <button
                className="btn btn-secondary btn-sm"
                style={{ background: 'var(--red-50)', color: 'var(--red-600)', borderColor: 'var(--red-100)' }}
                onClick={() => { setDetalle(null); setPdfModal({ url: `/api/pdf/recibo/${detalle.id}`, titulo: `Recibo ${detalle.numero}` }) }}
              >
                📄 Ver / Imprimir PDF
              </button>
              <button className="btn btn-secondary" onClick={() => setDetalle(null)}>Cerrar</button>
            </div>
          }
        >
          <div className="form-row2" style={{ marginBottom: 16 }}>
            <div><span className="lbl">Fecha</span><p>{fFecha(detalle.fecha)}</p></div>
            <div><span className="lbl">Cliente</span><p className="td-bold">{detalle.razon_social}</p></div>
            <div><span className="lbl">Documento</span><p className="td-mono">{fDoc(detalle.doc_tipo, detalle.doc_nro)}</p></div>
            <div><span className="lbl">Observaciones</span><p style={{ color: 'var(--gray-500)', fontSize: 12 }}>{detalle.observaciones || '—'}</p></div>
          </div>

          {detalle.facturas?.length > 0 && (
            <>
              <div className="lbl" style={{ marginBottom: 8 }}>Facturas imputadas</div>
              <div style={{ border: '1px solid var(--gray-200)', borderRadius: 8, overflow: 'hidden', marginBottom: 14 }}>
                {detalle.facturas.map(f => (
                  <div key={f.factura_id} style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 14px', borderBottom: '1px solid var(--gray-100)' }}>
                    <span className="code">{f.numero}</span>
                    {f.importe != null && <strong>{$ar(f.importe)}</strong>}
                  </div>
                ))}
              </div>
            </>
          )}

          <div className="lbl" style={{ marginBottom: 8 }}>Medios de cobro</div>
          {detalle.medios?.map((m, i) => (
            <div key={i} className="medio-card" style={{ marginBottom: 8 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span style={{ fontWeight: 700, color: TIPO_COLOR[m.tipo] }}>{TIPO_LABEL[m.tipo]}</span>
                <span style={{ fontSize: 16, fontWeight: 800 }}>{$ar(m.monto)}</span>
              </div>
              {m.detalle && <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 4 }}>{m.detalle}</div>}
              {m.banco && (
                <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 4 }}>
                  Banco: {m.banco}{m.numero_cheque ? ` — Nro. ${m.numero_cheque}` : ''}{m.titular ? ` — Titular: ${m.titular}` : ''}
                  {m.fecha_vcto ? ` — Vence: ${fFecha(m.fecha_vcto)}` : ''}
                </div>
              )}
            </div>
          ))}

          {detalle.retenciones?.length > 0 && <>
            <div className="lbl" style={{ margin: '16px 0 8px' }}>Retenciones sufridas</div>
            {detalle.retenciones.map(ret => (
              <div key={ret.id} className="medio-card" style={{ marginBottom: 8 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12 }}>
                  <strong>{ret.tipo_retencion}{ret.jurisdiccion ? ` · ${ret.jurisdiccion}` : ''}</strong>
                  <strong>{$ar(ret.monto)}</strong>
                </div>
                <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 4 }}>
                  {ret.pendiente_documentacion
                    ? `Registro histórico · certificado pendiente · ${ret.detalle_origen || 'sin detalle original'} · CUIT agente ${ret.cuit_agente}`
                    : `Certificado ${ret.numero_certificado}${ret.codigo_regimen ? ` · Régimen ${ret.codigo_regimen}` : ''} · ${fFecha(ret.fecha)} · CUIT agente ${ret.cuit_agente}`}
                </div>
              {ret.pendiente_documentacion && certificado?.id !== ret.id &&
                <button className="btn btn-secondary btn-sm" style={{ marginTop: 8 }} onClick={() => setCertificado({ id: ret.id, tipo_retencion: ret.tipo_retencion, numero_certificado: '', fecha: '', codigo_regimen: '', jurisdiccion: '' })}>
                  Completar certificado
                </button>}
              {certificado?.id === ret.id && <div style={{ marginTop: 10 }}>
                <div className="form-row2">
                  <label><span className="lbl">Impuesto</span><select className="sel" value={certificado.tipo_retencion} onChange={e => setCertificado(c => ({ ...c, tipo_retencion: e.target.value }))}>
                    {['Ganancias', 'IVA', 'IIBB', 'SUSS'].map(t => <option key={t} value={t}>{t}</option>)}
                  </select></label>
                  <label><span className="lbl">Número de certificado</span><input className="inp" value={certificado.numero_certificado} onChange={e => setCertificado(c => ({ ...c, numero_certificado: e.target.value }))} /></label>
                  <label><span className="lbl">Fecha del certificado</span><input className="inp" type="date" value={certificado.fecha} onChange={e => setCertificado(c => ({ ...c, fecha: e.target.value }))} /></label>
                  <label><span className="lbl">Código de régimen</span><input className="inp" value={certificado.codigo_regimen} onChange={e => setCertificado(c => ({ ...c, codigo_regimen: e.target.value }))} /></label>
                  {certificado.tipo_retencion === 'IIBB' && <label><span className="lbl">Jurisdicción</span><input className="inp" value={certificado.jurisdiccion} onChange={e => setCertificado(c => ({ ...c, jurisdiccion: e.target.value }))} /></label>}
                </div>
                <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
                  <button className="btn btn-success btn-sm" disabled={guardandoCertificado} onClick={guardarCertificado}>Guardar certificado</button>
                  <button className="btn btn-secondary btn-sm" disabled={guardandoCertificado} onClick={() => setCertificado(null)}>Cancelar</button>
                </div>
              </div>}
              </div>
            ))}
          </>}

          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '12px 0 0', borderTop: '2px solid var(--gray-200)', marginTop: 8 }}>
            <span style={{ fontWeight: 700, fontSize: 15 }}>Total del recibo:</span>
            <span style={{ fontSize: 20, fontWeight: 800, color: 'var(--green-600)' }}>{$ar(detalle.total)}</span>
          </div>
        </Modal>
      )}
      {pdfModal && <PDFModal url={pdfModal.url} titulo={pdfModal.titulo} onClose={() => setPdfModal(null)} />}
    </div>
  )
}
