// src/lib/supabase.js
// Cliente Supabase único para todo el frontend. Reemplaza al Axios de src/api/client.js:
// el frontend habla DIRECTO con PostgREST (lecturas) y con las RPC (escrituras atómicas).
// La anon key es pública en el navegador -> la seguridad real la dan Auth + RLS (migración 0002).
import { createClient } from '@supabase/supabase-js';

const url     = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!url || !anonKey) {
  throw new Error(
    'Faltan VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY en el .env del frontend (ver .env.example).'
  );
}

export const supabase = createClient(url, anonKey, {
  auth: {
    persistSession: true,     // mantiene la sesión del staff entre recargas
    autoRefreshToken: true,
    detectSessionInUrl: false, // app de red local, sin redirects OAuth
  },
});
