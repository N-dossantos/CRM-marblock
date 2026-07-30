// src/lib/auth.jsx
// Contexto de autenticación del staff. Envuelve la app y refleja en React la sesión de
// Supabase (persistida por supabase-js en localStorage). La seguridad real la dan Auth + RLS:
// sin sesión, `anon` no puede leer ni ejecutar nada (migraciones 0002/0004).
import { createContext, useContext, useEffect, useState } from 'react';
import { supabase } from './supabase';

const AuthContext = createContext(null);

export function AuthProvider({ children }) {
  const [session, setSession] = useState(null);
  const [loading, setLoading] = useState(true); // true hasta resolver la sesión inicial

  useEffect(() => {
    let mounted = true;

    // Sesión inicial (puede venir de localStorage tras un refresh).
    supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return;
      setSession(data.session);
      setLoading(false);
    });

    // Cambios posteriores: login, logout, refresh de token.
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
    });

    return () => {
      mounted = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  const value = {
    session,
    user: session?.user ?? null,
    loading,
    signIn: (email, password) => supabase.auth.signInWithPassword({ email, password }),
    signOut: () => supabase.auth.signOut(),
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth debe usarse dentro de <AuthProvider>.');
  return ctx;
}
