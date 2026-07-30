# Data migration — LAN Postgres → Supabase

> **Superseded as the data source (2026-07-28):** the live data now comes from **Tango**, not this
> LAN Postgres. See `TANGO_Migration.md`, which supersedes this file for *what* to load. This file
> is kept only for its reusable *load mechanics* — `session_replication_role=replica`, sequence
> reset, and the verify steps — which the Tango runbook still reuses.

Moves the **live** data from the current server PC's PostgreSQL into the Supabase project
`kkdbvzixwlyeahgianuc`. The structure is identical (same tables, same `SERIAL` PKs), so this is a
**data-only** copy — no schema translation.

> Runs **after all migrations `0001`–`0012` are applied** (empty tables + RPCs exist) and
> **instead of** `supabase/seed.sql` — the real `config_empresa` / `contadores` / `cuentas_bancarias`
> come from the live dump, and `contadores` is the source of truth for comprobante numbering, so it
> must cross over intact.
>
> Note: migration `0008` relaxed `notas.numero` uniqueness from global to per `(tipo, numero)` — a
> **looser** constraint, so live data that satisfied the old global-unique rule loads without conflict.
>
> **Do this at cutover**, when no one is writing to the LAN system, so numbering can't drift.

---

## 0. Prereqs

- `pg_dump` / `psql` (any machine that can reach the LAN Postgres for the dump, and the internet for the load).
- The Supabase **direct connection string**: Dashboard → Project Settings → Database → *Connection string* →
  **URI**. Looks like `postgresql://postgres:[PASSWORD]@db.kkdbvzixwlyeahgianuc.supabase.co:5432/postgres`.
  Export it: `export SUPABASE_DB_URL="postgresql://postgres:...@db...supabase.co:5432/postgres"`

## 1. Dump the live data (on the server PC)

```bash
pg_dump \
  --data-only \
  --schema=public \
  --no-owner --no-privileges \
  --exclude-table='schema_migrations' \
  -h localhost -U postgres -d crm_ventas \
  -f crm_data.sql
```

`--data-only` emits `COPY` blocks; `--schema=public` keeps it to our tables only. Transfer `crm_data.sql`
to the machine that has `$SUPABASE_DB_URL`.

## 2. Load into Supabase (FK checks + triggers deferred)

The `remitos ↔ facturas` circular FK and the `updated_at` triggers would fight a bulk load, so wrap the
import in `session_replication_role = replica` (bypasses FK validation and triggers for this session only):

```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 <<SQL
BEGIN;
SET session_replication_role = replica;
\i crm_data.sql
SET session_replication_role = origin;
COMMIT;
SQL
```

If any table already has seed rows (e.g. you accidentally ran `seed.sql`), `TRUNCATE ... RESTART IDENTITY CASCADE`
those tables first, or the `COPY` will hit PK conflicts.

## 3. Reset all `SERIAL` sequences

The `COPY` inserts explicit `id`s without advancing the sequences, so the next app insert would collide.
Re-sync every sequence in `public` to its table's `MAX(id)`:

```sql
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT s.relname AS seq, t.relname AS tbl, a.attname AS col
    FROM pg_class s
    JOIN pg_depend d   ON d.objid = s.oid AND d.deptype = 'a'
    JOIN pg_class t    ON t.oid = d.refobjid
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
    WHERE s.relkind = 'S' AND t.relnamespace = 'public'::regnamespace
  LOOP
    EXECUTE format(
      'SELECT setval(%L, COALESCE((SELECT MAX(%I) FROM %I), 1), (SELECT MAX(%I) IS NOT NULL FROM %I))',
      r.seq, r.col, r.tbl, r.col, r.tbl);
  END LOOP;
END $$;
```

`contadores` is keyed by `tipo` (not a sequence) — nothing to reset; its `ultimo_numero` values carried
over in step 2, so numbering resumes exactly where the LAN system left off.

## 4. Verify

Don't hand-roll checks — run the prepared verification script, which covers **all** tables/checks:
row counts (vs LAN), `contadores` numbering continuity, referential integrity (11 orphan checks),
sequence-vs-`MAX(id)` sanity (step 3 sanity), IVA-21% totals coherence, and RLS/`anon`/auth lockdown.
Two editions, same checks:

- **`supabase/POST_LOAD_VERIFY.sql`** — psql edition (`\echo` + a `RAISE NOTICE` `DO` block). Run with:
  ```bash
  psql "$SUPABASE_DB_URL" -f supabase/POST_LOAD_VERIFY.sql
  ```
- **`supabase/POST_LOAD_VERIFY_MCP.sql`** — single-query edition returning one `seccion | item | status | detalle`
  result set. Paste into the **Supabase dashboard SQL Editor**, or ask Claude to run it **via the Supabase MCP**
  once the load is done.

Scan the `status` column: everything should read `OK` / `ⓘ` except **`usuarios auth` until staff are created**
(`AUTH_SETUP.md §2`) — that one legitimately shows `⚠ FALTA staff` pre-signup. The row-count and
`max emitido` rows are marked `ⓘ` because you compare them by eye against the LAN DB (run the same counts there).

Then log in through the app (Auth/RLS) and open a client's cuenta corriente + issue one test comprobante
in a scratch client to confirm numbering and totals before going live.
