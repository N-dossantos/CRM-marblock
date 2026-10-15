// src/components/Consultas/VentaDetalle.jsx
// Modal de detalle SÓLO LECTURA de un comprobante de VENTA (factura / remito / nota / recibo /
// presupuesto), para el módulo Consultas (Fase B). Recibe el row de *_list; `doc._doc` marca el
// tipo. A diferencia de Compras, Ventas sí tiene PDF (Edge Function): botón "📄 PDF" → PDFModal.
import { useState } from 'react'
import { Modal, Badge } from '../UI'
import PDFModal from '../PDFModal'
import { pdfUrl } from '../../api'
import { $ar, fFecha, fDoc } from '../../utils'

const DOC_LABEL = {
  factura:     'Factura',
  remito:      'Remito',
  nota:        'Nota',
  recibo:      'Recibo',
  presupuesto: 'Presupuesto',
}

const MEDIO_LABEL = {
  efectivo:       'Efectivo',
  transferencia:  'Transferencia',
  cheque:         'Cheque físico',
  cheque_fisico:  'Cheque físico',
  echeq:          'E-Cheq',
}

function Field({ label, children }) {
  return (
    <div style={{ minWidth: 110 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>{label}</div>
      <div style={{ fontSize: 13, color: 'var(--gray-800)', marginTop: 2 }}>{children ?? '—'}</div>
    </div>
  )
}

function ItemsVenta({ items = [] }) {
  return (
    <div className="tbl-wrap" style={{ boxShadow: 'none', border: '1px solid var(--gray-200)' }}>
      <table>
        <thead>
          <tr>
            <th>Código</th><th>Descripción</th>
            <th className="th-right">Cant.</th><th className="th-right">Precio</th>
            <th className="th-right">Dto%</th><th className="th-right">Subtotal</th>
          </tr>
        </thead>
        <tbody>
          {items.length === 0
            ? <tr><td colSpan={6} style={{ textAlign: 'center', padding: 24, color: 'var(--gray-400)' }}>Sin ítems</td></tr>
            : items.map((it, i) => (
              <tr key={it.id ?? i}>
                <td><span className="code">{it.codigo || '—'}</span></td>
                <td>{it.descripcion}</td>
                <td className="td-right">{it.cantidad}</td>
                <td className="td-right">{$ar(it.precio_unitario)}</td>
                <td className="td-right">{(+it.descuento_item || 0)}%</td>
                <td className="td-right td-bold">{$ar(it.subtotal)}</td>
              </tr>
            ))}
        </tbody>
      </table>
    </div>
  )
}

function TotalesLineas({ lineas }) {
  return (
    <div className="totales-box" style={{ marginTop: 14, marginLeft: 'auto', maxWidth: 320 }}>
      {lineas.map(([label, val, opts = {}], i) => (
        <div className={`totales-row${opts.total ? ' total' : ''}`} key={i}>
          <span>{label}</span>
          <span className={opts.total ? 'val' : ''} style={opts.color ? { color: opts.color } : undefined}>{val}</span>
        </div>
      ))}
    </div>
  )
}

// El IVA de una factura puede venir de varias alícuotas (Fase F/WS3a): se rotula con las tasas de
// sus renglones; el importe es el guardado (`iva_monto`), no se recalcula acá.
const rotuloIva = (items = []) => {
  const tasas = [...new Set(items.map(it => +it.iva_porcentaje).filter(p => !Number.isNaN(p)))].sort((a, b) => a - b)
  return tasas.length ? `IVA ${tasas.join(' / ')}%` : 'IVA'
}

// `acciones`: botones extra para el pie (p. ej. NC/ND y Anular desde el listado de Facturas).
export default function VentaDetalle({ doc, onClose, acciones = null }) {
  const [pdf, setPdf] = useState(null)
  if (!doc) return null
  const tipoDoc = doc._doc
  const titulo = `${DOC_LABEL[tipoDoc] || 'Comprobante'} ${doc.numero || ''}`

  const pdfBuilder = pdfUrl[tipoDoc]
  const abrirPdf = () => pdfBuilder && setPdf({ url: pdfBuilder(doc.id), titulo })

  return (
    <>
      <Modal
        title={titulo}
        size="lg"
        onClose={onClose}
        footer={(pdfBuilder || acciones) && (
          <>
            {acciones}
            {pdfBuilder && (
              <button
                className="btn btn-secondary btn-sm"
                style={{ background: 'var(--red-50)', color: 'var(--red-600)', borderColor: 'var(--red-100)' }}
                onClick={abrirPdf}
              >
                📄 Ver PDF
              </button>
            )}
          </>
        )}
      >
        {/* Cabecera común: cliente */}
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', paddingBottom: 12, marginBottom: 14, borderBottom: '1px solid var(--gray-100)' }}>
          <div>
            <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--gray-800)' }}>{doc.razon_social}</div>
            {doc.doc_nro && <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 2 }}>{fDoc(doc.doc_tipo, doc.doc_nro)}</div>}
          </div>
          <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
            <Field label="Fecha">{fFecha(doc.fecha)}</Field>
            {tipoDoc === 'presupuesto' && <Field label="Vence">{fFecha(doc.fecha_vcto)}</Field>}
            {(tipoDoc === 'factura' || tipoDoc === 'remito' || tipoDoc === 'presupuesto') && (
              <Field label="Estado"><Badge estado={doc.estado} /></Field>
            )}
          </div>
        </div>

        {/* FACTURA */}
        {tipoDoc === 'factura' && (
          <>
            <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', marginBottom: 14 }}>
              <Field label="Tipo"><span className={`badge badge-${doc.tipo}`}>Fac {doc.tipo}</span></Field>
              <Field label={doc.remitos?.length > 1 ? 'Remitos vinc.' : 'Remito vinc.'}>
                {doc.remitos?.length ? doc.remitos.map(r => r.numero).join(', ') : (doc.remito_numero || '—')}
              </Field>
              {doc.observaciones && <Field label="Observaciones">{doc.observaciones}</Field>}
            </div>
            <ItemsVenta items={doc.items || []} />
            <TotalesLineas lineas={[
              ...(doc.subtotal != null ? [['Subtotal s/IVA', $ar(doc.subtotal)]] : []),
              ...(+doc.descuento_monto > 0 ? [[`Descuento ${doc.descuento_general}%`, `— ${$ar(doc.descuento_monto)}`, { color: 'var(--red-500)' }]] : []),
              ['Neto gravado', $ar(doc.neto_gravado)],
              [rotuloIva(doc.items), $ar(doc.iva_monto)],
              ...(+doc.percepciones_monto > 0 ? [['Percepciones', $ar(doc.percepciones_monto)]] : []),
              ['TOTAL', $ar(doc.total), { total: true }],
            ]} />
          </>
        )}

        {/* REMITO */}
        {tipoDoc === 'remito' && (
          <>
            <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', marginBottom: 14 }}>
              <Field label="Factura vinc.">{doc.factura_numero || '—'}</Field>
            </div>
            <ItemsVenta items={doc.items || []} />
          </>
        )}

        {/* NOTA */}
        {tipoDoc === 'nota' && (
          <>
            <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', marginBottom: 14 }}>
              <Field label="Tipo"><Badge estado={doc.tipo} /></Field>
              <Field label="Factura vinc.">{doc.factura_numero || '—'}</Field>
              <Field label="Motivo">{doc.motivo || '—'}</Field>
            </div>
            <ItemsVenta items={doc.items || []} />
            <TotalesLineas lineas={[
              ['Neto gravado', $ar(doc.neto_gravado)],
              [rotuloIva(doc.items), $ar(doc.iva_monto)],
              ['TOTAL', $ar(doc.total), { total: true }],
            ]} />
          </>
        )}

        {/* PRESUPUESTO */}
        {tipoDoc === 'presupuesto' && (
          <>
            <ItemsVenta items={doc.items || []} />
            <TotalesLineas lineas={[
              ...(+doc.descuento_general > 0 ? [[`Descuento ${doc.descuento_general}%`, '', {}]] : []),
              ['TOTAL', $ar(doc.total), { total: true }],
            ]} />
          </>
        )}

        {/* RECIBO */}
        {tipoDoc === 'recibo' && (
          <>
            <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', marginBottom: 14 }}>
              <Field label="Total cobrado"><b>{$ar(doc.total)}</b></Field>
            </div>

            <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--gray-600)', margin: '4px 0 6px' }}>Facturas imputadas</div>
            {(doc.facturas || []).length === 0
              ? <div style={{ fontSize: 12, color: 'var(--gray-400)', marginBottom: 12 }}>Sin imputación (cobro a cuenta)</div>
              : (
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 12 }}>
                  {doc.facturas.map((f, i) => <span key={i} className="code">{f.numero || f.factura_numero || f.factura_id}</span>)}
                </div>
              )}

            <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--gray-600)', margin: '4px 0 6px' }}>Medios de cobro</div>
            <div className="tbl-wrap" style={{ boxShadow: 'none', border: '1px solid var(--gray-200)' }}>
              <table>
                <thead><tr><th>Medio</th><th>Detalle</th><th className="th-right">Monto</th></tr></thead>
                <tbody>
                  {(doc.medios || []).map((m, i) => (
                    <tr key={m.id ?? i}>
                      <td>{MEDIO_LABEL[m.tipo] || m.tipo}</td>
                      <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>
                        {m.detalle || [m.banco, m.numero_cheque].filter(Boolean).join(' · ') || '—'}
                      </td>
                      <td className="td-right td-bold">{$ar(m.monto)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}

        {doc.observaciones && (
          <div style={{ marginTop: 14, paddingTop: 12, borderTop: '1px solid var(--gray-100)', fontSize: 12, color: 'var(--gray-500)' }}>
            <b style={{ color: 'var(--gray-600)' }}>Observaciones:</b> {doc.observaciones}
          </div>
        )}
      </Modal>

      {pdf && <PDFModal url={pdf.url} titulo={pdf.titulo} onClose={() => setPdf(null)} />}
    </>
  )
}
