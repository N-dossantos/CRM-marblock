// src/components/Consultas/Consulta360.jsx
// Shell reutilizable de "consulta integral 360°" (Fase B): panel izquierdo con buscador +
// lista de entidades (clientes o proveedores), panel derecho con cabecera + sub-pestañas.
// ConsultaCliente y ConsultaProveedor sólo aportan el loader de datos, la cabecera y las
// pestañas — todo el layout/scroll/estado de selección vive acá una sola vez.
import { useState } from 'react'
import { Loading } from '../UI'
import { $ar } from '../../utils'

export default function Consulta360({
  entities = [],
  selId,
  onSelect,
  searchPlaceholder = 'Buscar…',
  emptyIcon = '🔎',
  emptyText = 'Seleccione un registro para ver el detalle',
  selSaldo = null,     // saldo de la entidad seleccionada (para el badge del picker)
  saldoLabels = { pos: '▲ Debe', neg: '▼ A favor', zero: '✓ Sin saldo' },
  loading = false,
  data = null,
  header = null,       // JSX de cabecera (lo arma el padre con `data`)
  tabs = [],           // [{ id, label, count, render: () => JSX }]
  // Accessors opcionales (Fase D): permiten reusar el shell con entidades que no
  // tienen razon_social/cuit (p. ej. una cuenta de tesorería). Los defaults preservan
  // el comportamiento de ConsultaCliente/ConsultaProveedor sin tocarlos.
  getLabel    = (e) => e.razon_social,
  getSubtitle = (e) => e.cuit,
  matchFn     = (e, search) => {
    const s = search.toLowerCase()
    return (e.razon_social || '').toLowerCase().includes(s) || (e.cuit || '').includes(search)
  },
}) {
  const [search, setSearch] = useState('')
  const [tab, setTab] = useState(tabs[0]?.id)

  const filtered = entities.filter(e => (search ? matchFn(e, search) : true))

  const activo = tabs.find(t => t.id === tab) || tabs[0]

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '270px 1fr', gap: 18, height: 'calc(100vh - 54px - 48px)', overflow: 'hidden' }}>
      {/* Panel izquierdo: lista de entidades */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 0, overflow: 'hidden' }}>
        <div className="card" style={{ padding: 14, marginBottom: 0, borderBottom: 'none', borderBottomLeftRadius: 0, borderBottomRightRadius: 0 }}>
          <input className="search-inp" style={{ width: '100%' }} placeholder={searchPlaceholder} value={search} onChange={e => setSearch(e.target.value)} />
        </div>
        <div style={{ flex: 1, overflowY: 'auto', background: '#fff', border: '1px solid var(--gray-200)', borderRadius: '0 0 12px 12px' }}>
          {filtered.map(e => {
            const selected = String(selId) === String(e.id)
            const saldo = selected ? selSaldo : null
            const label = getLabel(e) || '—'
            return (
              <div
                key={e.id}
                onClick={() => onSelect(e.id)}
                style={{
                  padding: '10px 14px', cursor: 'pointer', borderBottom: '1px solid var(--gray-100)',
                  background: selected ? 'var(--blue-50)' : 'transparent',
                  borderLeft: selected ? '3px solid var(--blue-600)' : '3px solid transparent',
                  transition: 'background .12s',
                }}
              >
                <div style={{ fontWeight: selected ? 700 : 500, fontSize: 13, color: 'var(--gray-800)' }}>
                  {label.length > 28 ? label.slice(0, 28) + '…' : label}
                </div>
                {saldo !== null && saldo !== undefined
                  ? (
                    <div style={{ fontSize: 12, fontWeight: 700, marginTop: 2, color: saldo > 0 ? 'var(--red-500)' : saldo < 0 ? '#10b981' : 'var(--gray-400)' }}>
                      {$ar(saldo)} {saldo > 0 ? saldoLabels.pos : saldo < 0 ? saldoLabels.neg : saldoLabels.zero}
                    </div>
                  )
                  : <div style={{ fontSize: 11, color: 'var(--gray-400)', marginTop: 2 }}>{getSubtitle(e)}</div>}
              </div>
            )
          })}
          {filtered.length === 0 && (
            <div style={{ padding: 20, textAlign: 'center', fontSize: 12, color: 'var(--gray-400)' }}>Sin resultados</div>
          )}
        </div>
      </div>

      {/* Panel derecho */}
      <div style={{ overflowY: 'auto' }}>
        {!selId ? (
          <div className="card" style={{ textAlign: 'center', padding: '60px 20px' }}>
            <div style={{ fontSize: 40, marginBottom: 12 }}>{emptyIcon}</div>
            <p style={{ color: 'var(--gray-400)', fontSize: 14 }}>{emptyText}</p>
          </div>
        ) : loading || !data ? (
          <Loading />
        ) : (
          <div>
            {header}

            {/* Sub-pestañas */}
            <div style={{ display: 'flex', gap: 0, margin: '4px 0 16px', borderBottom: '2px solid var(--gray-200)', flexWrap: 'wrap' }}>
              {tabs.map(t => (
                <button
                  key={t.id}
                  onClick={() => setTab(t.id)}
                  style={{
                    padding: '8px 16px', background: 'transparent', border: 'none',
                    borderBottom: tab === t.id ? '2px solid var(--blue-600)' : '2px solid transparent',
                    marginBottom: -2, color: tab === t.id ? 'var(--blue-600)' : 'var(--gray-500)',
                    fontWeight: tab === t.id ? 700 : 500, fontSize: 13, cursor: 'pointer',
                    fontFamily: 'inherit', whiteSpace: 'nowrap',
                  }}
                >
                  {t.label}{typeof t.count === 'number' ? ` (${t.count})` : ''}
                </button>
              ))}
            </div>

            {activo?.render()}
          </div>
        )}
      </div>
    </div>
  )
}
