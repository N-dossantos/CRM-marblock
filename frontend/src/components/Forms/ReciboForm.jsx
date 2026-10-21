// src/components/Forms/ReciboForm.jsx
import { useState, useEffect } from 'react'
import { Modal, ClienteSearch } from '../UI'
import { $ar, hoy } from '../../utils'
import { ConfigAPI, RecibosAPI } from '../../api'
import toast from 'react-hot-toast'

const MEDIO_BASE = { tipo: 'efectivo', detalle: '', monto: 0, cuenta_bancaria_id: '' }
const RETENCION_BASE = { tipo_retencion: 'Ganancias', codigo_regimen: '', jurisdiccion: '', numero_certificado: '', fecha: hoy(), monto: 0 }

export default function ReciboForm({ clientes = [], initial = {}, onSave, onClose }) {
  const [form, setForm]            = useState({
    cliente_id: initial.cliId || '',
    facturas:   [],
    imputaciones: (initial.facIds || []).map(id => ({ factura_id: id, importe: initial.totalSugerido || 0 })),
    medios:     [],
    retenciones: [],
    observaciones: '',
  })
  const [cuentas, setCuentas]  = useState([])
  const [loading, setLoading]  = useState(false)
  const [cargandoFacturas, setCargandoFacturas] = useState(false)
  const [errorFacturas, setErrorFacturas] = useState(false)
  const [reintentoFacturas, setReintentoFacturas] = useState(0)
  // El recibo se escribe sobre talonario: el número se prellena con el próximo de `contadores`, pero
  // queda editable porque a veces una hoja se tacha o se pierde la copia (M7). Sólo se manda si el
  // operador lo cambió; si no, lo asigna crear_recibo al guardar (dos formularios abiertos a la vez
  // no chocan por el mismo sugerido).
  const [sugerido, setSugerido] = useState(null)
  const [numero, setNumero]     = useState('')

  useEffect(() => {
    ConfigAPI.cuentasBancarias().then(setCuentas)
    RecibosAPI.numeroSugerido()
      .then(n => { setSugerido(n); setNumero(actual => actual || n || '') })
      .catch(() => {})
  }, [])

  const numeroManual = numero.trim() && numero.trim() !== sugerido ? numero.trim() : null

  // El saldo disponible llega calculado por la base, considerando recibos y NC autorizadas.
  useEffect(() => {
    if (!form.cliente_id) {
      setCargandoFacturas(false)
      setErrorFacturas(false)
      setForm(f => ({ ...f, facturas: [] }))
      return
    }
    let vigente = true
    setCargandoFacturas(true)
    setErrorFacturas(false)
    RecibosAPI.facturasPendientes(+form.cliente_id)
      .then(facturas => {
        if (!vigente) return
        setForm(f => ({
          ...f,
          facturas,
          imputaciones: f.imputaciones
            .filter(i => facturas.some(fac => fac.id === i.factura_id))
            .map(i => ({ ...i, importe: Math.min(i.importe, +facturas.find(fac => fac.id === i.factura_id).saldo) })),
        }))
      })
      .catch(() => { if (vigente) setErrorFacturas(true) })
      .finally(() => { if (vigente) setCargandoFacturas(false) })
    return () => { vigente = false }
  }, [form.cliente_id, reintentoFacturas])

  const toggleFac = (fac) => setForm(f => ({ ...f,
    imputaciones: f.imputaciones.some(i => i.factura_id === fac.id)
      ? f.imputaciones.filter(i => i.factura_id !== fac.id)
      : [...f.imputaciones, { factura_id: fac.id, importe: +fac.saldo }],
  }))

  const updateImputacion = (id, importe) => setForm(f => ({ ...f,
    imputaciones: f.imputaciones.map(i => i.factura_id === id ? { ...i, importe: parseFloat(importe) || 0 } : i),
  }))

  const addMedio = () =>
    setForm(f => ({ ...f, medios: [...f.medios, { ...MEDIO_BASE }] }))

  const removeMedio = (i) =>
    setForm(f => ({ ...f, medios: f.medios.filter((_, idx) => idx !== i) }))

  const addRetencion = () => setForm(f => ({ ...f, retenciones: [...f.retenciones, { ...RETENCION_BASE, fecha: hoy() }] }))
  const removeRetencion = (i) => setForm(f => ({ ...f, retenciones: f.retenciones.filter((_, idx) => idx !== i) }))
  const updateRetencion = (i, field, value) => setForm(f => ({ ...f,
    retenciones: f.retenciones.map((r, idx) => idx === i
      ? { ...r, [field]: field === 'monto' ? parseFloat(value) || 0 : value }
      : r),
  }))

  const updateMedio = (i, field, val) =>
    setForm(f => ({
      ...f,
      medios: f.medios.map((m, idx) => {
        if (idx !== i) return m
        const next = { ...m, [field]: field === 'monto' ? parseFloat(val) || 0 : val }
        // Caja/cuenta aplica sólo a efectivo o transferencia.
        // Limpiarla al cambiar el medio evita asociar una cuenta incompatible.
        if (field === 'tipo') {
          next.cuenta_bancaria_id = ''
          next.detalle = ''
        }
        return next
      }),
    }))

  // Selecciona la cuenta del ledger para un medio efectivo/transferencia.
  // Guarda cuenta_bancaria_id (lo que crear_recibo lee para emitir la COBRANZA en tesorería)
  // y refleja la descripción en detalle para el listado/detalle del recibo.
  const setMedioCuenta = (i, cuentaId) =>
    setForm(f => ({
      ...f,
      medios: f.medios.map((m, idx) => {
        if (idx !== i) return m
        const cta = cuentas.find(c => String(c.id) === String(cuentaId))
        return { ...m, cuenta_bancaria_id: cuentaId || '', detalle: cta ? cta.descripcion : '' }
      }),
    }))

  const totalMedios = form.medios.reduce((a, m) => a + (m.monto || 0), 0)
  const totalRetenciones = form.retenciones.reduce((a, r) => a + (r.monto || 0), 0)
  const totalRecibo = totalMedios + totalRetenciones
  const totalImputado = form.imputaciones.reduce((a, i) => a + i.importe, 0)

  const save = async () => {
    if (!form.cliente_id)    { toast.error('Seleccione un cliente'); return }
    if (cargandoFacturas || errorFacturas) { toast.error('No se pudo verificar el saldo de las facturas. Reintentá la consulta.'); return }
    if (!form.medios.length && !form.retenciones.length) { toast.error('Agregue un medio de cobro o una retención'); return }
    if (totalRecibo <= 0) { toast.error('El total del recibo debe ser mayor a cero'); return }
    if (form.medios.some(m => !m.monto || m.monto <= 0)) { toast.error('Cada medio de cobro necesita un monto positivo'); return }
    if (form.medios.some(m => ['efectivo', 'transferencia'].includes(m.tipo) && !m.cuenta_bancaria_id)) {
      toast.error('Seleccione la caja o cuenta bancaria de cada cobro'); return
    }
    if (form.medios.some(m => ['cheque', 'echeq'].includes(m.tipo) && (!m.numero_cheque?.trim() || !m.banco?.trim() || !m.fecha_vcto))) {
      toast.error('Cada cheque necesita número, banco y vencimiento'); return
    }
    if (form.retenciones.some(r => !r.monto || r.monto <= 0 || !r.fecha || !r.numero_certificado.trim() || (r.tipo_retencion === 'IIBB' && !r.jurisdiccion.trim()))) {
      toast.error('Cada retención necesita fecha, certificado y monto; IIBB también jurisdicción'); return
    }
    if (form.retenciones.length && !clientes.find(c => c.id === +form.cliente_id && +c.doc_tipo === 80)) {
      toast.error('Para registrar retenciones, el cliente debe tener CUIT'); return
    }
    if (form.imputaciones.some(i => !i.importe || i.importe <= 0 || !form.facturas.some(f => f.id === i.factura_id && i.importe <= +f.saldo))) {
      toast.error('Revisá el importe aplicado a cada factura'); return
    }
    if (totalImputado > totalRecibo + 0.001) { toast.error('La suma aplicada a facturas supera el total del recibo'); return }
    if (numeroManual && !/^\d{5}-\d{8}$/.test(numeroManual)) {
      toast.error('El número del recibo debe tener el formato 00001-00004289'); return
    }

    setLoading(true)
    try {
      await onSave({
        cliente_id:   +form.cliente_id,
        imputaciones: form.imputaciones,
        medios:       form.medios,
        retenciones:  form.retenciones,
        observaciones: form.observaciones,
        ...(numeroManual && { numero: numeroManual }),
      })
    } finally {
      setLoading(false)
    }
  }

  return (
    <Modal
      almanaque={false}
      title="Nuevo Recibo de Cobro"
      size="lg"
      onClose={onClose}
      footer={
        <>
          <button className="btn btn-secondary" onClick={onClose} disabled={loading}>Cancelar</button>
          <button className="btn btn-success" onClick={save} disabled={loading}>
            {loading ? 'Guardando…' : '✓ Registrar cobro'}
          </button>
        </>
      }
    >
      <div className="form-row3">
        {/* Cliente */}
        <div className="field" style={{ gridColumn: '1 / 3' }}>
          <label className="lbl">Cliente *</label>
          <ClienteSearch
            clientes={clientes}
            value={form.cliente_id}
            onChange={cliId => setForm(f => ({ ...f, cliente_id: cliId, imputaciones: [], facturas: [] }))}
          />
        </div>

        {/* Número de la hoja del talonario */}
        <div className="field">
          <label className="lbl">N° de recibo</label>
          <input
            className="inp"
            value={numero}
            placeholder="00001-00004289"
            onChange={e => setNumero(e.target.value)}
            style={{ fontFamily: 'monospace' }}
          />
          {numeroManual && sugerido && (
            <div style={{ fontSize: 11, color: 'var(--orange-500)', marginTop: 4 }}>
              Distinto del sugerido ({sugerido}): se usa el que cargaste.
            </div>
          )}
        </div>
      </div>

      {/* Facturas a imputar */}
      {form.facturas.length > 0 && (
        <div className="field">
          <label className="lbl">Aplicar a facturas (opcional; el resto queda a cuenta)</label>
          <div style={{ border: '1px solid var(--gray-200)', borderRadius: 8, overflow: 'hidden' }}>
            {form.facturas.map(f => {
              const imp = form.imputaciones.find(i => i.factura_id === f.id)
              return (
                <div key={f.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 14px', borderBottom: '1px solid var(--gray-100)', flexWrap: 'wrap' }}>
                  <label style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer', flex: 1, minWidth: 190 }}>
                    <input type="checkbox" checked={!!imp} onChange={() => toggleFac(f)} />
                    <span className="code">{f.numero}</span>
                    <span style={{ color: 'var(--gray-500)', fontSize: 12 }}>Saldo {$ar(f.saldo)}</span>
                  </label>
                  {imp && <div className="field" style={{ width: 150 }}>
                    <label className="lbl" htmlFor={`importe-factura-${f.id}`}>Aplicar $</label>
                    <input id={`importe-factura-${f.id}`} type="number" className="inp inp-right" min="0.01" max={f.saldo} step="0.01"
                      value={imp.importe} onChange={e => updateImputacion(f.id, e.target.value)} />
                  </div>}
                </div>
              )
            })}
          </div>
        </div>
      )}

      {!form.cliente_id && (
        <div className="info-box">Seleccione un cliente para ver sus facturas pendientes.</div>
      )}
      {cargandoFacturas && <div className="info-box">Consultando saldos de facturas…</div>}
      {errorFacturas && <div className="info-box">No se pudieron consultar los saldos. <button className="btn btn-secondary btn-sm" onClick={() => setReintentoFacturas(n => n + 1)}>Reintentar</button></div>}
      {form.cliente_id && !cargandoFacturas && !errorFacturas && form.facturas.length === 0 && (
        <div className="info-box">Este cliente no tiene facturas pendientes. El total del recibo quedará a cuenta.</div>
      )}

      {/* Medios de cobro */}
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', margin: '16px 0 10px' }}>
        <span className="lbl" style={{ margin: 0 }}>Medios de cobro</span>
        <button className="btn btn-secondary btn-sm" onClick={addMedio}>+ Agregar</button>
      </div>

      {form.medios.map((m, i) => (
        <MedioCard key={i} medio={m} index={i} cuentas={cuentas} onChange={updateMedio} onCuenta={setMedioCuenta} onRemove={removeMedio} />
      ))}

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', margin: '18px 0 10px' }}>
        <span className="lbl" style={{ margin: 0 }}>Retenciones sufridas</span>
        <button className="btn btn-secondary btn-sm" onClick={addRetencion}>+ Agregar retención</button>
      </div>
      {form.retenciones.map((r, i) => (
        <div className="medio-card" key={i}>
          <div className="form-row3">
            <div className="field"><label className="lbl">Impuesto *</label>
              <select className="sel" value={r.tipo_retencion} onChange={e => updateRetencion(i, 'tipo_retencion', e.target.value)}>
                <option>Ganancias</option><option>IVA</option><option>IIBB</option><option>SUSS</option>
              </select>
            </div>
            <div className="field"><label className="lbl">N° de certificado *</label>
              <input className="inp" value={r.numero_certificado} onChange={e => updateRetencion(i, 'numero_certificado', e.target.value)} />
            </div>
            <div className="field"><label className="lbl">Código de régimen (si figura)</label>
              <input className="inp" value={r.codigo_regimen} onChange={e => updateRetencion(i, 'codigo_regimen', e.target.value)} />
            </div>
            <div className="field"><label className="lbl">Fecha del certificado *</label>
              <input type="date" className="inp" value={r.fecha} onChange={e => updateRetencion(i, 'fecha', e.target.value)} />
            </div>
            {r.tipo_retencion === 'IIBB' && <div className="field"><label className="lbl">Jurisdicción *</label>
              <input className="inp" value={r.jurisdiccion} onChange={e => updateRetencion(i, 'jurisdiccion', e.target.value)} placeholder="Ej: Buenos Aires" />
            </div>}
            <div className="field"><label className="lbl">Monto retenido $ *</label>
              <input type="number" className="inp inp-right" min="0.01" step="0.01" value={r.monto} onChange={e => updateRetencion(i, 'monto', e.target.value)} />
            </div>
          </div>
          <div style={{ textAlign: 'right', marginTop: 8 }}>
            <button className="btn btn-danger btn-xs" onClick={() => removeRetencion(i)}>Quitar retención</button>
          </div>
        </div>
      ))}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr auto', gap: '6px 16px', padding: '12px 0', borderTop: '2px solid var(--gray-200)', marginTop: 12 }}>
        <span>Dinero y cheques recibidos</span><b>{$ar(totalMedios)}</b>
        <span>Retenciones sufridas</span><b>{$ar(totalRetenciones)}</b>
        <span style={{ fontWeight: 700 }}>Total del recibo</span>
        <strong style={{ fontSize: 20, color: 'var(--blue-600)' }}>{$ar(totalRecibo)}</strong>
        {form.imputaciones.length > 0 && <><span>Aplicado a facturas</span><b>{$ar(totalImputado)}</b></>}
        {totalRecibo > totalImputado && <><span>Queda a cuenta del cliente</span><b>{$ar(totalRecibo - totalImputado)}</b></>}
        {totalImputado > totalRecibo && <><span style={{ color: 'var(--red-600)' }}>Falta cubrir para aplicar a facturas</span><b style={{ color: 'var(--red-600)' }}>{$ar(totalImputado - totalRecibo)}</b></>}
      </div>

      <div className="field" style={{ marginTop: 12 }}>
        <label className="lbl">Observaciones</label>
        <input className="inp" value={form.observaciones} onChange={e => setForm(f => ({ ...f, observaciones: e.target.value }))} />
      </div>
    </Modal>
  )
}

function MedioCard({ medio, index, cuentas, onChange, onCuenta, onRemove }) {
  const esCuenta = medio.tipo === 'efectivo' || medio.tipo === 'transferencia'
  const cuentasDisponibles = cuentas.filter(c => c.clase === (medio.tipo === 'efectivo' ? 'caja' : 'banco'))
  return (
    <div className="medio-card">
      <div className="form-row3" style={{ marginBottom: 10 }}>
        <div className="field">
          <label className="lbl">Medio de cobro</label>
          <select className="sel" value={medio.tipo} onChange={e => onChange(index, 'tipo', e.target.value)}>
            <option value="efectivo">Caja (efectivo)</option>
            <option value="transferencia">Transferencia bancaria</option>
            <option value="cheque">Cheque físico</option>
            <option value="echeq">E-Cheq</option>
          </select>
        </div>

        {esCuenta && (
          <div className="field">
            <label className="lbl">{medio.tipo === 'efectivo' ? 'Caja de ingreso *' : 'Cuenta bancaria de ingreso *'}</label>
            <select className="sel" value={medio.cuenta_bancaria_id || ''} onChange={e => onCuenta(index, e.target.value)}>
              <option value="">{cuentasDisponibles.length ? '— Seleccionar —' : medio.tipo === 'efectivo' ? 'No hay cajas activas' : 'No hay cuentas bancarias activas'}</option>
              {cuentasDisponibles.map(c => <option key={c.id} value={c.id}>{c.descripcion}</option>)}
            </select>
            <div style={{ fontSize: 11, color: 'var(--gray-500)', marginTop: 3 }}>
              {medio.tipo === 'efectivo' ? 'Solo aparecen cajas.' : 'Solo aparecen cuentas bancarias, como Provincia o Galicia.'}
            </div>
          </div>
        )}

        {(medio.tipo === 'cheque' || medio.tipo === 'echeq') && (
          <div className="field">
            <label className="lbl">Nro. cheque</label>
            <input className="inp" value={medio.numero_cheque || ''} onChange={e => onChange(index, 'numero_cheque', e.target.value)} />
          </div>
        )}

        <div className="field">
          <label className="lbl">Monto $</label>
          <input type="number" className="inp inp-right" value={medio.monto} min="0" step="0.01" onChange={e => onChange(index, 'monto', e.target.value)} />
        </div>
      </div>

      {(medio.tipo === 'cheque' || medio.tipo === 'echeq') && (
        <div className="form-row3">
          <div className="field">
            <label className="lbl">Banco</label>
            <input className="inp" value={medio.banco || ''} onChange={e => onChange(index, 'banco', e.target.value)} />
          </div>
          <div className="field">
            <label className="lbl">Titular (opcional)</label>
            <input className="inp" value={medio.titular || ''} onChange={e => onChange(index, 'titular', e.target.value)} />
          </div>
          <div className="field">
            <label className="lbl">Vencimiento</label>
            <input type="date" className="inp" value={medio.fecha_vcto || ''} onChange={e => onChange(index, 'fecha_vcto', e.target.value)} />
          </div>
        </div>
      )}

      <div style={{ textAlign: 'right' }}>
        <button className="btn btn-danger btn-xs" onClick={() => onRemove(index)}>Quitar</button>
      </div>
    </div>
  )
}
