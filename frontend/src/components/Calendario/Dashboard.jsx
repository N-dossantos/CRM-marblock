import { addDias } from '../../utils'
import { useCalendario, useEventos } from '../../lib/calendario'
import Evento, { CalendarioIcon, EstadoEventos } from './Evento'
import './calendario.css'

export default function CalendarioDashboard() {
  const { fechaHoy, abrir } = useCalendario()
  const datos = useEventos(fechaHoy, addDias(fechaHoy, 7))
  const grupos = [
    { titulo: 'Atrasados', eventos: datos.atrasados, clase: 'calendario-atrasados', vacio: 'No hay eventos atrasados.', fecha: true },
    { titulo: 'Hoy', eventos: datos.eventos.filter(ev => ev.fecha === fechaHoy), vacio: 'Sin eventos para hoy.' },
    { titulo: 'Próximos 7 días', eventos: datos.eventos.filter(ev => ev.fecha > fechaHoy), vacio: 'Sin eventos para los próximos 7 días.', fecha: true },
  ]
  return <section className="card calendario-dashboard" aria-labelledby="calendario-dashboard-titulo">
    <header className="calendario-dashboard-header">
      <h2 id="calendario-dashboard-titulo"><CalendarioIcon />Calendario</h2>
      <button type="button" className="btn btn-secondary btn-sm" onClick={() => abrir()}>Abrir calendario</button>
    </header>
    <EstadoEventos {...datos} />
    {!datos.loading && !datos.error && <div className="calendario-grupos">
      {grupos.map(g => <section key={g.titulo} className={g.clase}>
        <h3>{g.titulo}</h3>
        {g.eventos.length ? <ul>{g.eventos.map(ev => <Evento key={ev.id} evento={ev} mostrarFecha={g.fecha} />)}</ul>
          : <p className="calendario-vacio">{g.vacio}</p>}
      </section>)}
    </div>}
  </section>
}
