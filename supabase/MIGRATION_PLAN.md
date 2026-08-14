# Supabase Migration Plan — CRM Ventas

**Model:** Frontend → Supabase **directly** (supabase-js / PostgREST), full client adoption.
Express is **retired entirely** — PDF moves to a Supabase Edge Function. Because the anon key is
public in the browser, **Auth + Row-Level Security are mandatory** — this DB holds facturas, CUIT and cheques.

## Decisions (locked)

| Area | Decision |
|---|---|
| **Auth model** | **Shared staff** — every authenticated user gets full CRUD; `anon` denied. One login gate, no per-row ownership. |
| **Existing data** | **Migrate live LAN data** — dump current Postgres → load into Supabase at cutover. Runbook: `DATA_MIGRATION.md`. |
| **PDF** | **Edge Function** — port `routes/pdf.js` to a Supabase Edge Function; Express goes away completely. |
| **Totals** | Recomputed inside RPCs (authoritative, anti-tamper). |

## Target architecture

- **Frontend**: `@supabase/supabase-js` (`VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`), Supabase Auth
  (email/password), session-gated routes. Reads via PostgREST, writes via `.rpc()`.
- **Transactions → RPC**: every atomic comprobante op (numbering + header + N items + estado) is a
  `SECURITY DEFINER` Postgres function, reusing `siguiente_numero()` + `recalcular_estado_factura()`.
- **Totals in SQL**: `crm_calc_totales()` ports `utils/calculos.js` (IVA 21%) so the browser never sets a total.
- **Security**: RLS `FORCE`d on every table; `authenticated` full, `anon` none; RPCs `GRANT EXECUTE` to `authenticated` only.

## Applied status (project `kkdbvzixwlyeahgianuc`, via Supabase MCP)

Migrations `0001`–`0010` are **applied and verified live**. Each RPC family was smoke-tested against
the DB inside a self-aborting transaction (a final `RAISE` returns the computed values and rolls the
test data back, so the tables stay empty for the real data cutover). Confirmed live: 17 tables all
RLS-enabled + `staff_all` policy, 19 functions, `anon` can execute **0** of them.

