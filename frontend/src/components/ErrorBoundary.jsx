// src/components/ErrorBoundary.jsx
// Red de contención de errores de render. Sin esto, cualquier excepción tirada dentro de un
// componente desmonta TODO el árbol y el usuario ve una pantalla en blanco, sin pista de qué pasó
// ni forma de volver salvo recargar a mano (fue exactamente el síntoma del bug de ReciboForm,
// donde `facturas` terminaba siendo una función y `.map` explotaba).
//
// Tiene que ser una clase: los hooks no exponen componentDidCatch/getDerivedStateFromError.
import { Component } from 'react'

export default class ErrorBoundary extends Component {
  state = { error: null }

  static getDerivedStateFromError(error) {
    return { error }
  }

  componentDidCatch(error, info) {
    // No hay servicio de logs todavía; la consola es lo único que queda para diagnosticar.
    console.error('[ErrorBoundary] Error de render:', error, info?.componentStack)
  }

  // Al navegar a otra sección se reintenta el render: si el error era de esta pantalla,
  // la app sigue viva en vez de quedar trabada hasta un F5.
  reset = () => this.setState({ error: null })

  render() {
    const { error } = this.state
    if (!error) return this.props.children

    return (
      <div className="card" style={{ maxWidth: 620, margin: '48px auto', textAlign: 'center' }}>
        <div style={{ fontSize: 40, marginBottom: 12 }}>⚠️</div>
        <h2 style={{ fontSize: 18, fontWeight: 700, color: 'var(--gray-800)', marginBottom: 8 }}>
          Se rompió esta pantalla
        </h2>
        <p style={{ fontSize: 13, color: 'var(--gray-500)', marginBottom: 16 }}>
          El resto del sistema sigue funcionando. Los datos que no se llegaron a guardar se perdieron.
        </p>
        <pre style={{
          textAlign: 'left', background: 'var(--gray-100)', borderRadius: 8, padding: 12,
          fontSize: 12, color: 'var(--red-500)', overflowX: 'auto', marginBottom: 16,
        }}>
          {error.message || String(error)}
        </pre>
        <div style={{ display: 'flex', gap: 8, justifyContent: 'center' }}>
          <button className="btn btn-secondary" onClick={this.reset}>Reintentar</button>
          <button className="btn btn-primary" onClick={() => window.location.reload()}>Recargar</button>
        </div>
      </div>
    )
  }
}
