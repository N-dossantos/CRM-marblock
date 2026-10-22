// src/components/Forms/FacturasPendientesRemitir.jsx
// "Facturas pendientes de remitir" del remito (PLAN_MAESTRO §3.11): una tabla por factura, de la
// más vieja a la más nueva, con lo que falta entregar de cada producto. "Lleva" dice cuánto sale
// de cada factura en este viaje; ComprobanteForm arma los renglones con armarItems.
import { fFecha } from '../../utils'
import { faltan, palletsEquivalentes } from '../../utils/pendientes'

const n = (x) => (+x || 0).toLocaleString('es-AR', { maximumFractionDigits: 3 })
const UNA = { pallets: 'pallet', unidades: 'unidad' }

// La cantidad con su equivalente en pallets, si el producto va en pallets.
function Cantidad({ valor, item }) {
  const pal = item.es_pallet_vacio || item.es_transporte ? null : palletsEquivalentes(valor, item.unidades_por_pallet)
  return <>{n(valor)}{pal != null && <span className="fpr-pal">({n(pal)} pallets)</span>}</>
}

export default function FacturasPendientesRemitir({ facturas = [], lleva = {}, onChange, loading = false }) {
  const cambiar = (facturaId, clave, valor) => {
    const cant = Math.max(0, +valor || 0)
    const deFactura = { ...lleva[facturaId], [clave]: cant }
    if (!cant) delete deFactura[clave]
    const nuevo = { ...lleva, [facturaId]: deFactura }
    if (!Object.keys(deFactura).length) delete nuevo[facturaId]
    onChange(nuevo)
  }

  return (
    <div className="field" style={{ marginBottom: 14 }}>
      <label className="lbl">Facturas pendientes de remitir</label>
      {loading ? (
        <div className="rem-pend-vacio">Buscando facturas…</div>
      ) : facturas.length === 0 ? (
        <div className="rem-pend-vacio">Este cliente no tiene facturas pendientes de remitir.</div>
      ) : (
        <div className="fpr-lista">
          {facturas.map(f => {
            const falta = faltan(f)
            return (
              <div key={f.id} className="fpr-factura">
                <div className="fpr-head">
                  <span className="code">{f.tipo ? `${f.tipo} ` : ''}{f.numero}</span>
                  <span className="fpr-fecha">· {fFecha(f.fecha)}</span>
                  <span className="fpr-faltan">
                    {falta.cantidad === 1 ? `falta 1 ${UNA[falta.unidad]}` : `faltan ${n(falta.cantidad)} ${falta.unidad}`}
                  </span>
                </div>
                <table className="fpr-tabla">
                  <thead>
                    <tr>
                      <th>Producto</th><th>Facturado</th><th>Remitido</th><th>Pendiente</th><th>Lleva</th><th>Queda</th>
                    </tr>
                  </thead>
                  <tbody>
                    {f.items.map(it => {
                      const cant = +(lleva[f.id]?.[it.clave] || 0)
                      return (
                        <tr key={it.clave}>
                          <td>{it.descripcion}</td>
                          <td><Cantidad valor={it.facturado} item={it} /></td>
                          <td>{n(it.remitido)}</td>
                          <td title={+it.acreditado > 0 ? `Descuenta ${n(it.acreditado)} de notas de crédito` : undefined}>
                            <Cantidad valor={it.pendiente} item={it} />
                          </td>
                          <td>
                            <input className="inp fpr-lleva" type="number" min="0" placeholder="0"
                              aria-label={`Lleva de ${it.descripcion}, factura ${f.numero}`}
                              value={cant || ''} onChange={e => cambiar(f.id, it.clave, e.target.value)} />
                          </td>
                          <td><Cantidad valor={Math.max(0, it.pendiente - cant)} item={it} /></td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
