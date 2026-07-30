  # Auth setup — CRM Ventas (Phase 4)

Supabase Auth (email/password) gates the whole app. The frontend is already wired
(`frontend/src/lib/auth.jsx`, `views/Login`, session-gated `App.jsx`, logout in the topbar).
What remains is **project-side config that the MCP can't change** — do these in the Supabase
Dashboard for project `kkdbvzixwlyeahgianuc`.

## 0. Frontend env (already set locally)

`frontend/.env` has been created with the public values (anon key is public by design):

```
VITE_SUPABASE_URL=https://kkdbvzixwlyeahgianuc.supabase.co
VITE_SUPABASE_ANON_KEY=<legacy anon JWT>
```

## 1. ⚠️ CRITICAL — disable public signup

The auth model is **"shared staff": every `authenticated` user gets full CRUD** over invoices,
CUIT and cheques (RLS policy `staff_all`, migration 0002). The anon key is public, so **if
self-signup is left on, anyone on the internet could register and get full access.** Staff must
be **invite-only**.

**Dashboard → Authentication → Sign In / Providers → Email → turn OFF "Allow new users to sign up".**
(Equivalent setting: Authentication → Settings → "Allow new users to sign up" = off, i.e.
`GOTRUE_DISABLE_SIGNUP=true`.)

With signup off, users can only be created by an admin (below); `signInWithPassword` still works.

## 2. Create the staff user(s)

**Recommended — Dashboard:** Authentication → Users → **Add user** → enter email + password →
check **"Auto Confirm User"** (so no confirmation email is needed) → Create. Repeat per staff member.

**Alternative — SQL** (run in the Dashboard SQL editor, *not* through this chat, so the password
stays private). `crypt`/`gen_salt` (pgcrypto) are available in this project. Creates a
**confirmed** user + its email identity:

```sql
DO $$
DECLARE
  v_id    uuid := gen_random_uuid();
  v_email text := 'staff@empresa.com';   -- ← cambiar
  v_pass  text := 'CHANGE_ME';           -- ← cambiar; no commitear
BEGIN
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    -- GoTrue escanea estas columnas de token como `string`: deben ser '' (NUNCA NULL),
    -- si no el login falla con 500 "converting NULL to string is unsupported".
    confirmation_token, recovery_token, email_change_token_new, email_change,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token
  ) VALUES (
    v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    v_email, crypt(v_pass, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
    '', '', '', '', '', '', '', ''
  );
  INSERT INTO auth.identities (
    id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
  ) VALUES (
    gen_random_uuid(), v_id, v_id::text,
    jsonb_build_object('sub', v_id::text, 'email', v_email), 'email', now(), now(), now()
  );
END $$;
```

> Prefer the Dashboard path — it handles the `auth.identities` row and confirmation fields
> correctly across GoTrue versions. Only use the SQL insert if you must script it, and verify
> login afterwards.

## 3. Email confirmation (note)

Because staff are admin-created with **Auto Confirm**, no email delivery is required and you can
leave "Confirm email" as-is. If you ever create a user via `signUp` while "Confirm email" is ON,
that user can't log in until confirmed — so stick to admin-created + auto-confirm.

## 4. Verify end-to-end

1. `cd frontend && npm run dev` → open the LAN URL.
2. You should land on the **login screen** (no session ⇒ `anon` ⇒ RLS denies everything).
3. Log in with a staff user → the CRM loads; the topbar shows the email + **Salir**.
4. Reload → session persists (localStorage). Click **Salir** → back to the login screen.
5. Negative check: with signup disabled, attempting to register a new account fails.
