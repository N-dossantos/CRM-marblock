// src/components/Consultas/MovimientoDetalle.jsx
// Modal de detalle SÓLO LECTURA de un movimiento de TESORERÍA (una fila del ledger central),
// para la Consulta 360° de cuenta (Fase D). Recibe el row tal cual lo devuelve
// movimientos_tesoreria_list. Espeja a VentaDetalle: hay PDF (Edge Function) → botón "📄 PDF"
// que abre el comprobante interno del movimiento (orden de pago / recibo interno) en PDFModal.
import { useState } from 'react'
import { Modal } from '../UI'
import PDFModal from '../PDFModal'
import { pdfUrl } from '../../api'
import { $ar, fFecha } from '../../utils'

const ORIGEN_LABEL = {
  manual:         'Manual',
  recibo:         'Recibo de cobro',
  pago_proveedor: 'Pago a proveedor',
  cheque:         'Cheque de tercero',
  cheque_propio:  'Cheque propio',
  transferencia:  'Transferencia',
  conciliacion:   'Conciliación',
}

function Field({ label, children }) {
  return (
    <div style={{ minWidth: 120 }}>
      <div style={{ fontSize: 'calc(11px * var(--font-scale))', fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>{label}</div>
      <div style={{ fontSize: 'calc(13px * var(--font-scale))', color: 'var(--gray-800)', marginTop: 2 }}>{children ?? '—'}</div>
    </div>
  )
}

export default function MovimientoDetalle({ mov, onClose }) {
  const [pdf, setPdf] = useState(null)
  if (!mov) return null

  const esEntrada = Number(mov.signo) === 1
  const titulo = `Movimiento ${mov.numero || `#${mov.id}`}`
  const abrirPdf = () => setPdf({ url: pdfUrl.movimientoTesoreria(mov.id), titulo })

  const estado = mov.anulado
    ? <span className="badge badge-anulada">Anulado</span>
    : mov.conciliado ? <span className="badge badge-cobrada">Conciliado</span> : <span className="badge badge-pendiente">Vigente</span>

  return (
    <>
      <Modal
        title={titulo}
        size="md"
        onClose={onClose}
        footer={
          <button
            className="btn btn-secondary btn-sm"
            style={{ background: 'var(--red-50)', color: 'var(--red-600)', borderColor: 'var(--red-100)' }}
            onClick={abrirPdf}
          >
            📄 Ver PDF
          </button>
        }
      >
        {/* Cabecera: cuenta + estado */}
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', paddingBottom: 12, marginBottom: 14, borderBottom: '1px solid var(--gray-100)' }}>
          <div>
            <div style={{ fontSize: 'calc(15px * var(--font-scale))', fontWeight: 700, color: 'var(--gray-800)' }}>{mov.cuenta_descripcion}</div>
            <div style={{ fontSize: 'calc(12px * var(--font-scale))', color: 'var(--gray-500)', marginTop: 2 }}>
              {mov.cuenta_clase ? mov.cuenta_clase[0].toUpperCase() + mov.cuenta_clase.slice(1) : '—'}
            </div>
          </div>
          <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', justifyContent: 'flex-end' }}>
            <Field label="Fecha">{fFecha(mov.fecha)}</Field>
            <Field label="Estado">{estado}</Field>
          </div>
        </div>

        {/* Importe destacado */}
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--gray-50)', border: '1px solid var(--gray-200)', borderRadius: 10, padding: '14px 18px', marginBottom: 16 }}>
          <div style={{ fontSize: 'calc(12px * var(--font-scale))', fontWeight: 700, color: 'var(--gray-500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>
            {esEntrada ? '▲ Entrada' : '▼ Salida'}
          </div>
          <div style={{ fontSize: 'calc(26px * var(--font-scale))', fontWeight: 800, lineHeight: 1, color: esEntrada ? 'var(--green-600)' : 'var(--red-500)' }}>
            {esEntrada ? '' : '− '}{$ar(mov.monto)}
          </div>
        </div>

        {/* Datos del movimiento */}
        <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap', marginBottom: 14 }}>
          <Field label="Tipo">{mov.tipo_descripcion}{mov.tipo_codigo ? ` (${mov.tipo_codigo})` : ''}</Field>
          <Field label="Origen">{ORIGEN_LABEL[mov.origen] || mov.origen}</Field>
          {mov.referencia_id != null && (
            <Field label="Referencia">{mov.referencia_tipo || '—'} #{mov.referencia_id}</Field>
          )}
        </div>

        {mov.concepto && (
          <div style={{ marginTop: 4, paddingTop: 12, borderTop: '1px solid var(--gray-100)', fontSize: 'calc(12px * var(--font-scale))', color: 'var(--gray-500)' }}>
            <b style={{ color: 'var(--gray-600)' }}>Concepto:</b> {mov.concepto}
          </div>
        )}
      </Modal>

      {pdf && <PDFModal url={pdf.url} titulo={pdf.titulo} onClose={() => setPdf(null)} />}
    </>
  )
}
