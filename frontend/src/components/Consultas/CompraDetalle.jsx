// src/components/Consultas/CompraDetalle.jsx
// Modal de detalle SÓLO LECTURA de un comprobante de COMPRA (factura / remito / nota / pago),
// para el módulo Consultas (Fase B). Recibe el row tal cual lo devuelve *_compra_list /
// pagos_proveedor_list; `doc._doc` marca el tipo. No edita nada — los ABM de Compras siguen
// siendo el único lugar de carga. Reutiliza Modal/Badge; sin PDF (los comprobantes son del proveedor).
import { Modal, Badge } from '../UI'
import { $ar, fFecha } from '../../utils'

const DOC_LABEL = {
  factura: 'Factura de compra',
  remito:  'Remito de compra',
  nota:    'Nota de compra',
  pago:    'Pago a proveedor',
}

const MEDIO_LABEL = {
  efectivo:       'Efectivo',
  transferencia:  'Transferencia',
  cheque_propio:  'Cheque propio',
  cheque_tercero: 'Cheque de tercero',
}

function Field({ label, children }) {
  return (
    <div style={{ minWidth: 120 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>{label}</div>
      <div style={{ fontSize: 13, color: 'var(--gray-800)', marginTop: 2 }}>{children ?? '—'}</div>
    </div>
  )
}

function ItemsCompra({ items = [], conAlicuota = false }) {
  const cols = conAlicuota ? 6 : 5
  return (
    <div className="tbl-wrap" style={{ boxShadow: 'none', border: '1px solid var(--gray-200)' }}>
      <table>
        <thead>
          <tr>
            <th>Descripción</th>
            <th className="th-right">Cant.</th>
            <th className="th-right">Precio</th>
            <th className="th-right">Dto%</th>
            {conAlicuota && <th className="th-right">IVA</th>}
            <th className="th-right">Subtotal</th>
          </tr>
        </thead>
        <tbody>
          {items.length === 0
            ? <tr><td colSpan={cols} style={{ textAlign: 'center', padding: 24, color: 'var(--gray-400)' }}>Sin ítems</td></tr>
            : items.map((it, i) => (
              <tr key={it.id ?? i}>
                <td>{it.descripcion}</td>
                <td className="td-right">{it.cantidad}</td>
                <td className="td-right">{$ar(it.precio_unitario)}</td>
                <td className="td-right">{(+it.descuento_item || 0)}%</td>
                {conAlicuota && <td className="td-right">{it.alicuota_porcentaje != null ? `${it.alicuota_porcentaje}%` : '—'}</td>}
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

export default function CompraDetalle({ doc, onClose }) {
  if (!doc) return null
  const tipoDoc = doc._doc
  const titulo = `${DOC_LABEL[tipoDoc] || 'Comprobante'} ${doc.numero || ''}`

  return (
    <Modal title={titulo} size="lg" onClose={onClose}>
      {/* Cabecera común: proveedor */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', paddingBottom: 12, marginBottom: 14, borderBottom: '1px solid var(--gray-100)' }}>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--gray-800)' }}>{doc.razon_social}</div>
          <div style={{ fontSize: 12, color: 'var(--gray-500)', marginTop: 2 }}>
            CUIT {doc.cuit}{doc.condicion_iva ? ` · ${doc.condicion_iva}` : ''}
          </div>
        </div>
        <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
          <Field label="Fecha">{fFecha(doc.fecha)}</Field>
          {tipoDoc === 'factura' && <Field label="Recepción">{fFecha(doc.fecha_recepcion)}</Field>}
          {(tipoDoc === 'factura' || tipoDoc === 'remito') && (
            <Field label="Estado"><Badge estado={doc.estado} /></Field>
          )}
        </div>
      </div>

      {/* FACTURA */}
      {tipoDoc === 'factura' && (
        <>
          <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', marginBottom: 14 }}>
            <Field label="Tipo"><span className={`badge badge-${doc.tipo}`}>Fac {doc.tipo}</span></Field>
            <Field label="Punto vta.">{doc.punto_venta}</Field>
            <Field label="Remito vinc.">{doc.remito_numero || '—'}</Field>
            <Field label="CAE">{doc.cae || '—'}</Field>
          </div>
          <ItemsCompra items={doc.items || []} conAlicuota />
          {(doc.iva_detalle || []).length > 0 && (
            <div style={{ marginTop: 12 }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--gray-600)', marginBottom: 6 }}>Desglose de IVA</div>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                {doc.iva_detalle.map((d, i) => (
                  <span key={i} style={{ background: 'var(--gray-100)', borderRadius: 8, padding: '4px 10px', fontSize: 12 }}>
                    <b>{d.porcentaje}%</b> · neto {$ar(d.neto_gravado)} · IVA {$ar(d.iva_monto)}
                  </span>
                ))}
              </div>
            </div>
          )}
          <TotalesLineas lineas={[
            ['Subtotal s/IVA', $ar(doc.subtotal)],
            ...(+doc.descuento_monto > 0 ? [[`Descuento ${doc.descuento_general}%`, `— ${$ar(doc.descuento_monto)}`, { color: 'var(--red-500)' }]] : []),
            ['Neto gravado', $ar(doc.neto_gravado)],
            ['IVA', $ar(doc.iva_monto)],
            ['TOTAL', $ar(doc.total), { total: true }],
          ]} />
        </>
      )}

      {/* REMITO */}
      {tipoDoc === 'remito' && (
        <>
          <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', marginBottom: 14 }}>
            <Field label="Punto vta.">{doc.punto_venta}</Field>
            <Field label="Factura vinc.">{doc.factura_numero || '—'}</Field>
          </div>
          <ItemsCompra items={doc.items || []} />
        </>
      )}

      {/* NOTA */}
      {tipoDoc === 'nota' && (
        <>
          <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', marginBottom: 14 }}>
            <Field label="Tipo"><Badge estado={doc.tipo} /></Field>
            <Field label="Letra">{doc.tipo_letra}</Field>
            <Field label="Factura vinc.">{doc.factura_numero || '—'}</Field>
            <Field label="Motivo">{doc.motivo || '—'}</Field>
          </div>
          <ItemsCompra items={doc.items || []} />
          <TotalesLineas lineas={[
            ['Subtotal', $ar(doc.subtotal)],
            ['Neto gravado', $ar(doc.neto_gravado)],
            ['IVA', $ar(doc.iva_monto)],
            ['TOTAL', $ar(doc.total), { total: true }],
          ]} />
        </>
      )}

      {/* PAGO */}
      {tipoDoc === 'pago' && (
        <>
          <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', marginBottom: 14 }}>
            <Field label="Punto vta.">{doc.punto_venta}</Field>
            <Field label="Total pagado"><b>{$ar(doc.total)}</b></Field>
          </div>

          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--gray-600)', margin: '4px 0 6px' }}>Facturas imputadas</div>
          {(doc.facturas || []).length === 0
            ? <div style={{ fontSize: 12, color: 'var(--gray-400)', marginBottom: 12 }}>Sin imputación (pago a cuenta)</div>
            : (
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 12 }}>
                {doc.facturas.map((f, i) => <span key={i} className="code">{f.numero}</span>)}
              </div>
            )}

          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--gray-600)', margin: '4px 0 6px' }}>Medios de pago</div>
          <div className="tbl-wrap" style={{ boxShadow: 'none', border: '1px solid var(--gray-200)', marginBottom: 12 }}>
            <table>
              <thead><tr><th>Medio</th><th>Detalle</th><th className="th-right">Monto</th></tr></thead>
              <tbody>
                {(doc.medios || []).map((m, i) => (
                  <tr key={m.id ?? i}>
                    <td>{MEDIO_LABEL[m.tipo] || m.tipo}</td>
                    <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{m.detalle || '—'}</td>
                    <td className="td-right td-bold">{$ar(m.monto)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {(doc.retenciones || []).length > 0 && (
            <>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--gray-600)', margin: '4px 0 6px' }}>Retenciones</div>
              <div className="tbl-wrap" style={{ boxShadow: 'none', border: '1px solid var(--gray-200)' }}>
                <table>
                  <thead><tr>
                    <th>Tipo</th><th>Jurisdicción</th><th>Certificado</th>
                    <th className="th-right">Base</th><th className="th-right">Alíc.</th><th className="th-right">Monto</th>
                  </tr></thead>
                  <tbody>
                    {doc.retenciones.map((r, i) => (
                      <tr key={r.id ?? i}>
                        <td>{r.tipo_retencion}</td>
                        <td style={{ fontSize: 12, color: 'var(--gray-500)' }}>{r.jurisdiccion || '—'}</td>
                        <td className="code">{r.numero_certificado || '—'}</td>
                        <td className="td-right">{$ar(r.base_imponible)}</td>
                        <td className="td-right">{r.alicuota}%</td>
                        <td className="td-right td-bold">{$ar(r.monto)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </>
      )}

      {doc.observaciones && (
        <div style={{ marginTop: 14, paddingTop: 12, borderTop: '1px solid var(--gray-100)', fontSize: 12, color: 'var(--gray-500)' }}>
          <b style={{ color: 'var(--gray-600)' }}>Observaciones:</b> {doc.observaciones}
        </div>
      )}
    </Modal>
  )
}
