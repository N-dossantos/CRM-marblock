// src/views/Login/index.jsx
// Pantalla de acceso del staff. Al autenticar, onAuthStateChange (lib/auth) actualiza la
// sesión y App renderiza el CRM — no hace falta navegar manualmente.
import { useState } from 'react';
import toast from 'react-hot-toast';
import { useAuth } from '../../lib/auth';

export default function Login() {
  const { signIn } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setBusy(true);
    const { error: err } = await signIn(email.trim(), password);
    setBusy(false);
    if (err) {
      setError('Email o contraseña incorrectos.');
      return;
    }
    toast.success('Sesión iniciada');
  }

  return (
    <div className="login-screen">
      <form className="login-card" onSubmit={handleSubmit}>
        <div className="login-brand">
          <h1>⚡ CRM Pro</h1>
          <p>Módulo de Ventas — Marblock</p>
        </div>

        {error && <div className="err-box" style={{ marginBottom: 14 }}>{error}</div>}

        <div className="field">
          <label className="lbl" htmlFor="login-email">Email</label>
          <input
            id="login-email"
            type="email"
            className="inp"
            autoComplete="username"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
            autoFocus
            placeholder="tu@empresa.com"
          />
        </div>

        <div className="field">
          <label className="lbl" htmlFor="login-password">Contraseña</label>
          <input
            id="login-password"
            type="password"
            className="inp"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
            placeholder="••••••••"
          />
        </div>

        <button
          type="submit"
          className="btn btn-primary"
          style={{ width: '100%', marginTop: 6, justifyContent: 'center' }}
          disabled={busy}
        >
          {busy ? 'Ingresando…' : 'Ingresar'}
        </button>
      </form>
    </div>
  );
}
