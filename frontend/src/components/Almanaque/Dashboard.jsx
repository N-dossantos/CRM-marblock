import { addDias } from '../../utils'
import { useAlmanaque, useAnotaciones } from '../../lib/almanaque'
import Anotacion, { CalendarioIcon, EstadoAnotaciones } from './Anotacion'
import './almanaque.css'

export default function AlmanaqueDashboard() {
  const { fechaHoy, abrir } = useAlmanaque()
  const datos = useAnotaciones(fechaHoy, addDias(fechaHoy, 7))
  const grupos = [
    { titulo: 'Atrasadas', notas: datos.atrasadas, clase: 'almanaque-atrasadas', vacio: 'No hay anotaciones atrasadas.', fecha: true },
    { titulo: 'Hoy', notas: datos.notas.filter(n => n.fecha === fechaHoy), vacio: 'Sin anotaciones para hoy.' },
    { titulo: 'Próximos 7 días', notas: datos.notas.filter(n => n.fecha > fechaHoy), vacio: 'Sin anotaciones para los próximos 7 días.', fecha: true },
  ]
  return <section className="card almanaque-dashboard" aria-labelledby="almanaque-dashboard-titulo">
    <header className="almanaque-dashboard-header">
      <h2 id="almanaque-dashboard-titulo"><CalendarioIcon />Almanaque</h2>
      <button type="button" className="btn btn-secondary btn-sm" onClick={() => abrir()}>Abrir almanaque</button>
    </header>
    <EstadoAnotaciones {...datos} />
    {!datos.loading && !datos.error && <div className="almanaque-grupos">
      {grupos.map(g => <section key={g.titulo} className={g.clase}>
        <h3>{g.titulo}</h3>
        {g.notas.length ? <ul>{g.notas.map(n => <Anotacion key={n.id} nota={n} mostrarFecha={g.fecha} />)}</ul>
          : <p className="almanaque-vacio">{g.vacio}</p>}
      </section>)}
    </div>}
  </section>
}