| Migration | What | Status |
|---|---|---|
| `0001_schema` | Full schema port. Circular FK `remitos↔facturas` broken (facturas first, then `ALTER`). Functions + triggers + FK/partial indexes. No seed inserts. **`notas.numero` unique is now per `(tipo, numero)`** (see 0008). | ✅ applied |
| `0002_rls` | RLS enable, `staff_all` policy (authenticated-only), grants to `authenticated`, revokes from `anon`, default privileges. | ✅ applied |
| `0003_rpc_presupuestos` | `crm_calc_totales` + `crear_/actualizar_/set_estado` presupuesto RPCs — **the reference pattern**. Smoke-tested (nº, IVA 21%, vcto +7d). | ✅ applied + tested |
| `0004_harden_function_privileges` | **Fix:** `anon` could EXECUTE the SECURITY DEFINER write RPCs — Supabase default-privileges grant EXECUTE to `anon` directly and `REVOKE … FROM PUBLIC` doesn't remove it. Revokes from `anon`, pins `search_path` on the 5 helpers. | ✅ applied |
| `0005_rpc_remitos` | `crear_/actualizar_/anular` remito (+ presupuesto→convertido). Tested. | ✅ applied + tested |
| `0006_rpc_facturas` | `crear_/actualizar_/anular` factura. A/B numbering (`factura_a`/`factura_b`), links remito→facturado, anular releases remito. Tested (A nº `00002-00002001`). | ✅ applied + tested |
| `0007_rpc_notas` | `crear_nota` (NC/ND), inherits factura letra, recalcs factura estado. Tested (parcial→cobrada). | ✅ applied + tested |
| `0008_fix_notas_numero_unique` | **Fix:** pre-existing bug — `nota_credito`/`nota_debito` are separate counters both starting at `00002-00000001` but `notas.numero` was UNIQUE global → first NC and ND collide. Relaxed to UNIQUE `(tipo, numero)` (looser, live-load-safe). | ✅ applied |
| `0009_rpc_recibos` | `crear_recibo`: multi-medio (efectivo/transferencia/cheque/echeq) + multi-factura imputación + cheques cartera + recalc. Server computes total. Tested. | ✅ applied + tested |
| `0010_revoke_item_helpers_from_anon` | **Fix:** the item-insert helpers from 0005–0007 kept `anon` EXECUTE — the 0004 default-privilege revoke doesn't cover functions created later; only explicit per-function REVOKE does. | ✅ applied |
| `0011_rpc_reads_informes` | Read/informe RPCs (jsonb, byte-identical to the old Express JSON): `presupuestos_/remitos_/facturas_/notas_/recibos_list` (list+get+cross-table search+autovencer), `clientes_list` (saldo), `productos_actualizar_precios`, and all `informe_*` (dashboard, ventas, ranking clientes/deudores, remitos/facturas pendientes, cta-cte). SECURITY INVOKER, anon revoked. Smoke-tested + browser-verified. | ✅ applied + tested |
| `0012_pdf_list_fields` | **PDF port support:** the comprobante PDFs need the product `codigo` per item and the client `direccion` on notas (the old Express PDF queries joined `productos` / selected `direccion`; 0011 omitted both). Re-creates `presupuestos_/remitos_/facturas_/notas_list` adding `'codigo'` inside the items json (LEFT JOIN productos) and `c.direccion` to `notas_list`. Additive/backward-compatible; anon stays revoked (re-verified). | ✅ applied + verified |
| `0013_fiscal_afip_columns` | **Tango migration prep** (`TANGO_Migration.md` §5): adds nullable `cae`, `cae_vencimiento`, `afip_tipo_comprobante`, `afip_doc_tipo`, `afip_doc_nro` to `facturas` and `notas` so historical fiscally-issued Tango comprobantes preserve their CAE on import instead of discarding it. No app code reads/writes these yet — future AFIP module territory. Additive, tables were empty at apply time. | ✅ applied |
| `seed.sql` | Config seed for **fresh/dev only** (empresa, contadores, cuentas). Skipped in prod. | n/a (prod uses live data) |
| `DATA_MIGRATION.md` | pg_dump → load (FK/triggers deferred) → sequence reset → verify runbook. | ⏳ Phase 7 cutover |
| `frontend/src/lib/supabase.js`, `.env.example`, `package.json` | supabase-js singleton + `VITE_SUPABASE_*` + dep. | ✅ done |
| `frontend/src/api/index.js` | **Rewritten on supabase-js** — same per-resource signatures; reads/informes via `.rpc()`, comprobante writes via `.rpc()`, clientes/productos/cheques/config ABM via PostgREST. `client.js` (axios) now unused. | ✅ done + verified |
| `supabase/functions/pdf/` | **Edge Function** (`index.ts` + `base/templates/reportes.ts`) porting `routes/pdf.js`. Routes on the same `/pdf/<resource>/<id>` paths; reads via the 0011/0012 RPCs + `config_empresa` forwarding the caller JWT (RLS applies); pdfkit via `npm:pdfkit@0.15.0`. `verify_jwt=true`. Deployed (v1) + E2E-tested: presupuesto/ranking/ventas/cta-cte all return valid `%PDF` (código + cliente + totals render), no-auth → 401. | ✅ deployed + tested |
| `frontend/src/components/PDFModal/index.jsx` | Rewired: keeps the same `url` prop (`/api/pdf/...`), strips the prefix and fetches `{SUPABASE_URL}/functions/v1/pdf/<path>` with the session Bearer token + apikey. Views unchanged. `src/api/pdf.js` is now dead code. | ✅ done + verified |

**Rule learned (applies to every future RPC migration):** revoke EXECUTE from `PUBLIC, anon`
**explicitly on every function including helpers** — don't rely on `ALTER DEFAULT PRIVILEGES`.

## Applied status — expansion phases (post-cutover feature build)

The table above tracks the original **Express → Supabase migration** (Ventas, `0001`–`0013`). After
that, the CRM was extended sector by sector following `../system_plan.md` (see its **§3.1** for the
authoritative, prose implementation status of each phase). Those feature migrations are **also applied
to the same live project** and are summarized here per-block so this file stays the single source of
truth for "what's applied in the DB". They all follow the same conventions (shared-staff RLS **without**
`FORCE`, atomic `SECURITY DEFINER` write RPCs, `search_path` pinned, `anon` revoked, jsonb read/informe RPCs).

