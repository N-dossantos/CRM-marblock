# Tango → Supabase data migration (CRM Ventas)

**Status: v1 — key decisions locked 2026-07-28; fiscal-fields migration applied 2026-07-28; blocked
on Tango schema discovery (see §7) — user currently lacks the SSMS/SQL Server credential.**

**Locked decisions:**
- **Full replacement.** Tango is being **retired** — CRM-Ventas becomes the sole system of record.
  Migrate **all history** (every sales entity, years back), not just open balances.
- **Source: Tango Gestión (desktop) on Microsoft SQL Server**, via direct DB access (`.bak` restore
  or a read-only connection) → extraction path **A** (§3).
- **Volume is small** (< ~1k clientes, < ~10k comprobantes) → a scripted ETL (Python/SQL) is ample;
  no batching/sharding concerns.
- **CRM-Ventas issues new comprobantes going forward** → `contadores` must resume after Tango's last
  number per tipo/punto de venta.
- **AFIP/CAE electronic issuing is a FUTURE build** (separate project), but historical Tango invoices
  already carry CAE — so we **preserve the fiscal fields on import** now (§5) rather than re-migrate
  later.

## 1. Goal & context

The company's live operational data lives in **Tango** (Axoft, Gestión desktop / SQL Server). We're
**fully replacing Tango** with CRM-Ventas on **Supabase** (`kkdbvzixwlyeahgianuc`) — so **all** the
sales-side data and history migrates, and after cutover Tango is retired.