| Block | Migrations | What | Status |
|---|---|---|---|
| **Fase A — Compras + Procesos Generales** | `20260730120000`–`20260730120011` (12; internal `0100`–`0111`) | Schema Compras (proveedores, materiales, alícuotas IVA, facturas/remitos/notas de compra, pagos+retenciones), `cheques.proveedor_id` FK, **shared audit core** (`audit_log` + `audit_trigger()` + `tablas_generales`), RLS, RPCs (totales multi-alícuota, ABMs, comprobantes, pagos, reads/informes incl. Libro IVA Compras), + advisor fixes. E2E smoke-tested, then wiped. | ✅ applied + tested (2026-07-30) |
| **Fase B — Consultas 360° (Ventas/Compras)** | — (frontend only) | Fichas integrales por cliente/proveedor. **No DB migrations** — reuses existing `informe_*` / `*_list` RPCs. | ✅ done (2026-07-31) |
| **Fase C — Tesorería** | `20260731120000`–`20260731120007` (8; internal `0200`–`0207`) | Ledger central `movimientos_tesoreria` (± signo, saldo por `SUM`), `cheques_propios`, `conciliaciones_bancarias`, catálogos (agrupaciones, tipos de comprobante), ALTERs de `cuentas_bancarias`/`pago_proveedor_medios`, RLS, RPCs de escritura + integración ventas/compras→tesorería + `crear_transferencia`, informes jsonb, + advisor fix (revoca helper interno `tes_emitir_cobranza`). | ✅ applied (2026-07-31) |
| **Fase D — Consultas Tesorería + PDF + transferencias** | — (frontend + Edge Function) | Consultas 360° por cuenta + impresión + pantalla de transferencias. **No DB migrations.** ⏳ **Único pendiente: redeploy de la Edge Function `pdf`** con templates de tesorería (la desplegada es `v1`, ~2026-07-27, anterior a Tesorería). | 🔄 code-complete; PDF deploy pending |
| **Fase E — Núcleo contable** | `20260801120000`–`20260801120004` (5; internal `0300`–`0304`) | `plan_de_cuentas`, `asientos_contables`, `asiento_items` (+ trigger de balanceo diferido), RLS, `crear_asiento`/`anular_asiento` (manual, funciona), informes libro diario/mayor/sumas y saldos. **Aplicado con tablas vacías**; `generar_asiento_desde_*` aplicado pero **stub que lanza excepción** hasta validar la matriz de imputación (bloqueada en datos por Tango, igual que la Fase 7). **Frontend construido el 2026-08-14** (ver abajo). | ✅ applied empty (2026-08-01) |
| **Fase F/WS3 — IVA multi-alícuota en Ventas** | `20260802120000`–`20260802120002` (3) | `alicuota_iva_id` (nullable) en los 4 `*_items` de Ventas; `crear_/actualizar_` presupuesto/factura + `crear_nota` recalculando con `crm_calc_totales_multi_alicuota` (firmas idénticas ⇒ backward-compat: ítem sin alícuota ⇒ 21%); los `*_list` exponen `alicuota_iva_id` + `iva_porcentaje` por ítem. Smoke E2E: factura 21%+10.5% → total 2315. | ✅ applied + tested (2026-08-01) |
| **Fase F/WS2 — Ventas → Contabilidad (enganche)** | `20260803120000`–`20260803120001` (2) | `generar_asiento_desde_nota` (stub, como los de `0303`), `generar_asientos_ventas_pendientes` (backfill idempotente por `(referencia_tipo, referencia_id)`), disparo automático como **CONSTRAINT TRIGGER diferido** en `facturas`/`notas` guardado por `config_empresa('contabilidad_auto_asientos')`, + los 2 flags de config (`'off'` / `''`). Con el flag apagado es un **no-op**: no cambia el comportamiento actual. | 📝 escritas, **NO aplicadas** — la base no respondía el 2026-08-14 |

> Nota de contexto: estas fases construyen funcionalidad **sobre** el cutover, no lo reemplazan. El
> **bloqueo raíz sigue siendo el mismo** (credenciales del SQL Server de Tango): frena tanto la carga de
> datos live (Fase 7, abajo) como poblar `plan_de_cuentas` + la matriz contable (Fase E).

### Estado al 2026-08-14

- ✅ **Todo el código de las Fases A–F está commiteado y pusheado** a `origin/main`
  (`N-dossantos/CRM-marblock`) en 6 commits. Hasta esta fecha vivía **sólo en el disco del
  desarrollador**: `origin/main` tenía únicamente el módulo Ventas, así que la producción de Vercel
  servía una versión sin Compras/Tesorería/Consultas y las migraciones ya aplicadas no tenían backup
  en git.
- ✅ **Frontend de Contabilidad construido** (Fase E §8 paso 5, el único paso de esa lista que no
  depende de Tango): `PlanCuentasAPI` + `AsientosAPI` + `InformesAPI.{libroDiario,libroMayor,sumasYSaldos}`
  en `frontend/src/api/index.js`, vistas `ContabilidadPlanCuentas` / `ContabilidadAsientos`,
  `components/Forms/AsientoForm.jsx` (líneas debe/haber con preview de balanceo), 2 rutas
  `/contabilidad/*`, sección "Contabilidad" en el menú y 3 pestañas nuevas en `Informes`.
  `npm run build` OK. **Sin verificar contra la base** (ver abajo).
- ⏳ **La base `kkdbvzixwlyeahgianuc` no respondía** el 2026-08-14: toda consulta SQL vía MCP devuelve
  `Connection terminated due to connection timeout` y `get_advisors` devuelve lista vacía (cuando
  históricamente devolvía ~28 WARN by-design). Última actividad registrada: 2026-08-02. El patrón
  encaja con un **proyecto pausado por inactividad** — confirmar y restaurar en el dashboard.
  Bloquea: aplicar `20260803*`, el smoke test del frontend contable, y el deploy de la Edge Function.
- ⏳ **Sigue pendiente el redeploy de la Edge Function `pdf`** (Fase D + Fase F/WS3). Verificado en
  vivo: la desplegada es `version 1` (~2026-07-27, anterior a Tesorería), mientras el código local ya
  tiene los 6 casos de tesorería y el desglose multi-alícuota.

## Phases