**Tango is the source of truth for the live load — this file supersedes `DATA_MIGRATION.md`** (that
runbook targeted a dump of the old LAN Postgres CRM, which was the *development* database of this very
system, not the company's real data). Keep `DATA_MIGRATION.md` only for its reusable load mechanics
(`session_replication_role`, sequence reset, verification) referenced in §6.

## 2. Scope boundary — what the target can actually hold

The Supabase schema today models **only the sales side**. Migrating data that has no target table is
out of scope until those modules exist (Compras/Stock/Tesorería are on the roadmap, not built).

| In scope (has a target table) | Out of scope (no target yet) |
|---|---|
| Clientes, Productos/Artículos | Proveedores, Compras, Órdenes de compra |
| Presupuestos, Remitos, Facturas A/B, Notas C/D, Recibos | Stock / movimientos de inventario |
| Cheques (cartera), Cuentas bancarias, Config empresa, Contadores (numeración) | Tesorería / caja-bancos, Asientos contables |

## 3. Extraction method — **A. Direct SQL Server (locked)**

Tango Gestión keeps its data in **Microsoft SQL Server**, and you have direct access, so we take the
highest-fidelity path: read the source tables directly and script the ETL. (Paths B/Excel-Tango-Live
and C/Delta are not used.)

**Practical flow, given the data is on your LAN (I can't reach it from here):**
1. **Schema discovery first** — you run the discovery queries in §7 on the Tango DB (SSMS) and share
   the output (table + column list + row counts). Tango's schema is proprietary with cryptic table
   codes (`GVA*` for ventas, `STA*` for stock/artículos, etc.), so we confirm the real source
   tables/columns from *your* instance rather than guessing them.
2. From that I produce the exact **source→target column mapping** and an **export spec**.
3. You export those tables to CSV (`bcp` / SSMS "Export Data"), or restore the `.bak` where the CSVs
   can be produced, and place the CSVs in a local folder on this Mac.
4. I write + run the **ETL** (Python) that transforms the CSVs and loads them into Supabase via the
   direct connection (`psql` / `COPY`). Connection URI/password stay in a **gitignored** file, out of
   chat.

## 4. Proposed entity mapping (Tango → target Supabase table)

Field names below are the **target** columns (confirmed from the live schema). The Tango-side source
columns get filled in once we see your export/schema — names differ by version.

| Tango entity | → target table(s) | Key target columns to fill | Notes / gotchas |
|---|---|---|---|
| Clientes | `clientes` | `razon_social`, `cuit`, `condicion_iva`, `direccion`, `localidad`, `provincia`, `telefono`, `email`, `descuento_porcentaje`, `activo` | `cuit` + `condicion_iva` are NOT NULL — need a default for clientes sin CUIT (consumidor final). Map Tango's condición IVA codes → our text values. |
| Artículos | `productos` | `codigo`, `descripcion`, `precio_sin_iva`, `activo` | **Price must be VAT-exclusive.** If Tango stores list price **with** IVA, divide by 1.21 on import. `codigo` unique. |
| Presupuestos (+ renglones) | `presupuestos` + `presupuesto_items` | header: `numero`, `punto_venta`, `numero_comp`, `fecha`, `fecha_vcto`, `cliente_id`, totals, `estado`; items: `descripcion`, `cantidad`, `precio_unitario`, `subtotal`, `orden` | See "numbering" + "totals" gotchas below. |
| Remitos (+ renglones) | `remitos` + `remito_items` | `numero`, `punto_venta`, `numero_comp`, `fecha`, `cliente_id`, `estado`, optional `factura_id`/`presupuesto_id` links | Remitos carry no money in our schema. |
| Facturas A/B (+ renglones) | `facturas` + `factura_items` | `numero`, `punto_venta`, `numero_comp`, `tipo` (`factura_a`/`factura_b`), `fecha`, `cliente_id`, `neto_gravado`, `iva_alicuota`, `iva_monto`, `total`, `estado` | `tipo` is char code. **No CAE column** — the schema doesn't store AFIP authorization (see §5). `estado` (pendiente/parcial/cobrada) depends on whether you also load cobranzas. |
| Notas Crédito/Débito (+ renglones) | `notas` + `nota_items` | `numero`, `punto_venta`, `numero_comp`, `tipo` (`nota_credito`/`nota_debito`), `tipo_letra`, `fecha`, `factura_id`, totals | **Always linked to a factura** (`factura_id` NOT NULL) — the source NC/ND must resolve to a migrated factura, else it's an orphan. |
| Recibos / Cobranzas | `recibos` + `recibo_medios` + `recibo_facturas` | recibo: `numero`, `punto_venta`, `numero_comp`, `fecha`, `cliente_id`, `total`; medios: `tipo`, `monto` (+ cheque fields); imputaciones: `factura_id` | Multi-medio + multi-factura. Only feasible in full fidelity if the source has the payment breakdown + which facturas each receipt cancelled. |
| Cheques en cartera | `cheques` | `numero`, `tipo`, `banco`, `titular`, `cuit_titular`, `fecha_emision`, `fecha_vcto`, `monto`, `estado`, optional `cliente_id` | Bring only cheques still in cartera (not yet deposited/entregados) if you only want open items. |
| Cuentas bancarias / empresa | `cuentas_bancarias`, `config_empresa` | — | Usually re-entered by hand; small. |
| Numeración (últimos números emitidos) | `contadores` | `tipo`, `punto_venta`, `ultimo_numero` | Must continue **after** the last number Tango issued per type/punto de venta (see §5). |

**Two column shapes to know:** every comprobante has both `numero` (varchar, the formatted
`PPPPP-NNNNNNNN` string) **and** `numero_comp` (integer, the numeric part). Both get set on import.
`id` is a SERIAL — we let Postgres assign new ids and wire the FKs (cliente_id, factura_id, …) by
those new ids during ETL (Tango's own ids don't need to survive).

## 5. Design decisions this migration forces

- **Historical comprobantes load by direct INSERT, not through the RPCs.** The `crear_*` RPCs mint a
  fresh number from `contadores`; historical rows already have their numbers. So we insert them
  directly (preserving `numero`/`punto_venta`/`numero_comp`/`fecha`), exactly like `DATA_MIGRATION.md`
  does — then set each `contadores.ultimo_numero` to continue after the last migrated number so the
  next in-app issuance can't collide.
- **Numbering continuity ⇄ who issues going forward.** If CRM-Ventas becomes the system that issues
  new comprobantes, `contadores` must resume from Tango's last per punto de venta. If Tango keeps
  issuing (and this is reporting only), continuity matters less.
- **Fiscal (AFIP/CAE) — preserve now, issue later. ✅ Applied 2026-07-28** (migration
  `20260728120000_fiscal_afip_columns`). You plan to issue **fiscal** invoices from CRM-Ventas
  eventually (CAE + AFIP web-service integration) — a **separate future build**, not this migration.
  But your historical Tango facturas were fiscally issued and **carry CAE / vto-CAE /
  tipo-comprobante-AFIP / punto de venta**. `facturas` and `notas` now have nullable columns `cae`,
  `cae_vencimiento`, `afip_tipo_comprobante`, `afip_doc_tipo`, `afip_doc_nro` so history is preserved
  on import and the future AFIP module has somewhere to write. NULL until then; no app code reads or
  writes them yet.
- **Totals are recomputed/verified as VAT-exclusive + 21%.** `POST_LOAD_VERIFY` checks
  `round(neto*0.21,2)=iva` and `neto+iva=total`. Tango data that used a different alícuota, rounding,
  or VAT-inclusive prices will surface here and needs a mapping rule.
- **Open-items vs full-history is the big scope lever** (see §7 Q2): master data + open balances is a
  fraction of the effort of loading years of closed comprobantes.

## 6. Load mechanics (once mapping + scope are locked)

Mirrors `DATA_MIGRATION.md` so the same verification applies:

1. **Extract** from Tango (method A/B/C) → raw CSV/SQL per entity.
2. **Transform** into `COPY`-ready data matching the target columns (resolve FKs to new ids, fix
   VAT-exclusive prices, map códigos de condición IVA / tipo, parse Argentine date/number formats).
3. **Load** into Supabase wrapped in `SET session_replication_role = replica;` (defers the circular
   `remitos↔facturas` FK + `updated_at` triggers), in dependency order
   (clientes/productos → presupuestos → remitos → facturas → notas → recibos → cheques).
4. **Reset sequences** to `MAX(id)` per table (the `DO $$` block in `DATA_MIGRATION.md §3`).
5. **Set `contadores`** per tipo/punto de venta to the last issued number.
6. **Verify** with `POST_LOAD_VERIFY_MCP.sql` (row counts vs Tango, numbering continuity, 0 orphans,
   sequences OK, IVA 21% coherence, RLS/anon/auth) + a login-and-issue-one-test smoke check.

We'll dry-run the load into the (currently empty) Supabase with a small sample first, verify, wipe,
then do the real cutover load.

## 7. Status & next step — Tango schema discovery

**Answered (2026-07-28):** SQL-Server / Gestión · full history · CRM-Ventas issues going forward
(Tango retired) · AFIP fiscal issuing is a future build · small volume. (See "Locked decisions" at the
top.)

**Fiscal-fields migration (§5):** ✅ applied 2026-07-28 — no longer open.

**Immediate blocker — Tango schema discovery, and it's currently stuck on credentials.** As of
2026-07-28 the user doesn't have a working SQL Server login for SSMS against the Tango instance
(forgotten password) — so §7's discovery queries can't run yet. This is a LAN/organizational-access
problem outside what an assistant without LAN access can resolve directly; options worth checking,
roughly cheapest first:

1. **Windows Authentication instead of SQL auth.** If the SQL Server instance has Windows/Integrated
   Auth enabled and the Windows account you're logged in as (or another admin account you can use) has
   a mapped login, SSMS can connect with *no separate SQL password* — pick "Windows Authentication" in
   the SSMS connect dialog instead of "SQL Server Authentication".
2. **Tango's own stored connection.** The Tango Gestión client itself must authenticate to this same
   SQL Server to run day-to-day — its install often keeps the connection profile (server, DB, login)
   in a local config/`.ini` file or the Windows registry under the Tango install directory. Worth a
   look before escalating.
3. **Ask whoever provisioned it.** Whoever installed Tango/SQL Server (internal IT, or the Axoft/Tango
   reseller that sold the license) likely has the `sa` password or can issue you a new read-only login
   — usually the fastest real fix.
4. **Password manager / handoff notes** from a previous admin, if any exist.
5. **Last resort — local admin reset.** If you have Windows admin rights on the machine running SQL
   Server (RDP or physical access), the `sa` password can be reset by starting the SQL Server service
   in single-user mode (`sqlservr.exe -m`) and running `ALTER LOGIN sa WITH PASSWORD = '...'` via
   `sqlcmd`. This needs OS-level admin and a maintenance window (SQL Server service restart) — say the
   word if this is the path and I'll write out the exact commands.

Once you're in, run these read-only metadata queries in SSMS against the Tango database and send me
the results (CSV or paste):

```sql
-- (a) All tables + columns — so we can map source → target
SELECT c.TABLE_NAME, c.ORDINAL_POSITION, c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH
FROM INFORMATION_SCHEMA.COLUMNS c
JOIN INFORMATION_SCHEMA.TABLES t
  ON t.TABLE_NAME = c.TABLE_NAME AND t.TABLE_TYPE = 'BASE TABLE'
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;

-- (b) Row counts per table — so we spot the tables that actually hold data
SELECT s.name AS schema_name, t.name AS table_name, SUM(p.rows) AS filas
FROM sys.tables t
JOIN sys.schemas s     ON s.schema_id = t.schema_id
JOIN sys.partitions p  ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY s.name, t.name
HAVING SUM(p.rows) > 0
ORDER BY filas DESC;
```

Also tell me whether you'll share a **`.bak`** or produce **CSV exports**; and a **sample** of one
factura + its renglones + its cliente lets me nail the mapping fast.

With (a)+(b) I'll: identify the real Tango source tables, fill the source column in the §4 mapping,
write the fiscal-fields migration (if approved), and build the ETL — then dry-run a sample load into
the (empty) Supabase, verify, and schedule the full cutover.