0. **Enable MCP** — ✅ **done.** Supabase MCP active against `kkdbvzixwlyeahgianuc`.
1. **DB foundation** — ✅ **done.** `0001` applied; 17 tables, 55 indexes, functions + triggers live.
2. **RLS** — ✅ **done.** `0002` applied; `staff_all` (authenticated-only), `anon` denied. Verified `anon` executes 0 functions.
3. **RPC functions** — ✅ **done.** `0003` presupuestos (reference), `0005` remitos, `0006` facturas, `0007` notas, `0009` recibos — all applied + tested live. Hardening: `0004`, `0010`; bug fix: `0008`.
4. **Auth** — ✅ **frontend done + verified E2E**, ⏳ **project config pending (manual)**. Built: `AuthProvider`+`useAuth` (`src/lib/auth.jsx`), `views/Login`, session-gated `App.jsx` (loading → login → CRM), logout in the topbar, `main.jsx` wrapped in `AuthProvider`, `frontend/.env` set. **Verified end-to-end in the browser** with a throwaway user: gate → login → session persists on reload → logout. (Surfaced the GoTrue gotcha: SQL-created users need the token columns = `''`, not NULL — captured in `AUTH_SETUP.md`.) **Remaining (dashboard, can't do via MCP — see `AUTH_SETUP.md`): ⚠️ disable public signup (critical for the shared-staff model) + create the real staff user(s).**
5. **Frontend data layer** — ✅ **done + browser-verified.** `src/api/index.js` rewritten on supabase-js with the **same per-resource signatures** (views unchanged): reads/informes + comprobante writes via `.rpc()` (migration 0011 + the write RPCs), clientes/productos/cheques/config ABM via PostgREST. `PRESUPUESTO_VENCIDO` 422 semantics preserved. E2E: login → dashboard (no 500s) → create cliente → create presupuesto (nº `00002-00000001`, IVA 21%, vencimiento +7d), console clean; test data wiped after. `client.js` (axios) is now dead code.
6. **PDF Edge Function** — ✅ **done + E2E-tested.** Ported `routes/pdf.js` → `supabase/functions/pdf/` (`index.ts` router + `base/templates/reportes.ts`). **pdfkit runs fine under Deno via `npm:pdfkit@0.15.0`** (the flagged risk — no rewrite needed). Reads data through the 0011/0012 RPCs + `config_empresa`, forwarding the caller JWT so RLS applies. `PDFModal` now fetches `{SUPABASE_URL}/functions/v1/pdf/<path>` with the session token; views still pass the same `/api/pdf/...` strings (no view edits). Deployed (v1, `verify_jwt=true`) and verified end-to-end with a throwaway user + temp data: presupuesto (código/cliente/totales render), ranking-deudores, ventas, cta-cte all return valid `%PDF`; no-auth request → 401. Test data + user wiped afterwards (DB back to empty).
7. **Cutover** — 🔄 **in progress. DB side verified ready (2026-07-28); remaining steps are user-run (LAN + private creds + dashboard).**
   - ✅ **Pre-cutover DB verification (via MCP):** all 13 migrations `0001–0013` applied (including `0013_fiscal_afip_columns`); **17/17 tables RLS-enabled + `staff_all` policy**, 33 public functions, **`anon` executes 0 functions / selects 0 tables**, PDF Edge Function `pdf` ACTIVE (`verify_jwt=true`). Security advisors return only the **expected/by-design** warns — `rls_policy_always_true` ×17 (the shared-staff `USING(true)` policy) and `authenticated_security_definer_function_executable` ×11 (the write RPCs are meant to be `authenticated`-callable) — no action items.
   - ✅ **DB is pristine for the live load:** removed a leftover test product (`productos` id=2 from earlier smoke-testing) + reset its sequence; **all 17 tables now empty**, `auth.users`=0. No PK-conflict landmines for the `COPY` load.
   - ⏳ **Remaining (only the user can run these):** ① **Load live data — source is now Tango, not the LAN Postgres. See `TANGO_Migration.md` (supersedes `DATA_MIGRATION.md`): full replacement, Tango Gestión/SQL-Server → CSV/`.bak` → scripted ETL → load (`session_replication_role=replica`) → reset sequences → set `contadores` → §4 verify (`POST_LOAD_VERIFY_MCP.sql`).** Currently blocked on Tango schema discovery (`supabase/tango_discovery.sql`, ready to run) — as of 2026-07-28 further stuck on the user not having a working SSMS/SQL Server credential for the Tango instance (see `TANGO_Migration.md` §7 for recovery options). ② Dashboard auth per `AUTH_SETUP.md`: **disable public signup** + **create real staff user(s)**.
   - ✅ **Express retired (2026-07-28, at user direction — ahead of the original "after go-live smoke-test" ordering):** deleted `backend/`, `frontend/src/api/client.js`, `frontend/src/api/pdf.js`, and the stale `VITE_API_URL` pointer in `frontend/.env.example`. Frontend had zero remaining references (verified). ⚠ **Consequence:** the cutover rollback path is now **LAN Postgres only** — the Express API no longer exists in the tree and there is no git backup, so if the Supabase go-live hits a blocker, fall back to the still-running LAN stack rather than this repo.

## Next action

Phases 1–6 complete and verified. **Phase 7 cutover is DB-ready** (migrations `0001–0012` applied,
RLS/functions/anon-lockout/edge-function all verified, tables pristine — see the Phase 7 entry
above). The remaining steps need LAN access, the private DB password, or the dashboard, so **the user
runs them**, in this order:

1. **Load live data** — source is now **Tango**, not the LAN Postgres. Follow `TANGO_Migration.md`
   (supersedes `DATA_MIGRATION.md`): Tango Gestión/SQL-Server → CSV/`.bak` → scripted ETL → load
   (wrapped in `session_replication_role=replica`) → reset sequences → set `contadores` → verify
   (`POST_LOAD_VERIFY_MCP.sql`). `DATA_MIGRATION.md` is kept only for its reusable load mechanics
   (the `session_replication_role`/sequence-reset/verify steps), not as the data source. Keep the
   connection URI/password **out of chat** (put it in a gitignored file).
2. **Dashboard auth** — `AUTH_SETUP.md`: ⚠️ **disable public signup** (critical for shared-staff) + **Add user** (Auto Confirm) for each staff member.
3. **Go-live smoke-test** — log in through the app; exercise every module clientes → presupuestos → remitos → facturas → notas → recibos, informes, and **PDF buttons**; confirm numbering continues from `contadores` and totals/IVA are correct.
4. **Retire Express** — ✅ **done (2026-07-28, at user direction, ahead of the smoke-test).** Deleted `backend/`, `frontend/src/api/client.js`, `frontend/src/api/pdf.js`; removed the stale `VITE_API_URL` line from `frontend/.env.example`. ⚠ Because this happened *before* the live-data load, the only cutover fallback is now the LAN Postgres (Express is gone from the tree, no git backup). Post-load verification is prepped: `supabase/POST_LOAD_VERIFY_MCP.sql` (MCP / SQL-Editor) + `POST_LOAD_VERIFY.sql` (psql).

Offer available: once the dump is loaded, the Supabase-side verification queries (row counts, numbering, orphan check) can be run here via MCP.
