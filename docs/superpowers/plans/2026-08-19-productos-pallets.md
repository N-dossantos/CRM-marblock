# Productos por Pallets — catálogo + carga por pallets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load the real 23-product Marblock catalog (+ two special line items: Pallet de Madera
Vacío and Servicio de Transporte) into `productos`, and let every Ventas/Cuenta 2 comprobante grid
enter quantities as **pallets** (auto-computing total units), search products by typing their short
numeric ID or free text, and auto-maintain a "Pallet de Madera Vacío" line summing the pallets of
the other items.

**Architecture:** DB-first: add `unidades_por_pallet` / `es_pallet_vacio` / `es_transporte` to
`productos`, seed the 25 rows, and add `pallets` + `unidades_por_pallet` to every Ventas + Cuenta 2
item table so a saved comprobante can be re-opened with its pallet breakdown intact. The write/read
RPCs are additive (`CREATE OR REPLACE`, same signatures, existing grants persist automatically).
On the frontend, the shared `ItemsTable` (`src/components/UI/index.jsx`) gets a native
`<input list>`/`<datalist>` product combobox (avoids fighting `.modal-body`'s `overflow-y:auto` and
`.items-table-wrap`'s `overflow:hidden`, which would clip a hand-rolled absolute-positioned
dropdown) plus a Pallets/Unidades column split, and a new `usePalletsVacios` hook (used by
`ComprobanteForm` and `RemitoXForm`, the two forms productos.md names) keeps the wood-pallet line in
sync unless the user edits or removes it.

**Tech Stack:** React 18 + Vite frontend, Supabase Postgres (SECURITY DEFINER RPCs), no test/lint
tooling in `frontend/` — verification is `npm run dev` + manual flow exercise, and direct SQL via
the Supabase MCP for DB-layer tasks.

**Spec:** `productos.md` (repo root of `crm-tango`) — sections 1–4 (requirements, product table,
DB/UI spec, implementation prompt).

## Global Constraints

- **Catalog is exactly the 23 rows in productos.md §2 + 2 specials**, `codigo` = bare `'1'..'25'`
  (not zero-padded) — matches "IDs Cortos y Únicos: acceso rápido mediante números enteros simples."
- **`productos` gets exactly the three columns from productos.md §3.1.1**: `unidades_por_pallet
  INTEGER NOT NULL DEFAULT 1`, `es_pallet_vacio BOOLEAN NOT NULL DEFAULT FALSE`, `es_transporte
  BOOLEAN NOT NULL DEFAULT FALSE`.
- **Item tables get `pallets INTEGER` (nullable — legacy rows have none) + `unidades_por_pallet
  INTEGER NOT NULL DEFAULT 1`** on `presupuesto_items`, `factura_items`, `remito_items`,
  `cuenta2_remito_items` (named in productos.md §3.1.2, under their real singular table names —
  the doc's plural names don't exist in this schema) **and `nota_items`**, added because `NotaForm`
  (`src/views/Notas/NotaForm.jsx`) uses the same shared `ItemsTable`; leaving it out would make the
  grid show a Pallets input that silently doesn't persist.
- **`cantidad` stays `DECIMAL(10,3)` — do not change its column type to INTEGER.** productos.md
  §1's "Sin Decimales" requirement is enforced application-side: the frontend always writes
  `pallets × unidades_por_pallet`, which is inherently a whole number, into the existing column. No
  migration touches `cantidad`'s type.
- **`precio_unitario` is always per-unit, never scaled by `unidades_por_pallet`.** Only `cantidad`
  (total units) and the totals math derive from pallets; price entry is unaffected.
- **Out of scope, do not touch:** `supabase/functions/pdf/*` (PDFs print `it.cantidad` directly —
  already correct, no pallets-aware rendering needed), the Compras domain (`CompraComprobanteForm`,
  `materiales`, `factura_compra_items`/etc. — separate catalog, separate items UI, not part of
  productos.md), `productos_actualizar_precios` (bulk % price increase — unaffected by pallets).
- **Accepted side effect:** `ItemsTable`'s readonly mode is also used by
  `src/views/ComprasNotas/index.jsx` (Compras domain). Adding the Pallets/Unidades columns there
  shows a harmless `—` Pallets column for Compras items (which never populate `pallets`) — not
  worth a new prop to hide it for one read-only view.
- **Supabase project `kkdbvzixwlyeahgianuc`; migrations applied via `mcp__supabase__apply_migration`
  (never Docker/local Postgres, per this repo's CLAUDE.md).** Both migration files below must also
  be written to `supabase/migrations/` with matching filenames so they're tracked in git.
- **No frontend lint/test tooling.** Verify frontend tasks with `npm run dev` (from `frontend/`) and
  exercising the flow in the browser, per `frontend/CLAUDE.md`. Verify DB tasks with
  `mcp__supabase__execute_sql`.

---

### Task 1: DB schema — `productos` columns, item-table columns, seed the 25-row catalog

**Files:**
- Create: `supabase/migrations/20260819120000_productos_pallets_schema.sql`

**Interfaces:**
- Produces: `productos.unidades_por_pallet` (int, default 1), `productos.es_pallet_vacio` (bool),
  `productos.es_transporte` (bool); `pallets`/`unidades_por_pallet` columns on
  `presupuesto_items`/`factura_items`/`remito_items`/`nota_items`/`cuenta2_remito_items`; 25 rows in
  `productos` with `codigo IN ('1'..'25')`. Task 2 reads/writes these columns from RPC bodies.

- [ ] **Step 1: Write the migration file**

Context gathered from the live DB before writing this: `productos` currently has exactly one row —
`id=1, codigo='01', descripcion='Bloque Liso de 20 Portante', precio_sin_iva=1572.08` — a leftover
smoke-test row. It is **not safe to delete**: `cuenta2_remito_items` already has 3 real rows with
`producto_id=1` (live Cuenta 2 data, `ON DELETE SET NULL` would silently orphan them). The migration
fixes that row's `codigo` to `'1'` in place instead of deleting it, then upserts the rest by
`codigo` so it's idempotent and safe to re-run.

```sql
-- =============================================================
-- CRM Ventas — productos.md: catálogo de 23 bloques/adoquines + 2 ítems especiales, y venta por
-- pallets. Agrega unidades_por_pallet/es_pallet_vacio/es_transporte a `productos` (spec §3.1.1) y
-- pallets/unidades_por_pallet a cada tabla de ítems de comprobante (spec §3.1.2, + nota_items:
-- comparte ItemsTable con presupuestos/remitos/facturas) para poder reconstruir el desglose
-- pallets/unidades al reabrir un comprobante ya guardado.
-- Idempotente: ADD COLUMN IF NOT EXISTS + INSERT ... ON CONFLICT (codigo) DO UPDATE.
-- =============================================================

ALTER TABLE public.productos
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS es_pallet_vacio      BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS es_transporte        BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.presupuesto_items
  ADD COLUMN IF NOT EXISTS pallets INTEGER,
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1;
ALTER TABLE public.factura_items
  ADD COLUMN IF NOT EXISTS pallets INTEGER,
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1;
ALTER TABLE public.remito_items
  ADD COLUMN IF NOT EXISTS pallets INTEGER,
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1;
ALTER TABLE public.nota_items
  ADD COLUMN IF NOT EXISTS pallets INTEGER,
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1;
ALTER TABLE public.cuenta2_remito_items
  ADD COLUMN IF NOT EXISTS pallets INTEGER,
  ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1;

-- La fila id=1 es un remanente de smoke-test (codigo '01') que YA tiene ítems reales de Cuenta 2
-- apuntando a producto_id=1 — no se puede borrar sin desvincular esos ítems (ON DELETE SET NULL).
-- Se corrige en el lugar para que pase a ser el producto '1' real; el UPSERT de abajo la completa.
UPDATE public.productos SET codigo = '1' WHERE id = 1 AND codigo = '01';

INSERT INTO public.productos
  (codigo, descripcion, precio_sin_iva, unidades_por_pallet, es_pallet_vacio, es_transporte, activo)
VALUES
  ('1',  'Bloque Liso de 19x19x39 Portante',        1572.08, 105, FALSE, FALSE, TRUE),
  ('2',  'Bloque Medio de 19x19x19 Liso',            1169.76, 180, FALSE, FALSE, TRUE),
  ('3',  'Bloque Dintel de 19x19x39 Liso',           2025.32, 105, FALSE, FALSE, TRUE),
  ('4',  'Bloque Liso de 19x19x39 Estandar',         1405.41, 105, FALSE, FALSE, TRUE),
  ('5',  'Bloque Media Altura de 19x9,5x39 Liso',     837.13, 150, FALSE, FALSE, TRUE),
  ('6',  'Bloque Liso de 14x19x39 Portante',         1237.13, 150, FALSE, FALSE, TRUE),
  ('7',  'Bloque Medio de 14x19x19 Liso',             919.45, 252, FALSE, FALSE, TRUE),
  ('8',  'Bloque Dintel de 14x19x39 Liso',           1524.90, 150, FALSE, FALSE, TRUE),
  ('9',  'Bloque Liso de 14x19x39 Estandar',         1112.96, 150, FALSE, FALSE, TRUE),
  ('10', 'Bloque Liso de 9x19x39',                   1146.91, 210, FALSE, FALSE, TRUE),
  ('11', 'Bloque de 19x19x39 Split',                 2697.25, 105, FALSE, FALSE, TRUE),
  ('12', 'Bloque de 19x19x39 Split Esquinero',       3096.75, 105, FALSE, FALSE, TRUE),
  ('13', 'Bloque Dintel de 19x19x39 Split',          3096.75, 105, FALSE, FALSE, TRUE),
  ('14', 'Bloque Medio de 19x19x39 Split',           1622.72, 180, FALSE, FALSE, TRUE),
  ('15', 'Bloque Medio de 19x19x39 Split Esquinero', 1840.96, 180, FALSE, FALSE, TRUE),
  ('16', 'Bloque de 14x19x39 Split',                 2472.48, 150, FALSE, FALSE, TRUE),
  ('17', 'Plaqueta de 7x19x39 Split',                2065.97, 216, FALSE, FALSE, TRUE),
  ('18', 'Adoquin Inter-trabado de 11x21x8',          537.82, 528, FALSE, FALSE, TRUE),
  ('19', 'Adoquin Inter-trabado de 11x21x6',          413.70, 624, FALSE, FALSE, TRUE),
  ('20', 'Adoquin Holanda de 10x20x8',                439.71, 600, FALSE, FALSE, TRUE),
  ('21', 'Adoquin Holanda de 10x20x6',                353.05, 720, FALSE, FALSE, TRUE),
  ('22', 'Cubremuros 26x19x4,5',                     1154.50, 256, FALSE, FALSE, TRUE),
  ('23', 'Cordon 28x13x50',                         11020.73,  56, FALSE, FALSE, TRUE),
  ('24', 'Pallet de Madera Vacío',                    4000.00,   1, TRUE,  FALSE, TRUE),
  ('25', 'Servicio de Transporte',                  300000.00,   1, FALSE, TRUE,  TRUE)
ON CONFLICT (codigo) DO UPDATE SET
  descripcion         = EXCLUDED.descripcion,
  precio_sin_iva       = EXCLUDED.precio_sin_iva,
  unidades_por_pallet  = EXCLUDED.unidades_por_pallet,
  es_pallet_vacio      = EXCLUDED.es_pallet_vacio,
  es_transporte        = EXCLUDED.es_transporte,
  activo               = TRUE,
  updated_at           = NOW();
```

- [ ] **Step 2: Apply the migration via the Supabase MCP**

Call `mcp__supabase__apply_migration` with `name: "productos_pallets_schema"` and `query` equal to
the exact SQL from Step 1.

- [ ] **Step 3: Verify with `mcp__supabase__execute_sql`**

```sql
SELECT codigo, unidades_por_pallet, es_pallet_vacio, es_transporte, precio_sin_iva
FROM productos ORDER BY codigo::int;
```
Expected: 25 rows, `codigo` `'1'`..`'25'`, row `'1'` has `unidades_por_pallet=105`, row `'24'` has
`es_pallet_vacio=true`, row `'25'` has `es_transporte=true`.

```sql
SELECT count(*) FROM cuenta2_remito_items WHERE producto_id = 1;
```
Expected: `3` (unchanged — confirms the existing Cuenta 2 rows were not orphaned).

```sql
SELECT table_name, column_name FROM information_schema.columns
WHERE table_name IN ('presupuesto_items','factura_items','remito_items','nota_items','cuenta2_remito_items')
  AND column_name IN ('pallets','unidades_por_pallet')
ORDER BY table_name, column_name;
```
Expected: 10 rows (2 columns × 5 tables).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260819120000_productos_pallets_schema.sql
git commit -m "feat(db): seed 25-product catalog + pallets columns on productos and item tables"
```

---

### Task 2: DB RPC — carry `pallets`/`unidades_por_pallet` through write + read RPCs

**Files:**
- Create: `supabase/migrations/20260819120001_rpc_productos_pallets_items.sql`

**Interfaces:**
- Consumes: columns added in Task 1.
- Produces: `crm_insert_presupuesto_items`/`crm_insert_remito_items`/`crm_insert_factura_items`/
  `crm_insert_nota_items`/`crm_insert_cuenta2_remito_items` now read `pallets`/`unidades_por_pallet`
  keys from each item's jsonb; `presupuestos_list`/`remitos_list`/`facturas_list`/`notas_list`/
  `remitos_cuenta2_list` now include `'pallets'`/`'unidades_por_pallet'` in each item's
  `json_build_object`. No function signatures change (same params as today), so existing grants on
  `crear_presupuesto`/`crear_remito`/etc. (untouched by this task) persist automatically.

- [ ] **Step 1: Write the migration file**

```sql
-- =============================================================
-- CRM Ventas — productos.md: pallets/unidades_por_pallet a través de las RPC de escritura y
-- lectura. Sólo re-crea los helpers internos crm_insert_*_items (agregan 2 columnas al INSERT) y
-- las *_list de lectura (agregan 2 claves al json_build_object de cada ítem) — las RPC públicas
-- crear_*/actualizar_* no cambian: ya reenvían p_items sin tocarlo al helper correspondiente.
-- Additive/backward-compatible: los ítems guardados antes de esta migración simplemente no traen
-- 'pallets'/'unidades_por_pallet' (columnas nullable / default 1). CREATE OR REPLACE con la misma
-- firma preserva los grants existentes automáticamente; se restatean igual por la convención del
-- proyecto (ver 20260728120012_pdf_list_fields.sql).
-- =============================================================

-- ── Helpers de escritura ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION crm_insert_presupuesto_items(
  p_presupuesto_id integer,
  p_items          jsonb
)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO presupuesto_items
    (presupuesto_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
  SELECT
    p_presupuesto_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer,
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_remito_items(
  p_remito_id integer,
  p_items     jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO remito_items
    (remito_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
  SELECT
    p_remito_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    COALESCE((e.item->>'precio_unitario')::numeric, 0),
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * COALESCE((e.item->>'precio_unitario')::numeric, 0)
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer,
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_factura_items(
  p_factura_id integer,
  p_items      jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO factura_items
    (factura_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
  SELECT
    p_factura_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer,
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_nota_items(
  p_nota_id integer,
  p_items   jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO nota_items
    (nota_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
  SELECT
    p_nota_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer,
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crm_insert_cuenta2_remito_items(
  p_remito_id integer,
  p_items     jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO cuenta2_remito_items
    (remito_id, producto_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden, pallets, unidades_por_pallet)
  SELECT
    p_remito_id,
    NULLIF(e.item->>'producto_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer,
    NULLIF(e.item->>'pallets', '')::integer,
    COALESCE(NULLIF(e.item->>'unidades_por_pallet', '')::integer, 1)
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

-- ── RPC de lectura ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION presupuestos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE presupuestos SET estado = 'vencido', updated_at = NOW()
  WHERE estado IN ('borrador','enviado') AND fecha_vcto < CURRENT_DATE;

  RETURN QUERY
  SELECT to_jsonb(t) FROM (
    SELECT p.*,
      c.razon_social, c.cuit, c.condicion_iva, c.direccion, c.email, c.telefono,
      json_agg(json_build_object(
        'id', pi.id, 'producto_id', pi.producto_id, 'codigo', pr.codigo, 'descripcion', pi.descripcion,
        'cantidad', pi.cantidad, 'precio_unitario', pi.precio_unitario,
        'descuento_item', pi.descuento_item, 'subtotal', pi.subtotal, 'orden', pi.orden,
        'pallets', pi.pallets, 'unidades_por_pallet', pi.unidades_por_pallet
      ) ORDER BY pi.orden) FILTER (WHERE pi.id IS NOT NULL) AS items
    FROM presupuestos p
    JOIN clientes c ON c.id = p.cliente_id
    LEFT JOIN presupuesto_items pi ON pi.presupuesto_id = p.id
    LEFT JOIN productos pr ON pr.id = pi.producto_id
    WHERE (p_id IS NULL OR p.id = p_id)
      AND (p_estado IS NULL OR p.estado = p_estado)
      AND (p_q IS NULL OR p.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    GROUP BY p.id, c.id
    ORDER BY p.fecha DESC, p.numero DESC
  ) t;
END;
$$;

CREATE OR REPLACE FUNCTION remitos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_estado text DEFAULT NULL, p_cliente_id integer DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT r.*,
      c.razon_social, c.cuit, c.condicion_iva, c.direccion, c.email, c.telefono,
      f.numero AS factura_numero,
      json_agg(json_build_object(
        'id', ri.id, 'producto_id', ri.producto_id, 'codigo', pr.codigo, 'descripcion', ri.descripcion,
        'cantidad', ri.cantidad, 'precio_unitario', ri.precio_unitario,
        'descuento_item', ri.descuento_item, 'subtotal', ri.subtotal, 'orden', ri.orden,
        'pallets', ri.pallets, 'unidades_por_pallet', ri.unidades_por_pallet
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items
    FROM remitos r
    JOIN clientes c ON c.id = r.cliente_id
    LEFT JOIN facturas f ON f.id = r.factura_id
    LEFT JOIN remito_items ri ON ri.remito_id = r.id
    LEFT JOIN productos pr ON pr.id = ri.producto_id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_estado IS NULL OR r.estado = p_estado)
      AND (p_cliente_id IS NULL OR r.cliente_id = p_cliente_id)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    GROUP BY r.id, c.id, f.numero
    ORDER BY r.fecha DESC, r.numero DESC
  ) t;
$$;

CREATE OR REPLACE FUNCTION facturas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL,
  p_tipo text DEFAULT NULL, p_cliente_id integer DEFAULT NULL,
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_solo_sin_remito boolean DEFAULT false
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT f.*,
      c.razon_social, c.cuit, c.condicion_iva, c.direccion, c.email, c.telefono,
      r.numero AS remito_numero, p.numero AS presupuesto_numero,
      json_agg(json_build_object(
        'id', fi.id, 'producto_id', fi.producto_id, 'codigo', pr.codigo, 'descripcion', fi.descripcion,
        'cantidad', fi.cantidad, 'precio_unitario', fi.precio_unitario,
        'descuento_item', fi.descuento_item, 'subtotal', fi.subtotal, 'orden', fi.orden,
        'pallets', fi.pallets, 'unidades_por_pallet', fi.unidades_por_pallet
      ) ORDER BY fi.orden) FILTER (WHERE fi.id IS NOT NULL) AS items
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    LEFT JOIN remitos r ON r.id = f.remito_id
    LEFT JOIN presupuestos p ON p.id = f.presupuesto_id
    LEFT JOIN factura_items fi ON fi.factura_id = f.id
    LEFT JOIN productos pr ON pr.id = fi.producto_id
    WHERE (p_id IS NULL OR f.id = p_id)
      AND (p_estado IS NULL OR f.estado = p_estado)
      AND (p_tipo IS NULL OR f.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      AND (p_desde IS NULL OR f.fecha >= p_desde)
      AND (p_hasta IS NULL OR f.fecha <= p_hasta)
      AND (NOT p_solo_sin_remito OR (f.remito_id IS NULL AND f.estado <> 'anulada'))
      AND (p_q IS NULL OR f.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR c.cuit ILIKE '%'||p_q||'%')
    GROUP BY f.id, c.id, r.numero, p.numero
    ORDER BY f.fecha DESC, f.numero DESC
  ) t;
$$;

CREATE OR REPLACE FUNCTION notas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_tipo text DEFAULT NULL, p_cliente_id integer DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT n.*,
      f.numero AS factura_numero, f.tipo AS factura_tipo,
      c.razon_social, c.cuit, c.condicion_iva, c.direccion,
      json_agg(json_build_object(
        'id', ni.id, 'producto_id', ni.producto_id, 'codigo', pr.codigo, 'descripcion', ni.descripcion,
        'cantidad', ni.cantidad, 'precio_unitario', ni.precio_unitario,
        'descuento_item', ni.descuento_item, 'subtotal', ni.subtotal, 'orden', ni.orden,
        'pallets', ni.pallets, 'unidades_por_pallet', ni.unidades_por_pallet
      ) ORDER BY ni.orden) FILTER (WHERE ni.id IS NOT NULL) AS items
    FROM notas n
    JOIN facturas f ON f.id = n.factura_id
    JOIN clientes c ON c.id = f.cliente_id
    LEFT JOIN nota_items ni ON ni.nota_id = n.id
    LEFT JOIN productos pr ON pr.id = ni.producto_id
    WHERE (p_id IS NULL OR n.id = p_id)
      AND (p_tipo IS NULL OR n.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      AND (p_q IS NULL OR n.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR f.numero ILIKE '%'||p_q||'%')
    GROUP BY n.id, f.numero, f.tipo, c.razon_social, c.cuit, c.condicion_iva, c.direccion
    ORDER BY n.fecha DESC
  ) t;
$$;

CREATE OR REPLACE FUNCTION remitos_cuenta2_list(
  p_id          integer DEFAULT NULL,
  p_tipo_sector text    DEFAULT NULL,
  p_q           text    DEFAULT NULL,
  p_entidad_id  integer DEFAULT NULL,
  p_desde       date    DEFAULT NULL,
  p_hasta       date    DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT r.*,
      COALESCE(cl.nombre, pv.nombre) AS entidad_nombre,
      COALESCE(r.cliente_id, r.proveedor_id) AS entidad_id,
      json_agg(json_build_object(
        'id', ri.id, 'producto_id', ri.producto_id, 'codigo', pr.codigo,
        'descripcion', ri.descripcion, 'cantidad', ri.cantidad,
        'precio_unitario', ri.precio_unitario, 'descuento_item', ri.descuento_item,
        'subtotal', ri.subtotal, 'orden', ri.orden,
        'pallets', ri.pallets, 'unidades_por_pallet', ri.unidades_por_pallet
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items
    FROM cuenta2_remitos r
    LEFT JOIN clientes_cuenta2    cl ON cl.id = r.cliente_id
    LEFT JOIN proveedores_cuenta2 pv ON pv.id = r.proveedor_id
    LEFT JOIN cuenta2_remito_items ri ON ri.remito_id = r.id
    LEFT JOIN productos pr ON pr.id = ri.producto_id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_tipo_sector IS NULL OR r.tipo_sector = p_tipo_sector)
      AND (p_entidad_id IS NULL OR r.cliente_id = p_entidad_id OR r.proveedor_id = p_entidad_id)
      AND (p_desde IS NULL OR r.fecha >= p_desde)
      AND (p_hasta IS NULL OR r.fecha <= p_hasta)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%'
                       OR cl.nombre ILIKE '%'||p_q||'%'
                       OR pv.nombre ILIKE '%'||p_q||'%')
    GROUP BY r.id, cl.nombre, pv.nombre
    ORDER BY r.fecha DESC, r.id DESC
  ) t;
$$;

-- ── Permisos ───────────────────────────────────────────────────────
-- crm_insert_*_items: CREATE OR REPLACE con la misma firma preserva el ACL existente solo; se
-- restatea igual, por la convención del proyecto (ver comentario en 20260728120012_pdf_list_fields.sql).
REVOKE ALL ON FUNCTION crm_insert_presupuesto_items(integer, jsonb)    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_remito_items(integer, jsonb)         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_factura_items(integer, jsonb)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_nota_items(integer, jsonb)           FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crm_insert_cuenta2_remito_items(integer, jsonb) FROM PUBLIC, anon, authenticated;

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'presupuestos_list','remitos_list','facturas_list','notas_list','remitos_cuenta2_list'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated;', r.sig);
  END LOOP;
END $$;
```

- [ ] **Step 2: Apply the migration via the Supabase MCP**

Call `mcp__supabase__apply_migration` with `name: "rpc_productos_pallets_items"` and `query` equal
to the exact SQL from Step 1.

- [ ] **Step 3: Verify with a write→read round trip via `mcp__supabase__execute_sql`**

```sql
DO $$
DECLARE
  v_cliente_id integer;
  v_pres       presupuestos;
BEGIN
  SELECT id INTO v_cliente_id FROM clientes LIMIT 1;
  v_pres := crear_presupuesto(
    v_cliente_id,
    '[{"producto_id": 1, "descripcion": "Bloque Liso de 19x19x39 Portante", "cantidad": 210, "precio_unitario": 1572.08, "descuento_item": 0, "pallets": 2, "unidades_por_pallet": 105}]'::jsonb,
    0, 'TEST productos.md — borrar'
  );
END $$;

SELECT jsonb_pretty(row) FROM presupuestos_list(NULL, 'TEST productos.md', NULL) AS row;
```
Expected: the single item in the printed jsonb has `"pallets": 2` and `"unidades_por_pallet": 105`.

```sql
DELETE FROM presupuestos WHERE observaciones = 'TEST productos.md — borrar';
```
Cleans up the test row (cascades to `presupuesto_items`).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260819120001_rpc_productos_pallets_items.sql
git commit -m "feat(db): carry pallets/unidades_por_pallet through comprobante write and read RPCs"
```

---

### Task 3: `frontend/src/api/index.js` — pallets fields in the Productos ABM

**Files:**
- Modify: `frontend/src/api/index.js:25-30` (the `prod` normalizer), `frontend/src/api/index.js:84-98`
  (`ProductosAPI`)

**Interfaces:**
- Consumes: `productos.unidades_por_pallet` (Task 1).
- Produces: `ProductosAPI.list()` rows now include `unidades_por_pallet`/`es_pallet_vacio`/
  `es_transporte` (via `select('*')`, unchanged) and are sorted numerically by `codigo`. Task 5's
  `ItemsTable`/`ProductoBuscador` and Task 7's Productos view both consume this.

- [ ] **Step 1: Edit the `prod` normalizer and add a numeric-codigo sort helper**

```javascript
const prod = (d) => ({
  codigo:         d.codigo?.trim().toUpperCase(),
  descripcion:    d.descripcion?.trim(),
  precio_sin_iva: parseFloat(d.precio_sin_iva) || 0,
  ...(d.activo !== undefined ? { activo: d.activo !== false } : {}),
})
```
becomes
```javascript
const prod = (d) => ({
  codigo:               d.codigo?.trim().toUpperCase(),
  descripcion:          d.descripcion?.trim(),
  precio_sin_iva:       parseFloat(d.precio_sin_iva) || 0,
  unidades_por_pallet:  Math.max(1, parseInt(d.unidades_por_pallet, 10) || 1),
  ...(d.activo !== undefined ? { activo: d.activo !== false } : {}),
})

// Orden numérico cuando el código es un entero simple (catálogo productos.md: '1'..'25');
// cae a orden alfabético para códigos no numéricos.
const sortByCodigo = (rows) => [...rows].sort((a, b) => {
  const na = Number(a.codigo), nb = Number(b.codigo)
  if (Number.isFinite(na) && Number.isFinite(nb)) return na - nb
  return String(a.codigo).localeCompare(String(b.codigo))
})
```

- [ ] **Step 2: Edit `ProductosAPI.list`**

```javascript
export const ProductosAPI = {
  list: ({ q, activo } = {}) => {
    let query = supabase.from('productos').select('*').order('codigo')
    if (q) {
      const s = String(q).replace(/[,()]/g, ' ')
      query = query.or(`descripcion.ilike.%${s}%,codigo.ilike.%${s}%`)
    }
    if (activo !== undefined) query = query.eq('activo', activo === true || activo === 'true')
    return query.then(unwrap)
  },
```
becomes
```javascript
export const ProductosAPI = {
  list: ({ q, activo } = {}) => {
    let query = supabase.from('productos').select('*')
    if (q) {
      const s = String(q).replace(/[,()]/g, ' ')
      query = query.or(`descripcion.ilike.%${s}%,codigo.ilike.%${s}%`)
    }
    if (activo !== undefined) query = query.eq('activo', activo === true || activo === 'true')
    return query.then(unwrap).then(sortByCodigo)
  },
```

- [ ] **Step 3: Verify**

`cd frontend && npm run dev`, log in, open the Productos view — it should load without console
errors (the visible column/ordering change lands in Task 7; this step is a regression check that
the API layer change alone doesn't break the existing page).

- [ ] **Step 4: Commit**

```bash
git add frontend/src/api/index.js
git commit -m "feat(api): normalize unidades_por_pallet and sort productos numerically by codigo"
```

---

### Task 4: `usePalletsVacios` hook — auto-sync the wood-pallet line

**Files:**
- Create: `frontend/src/hooks/usePalletsVacios.js`

**Interfaces:**
- Consumes: an `items` array (each item optionally has `pallets: number`, `producto_id`,
  `es_pallet_vacio: boolean`, `es_transporte: boolean` — the shape `ItemsTable`'s `selectProd`
  produces, see Task 5), a `setItems(nextItemsArray)` callback, and the `productos` list (Task 3;
  needs at least one row with `es_pallet_vacio === true`).
- Produces: no return value — calls `setItems` with an updated items array whenever the "Pallet de
  Madera Vacío" line needs to be created, resynced, or removed. Used by Task 6's `ComprobanteForm`
  and `RemitoXForm`.

- [ ] **Step 1: Write the hook**

```javascript
// src/hooks/usePalletsVacios.js
// Mantiene sincronizada la línea de "Pallet de Madera Vacío" (productos.es_pallet_vacio) con la
// suma de pallets de los demás ítems de la grilla — productos.md §1.2/§3.2.3.
//   * Si no existe la línea y el total de pallets es > 0, la crea.
//   * Si existe y el usuario no la tocó a mano (ItemsTable marca pallets_auto=false al editar su
//     campo Pallets), la mantiene sincronizada con el total; si el total cae a 0, la quita.
//   * Si el usuario la editó a mano o la borró, se respeta: sólo vuelve a crearse/recrearse cuando
//     el total de pallets cambia de nuevo (lastAutoTotal deja de coincidir).
import { useEffect, useRef } from 'react'

export function usePalletsVacios(items, setItems, productos) {
  const lastAutoTotal = useRef(null)

  useEffect(() => {
    const palletProd = productos.find(p => p.es_pallet_vacio)
    if (!palletProd) return

    const total = items.reduce((sum, it) => (
      it.producto_id && !it.es_pallet_vacio && !it.es_transporte
        ? sum + (parseInt(it.pallets, 10) || 0)
        : sum
    ), 0)

    const idx = items.findIndex(it => it.es_pallet_vacio)

    if (idx === -1) {
      if (total > 0 && total !== lastAutoTotal.current) {
        lastAutoTotal.current = total
        setItems([...items, {
          producto_id:         palletProd.id,
          descripcion:         palletProd.descripcion,
          precio_unitario:     palletProd.precio_sin_iva,
          descuento_item:      0,
          unidades_por_pallet: 1,
          es_pallet_vacio:     true,
          es_transporte:       false,
          pallets:             total,
          cantidad:            total,
          pallets_auto:        true,
        }])
      }
      return
    }

    const line = items[idx]
    if (line.pallets_auto === false) return

    if (total === 0) {
      lastAutoTotal.current = total
      setItems(items.filter((_, i) => i !== idx))
      return
    }
    if (Number(line.pallets) === total) return

    lastAutoTotal.current = total
    setItems(items.map((it, i) => i !== idx ? it : { ...it, pallets: total, cantidad: total, pallets_auto: true }))
  }, [items, productos])
}
```

- [ ] **Step 2: Verify**

No standalone entry point yet (wired into forms in Task 6) — this step is code review only: re-read
the file and confirm the three branches (create / resync / remove) match the bullet list in the
header comment, and that `line.pallets_auto === false` is the only guard that permanently stops
auto-sync for a given line.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/hooks/usePalletsVacios.js
git commit -m "feat(hooks): add usePalletsVacios to auto-sync the wood pallet line item"
```

---

### Task 5: `ItemsTable` — product combobox + Pallets/Unidades columns

**Files:**
- Modify: `frontend/src/components/UI/index.jsx`

**Interfaces:**
- Consumes: `productos` rows now carry `unidades_por_pallet`/`es_pallet_vacio`/`es_transporte`
  (Task 3).
- Produces: `ItemsTable`'s `onChange` now emits items shaped `{ producto_id, descripcion,
  precio_unitario, descuento_item, unidades_por_pallet, es_pallet_vacio, es_transporte, pallets,
  cantidad, pallets_auto? }` — `usePalletsVacios` (Task 4) and the RPCs (Task 2) both read these
  exact keys. `cantidad` is always `pallets * unidades_por_pallet` and is no longer directly
  editable in the grid.

- [ ] **Step 1: Add the `useState`/`useEffect` import**

```javascript
// src/components/UI/index.jsx
import { BADGE_COLORS, ESTADOS, $ar, calcTotales, calcTotalesC2, calcSubtotalItem } from '../../utils'
```
becomes
```javascript
// src/components/UI/index.jsx
import { useEffect, useState } from 'react'
import { BADGE_COLORS, ESTADOS, $ar, calcTotales, calcTotalesC2, calcSubtotalItem } from '../../utils'
```

- [ ] **Step 2: Add `productoLabel` + `ProductoBuscador` above `ItemsTable`**

Insert immediately before the `// ── ITEMS TABLE ...` section header:

```javascript
// ── PRODUCTO BUSCADOR (autocompletar por ID corto o texto) ─────────
// <input list> + <datalist>: usa el desplegable nativo del navegador en vez de uno propio con
// position:absolute, que quedaría recortado por .items-table-wrap (overflow:hidden) y
// .modal-body (overflow-y:auto). Cada <option> vale la etiqueta completa "[ID] Descripción — X
// un/pallet"; al elegirla el navegador ya deja ese texto en el input, así que sólo hace falta
// resolverla contra el catálogo. Tipear sólo el ID (sin abrir el desplegable) también funciona: se
// resuelve por código exacto al perder el foco o con Enter — productos.md §3.2.1.
const productoLabel = (p) =>
  `[${p.codigo}] ${p.descripcion}${p.unidades_por_pallet > 1 ? ` — ${p.unidades_por_pallet} un/pallet` : ''}`

function ProductoBuscador({ value, productos, onSelect, rowKey }) {
  const activos = productos.filter(p => p.activo)
  const selected = activos.find(p => p.id === value)
  const [text, setText] = useState(selected ? productoLabel(selected) : '')

  useEffect(() => {
    setText(selected ? productoLabel(selected) : '')
  }, [selected])

  const byLabel  = new Map(activos.map(p => [productoLabel(p), p]))
  const byCodigo = new Map(activos.map(p => [p.codigo, p]))

  const commit = (raw) => {
    const picked = byLabel.get(raw) || byCodigo.get(raw.trim())
    if (picked) { onSelect(picked); setText(productoLabel(picked)); return }
    setText(selected ? productoLabel(selected) : '')
  }

  const listId = `productos-dl-${rowKey}`

  return (
    <>
      <input
        className="inp inp-sm"
        list={listId}
        value={text}
        placeholder="ID o descripción…"
        onChange={(e) => {
          const raw = e.target.value
          setText(raw)
          const exact = byLabel.get(raw)
          if (exact) onSelect(exact)
        }}
        onBlur={(e) => commit(e.target.value)}
        onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); commit(e.target.value) } }}
      />
      <datalist id={listId}>
        {activos.map(p => <option key={p.id} value={productoLabel(p)} />)}
      </datalist>
    </>
  )
}
```

- [ ] **Step 3: Replace `ItemsTable`'s body**

The full old block (from `export function ItemsTable` through its closing `}`, i.e. current lines
132–245) becomes:

```javascript
export function ItemsTable({ items, productos = [], alicuotas = [], readonly = false, onChange }) {
  const showIva = alicuotas.length > 0

  const update = (i, field, val) => {
    if (!onChange) return
    const next = items.map((it, idx) => {
      if (idx !== i) return it
      if (field === 'pallets') {
        const pallets = Math.max(0, Math.trunc(parseFloat(val)) || 0)
        const upp = it.unidades_por_pallet || 1
        return { ...it, pallets, cantidad: pallets * upp, ...(it.es_pallet_vacio && { pallets_auto: false }) }
      }
      const updated = { ...it, [field]: ['precio_unitario','descuento_item'].includes(field) ? parseFloat(val) || 0 : val }
      return updated
    })
    onChange(next)
  }

  const selectProd = (i, p) => {
    if (!onChange) return
    const upp = Number(p.unidades_por_pallet) || 1
    const next = items.map((it, idx) => idx !== i ? it : {
      ...it,
      producto_id:         p.id,
      descripcion:         p.descripcion || '',
      precio_unitario:     p.precio_sin_iva || 0,
      unidades_por_pallet: upp,
      es_pallet_vacio:     !!p.es_pallet_vacio,
      es_transporte:       !!p.es_transporte,
      pallets:             1,
      cantidad:            upp,
    })
    onChange(next)
  }

  const selectAlic = (i, val) => {
    if (!onChange) return
    onChange(items.map((it, idx) => idx !== i ? it : { ...it, alicuota_iva_id: +val || '' }))
  }

  const remove = (i) => onChange && onChange(items.filter((_, idx) => idx !== i))

  return (
    <div className="items-table-wrap">
      <table className="items-table">
        <thead>
          <tr>
            <th style={{ width: 170 }}>Producto</th>
            <th>Descripción</th>
            <th className="th-right" style={{ width: 65 }}>Pallets</th>
            <th className="th-right" style={{ width: 80 }}>Unidades</th>
            <th className="th-right" style={{ width: 120 }}>Precio s/IVA</th>
            <th className="th-right" style={{ width: 65 }}>Dto%</th>
            {showIva && <th style={{ width: 90 }}>IVA</th>}
            <th className="th-right" style={{ width: 110 }}>Subtotal</th>
            {!readonly && <th style={{ width: 36 }}></th>}
          </tr>
        </thead>
        <tbody>
          {items.length === 0 ? (
            <tr><td colSpan={7 + (showIva ? 1 : 0) + (readonly ? 0 : 1)} className="empty-state">Sin ítems</td></tr>
          ) : items.map((it, i) => (
            <tr key={i}>
              <td>
                {readonly
                  ? <span className="code">{it.codigo || '—'}</span>
                  : <ProductoBuscador value={it.producto_id} productos={productos} onSelect={(p) => selectProd(i, p)} rowKey={i} />
                }
              </td>
              <td>
                {readonly
                  ? it.descripcion
                  : <input className="inp inp-sm" value={it.descripcion || ''} onChange={(e) => update(i, 'descripcion', e.target.value)} />
                }
              </td>
              <td className="td-right">
                {readonly
                  ? (it.pallets ?? '—')
                  : <input type="number" className="inp inp-sm inp-right" style={{ width: 60 }} value={it.pallets ?? ''} min="0" step="1" onChange={(e) => update(i, 'pallets', e.target.value)} />
                }
              </td>
              <td className="td-right">{Number(it.cantidad || 0).toLocaleString('es-AR')}</td>
              <td className="td-right">
                {readonly
                  ? $ar(it.precio_unitario)
                  : <input type="number" className="inp inp-sm inp-right" style={{ width: 110 }} value={it.precio_unitario} min="0" onChange={(e) => update(i, 'precio_unitario', e.target.value)} />
                }
              </td>
              <td className="td-right">
                {readonly
                  ? `${it.descuento_item || 0}%`
                  : <input type="number" className="inp inp-sm inp-right" style={{ width: 58 }} value={it.descuento_item || 0} min="0" max="100" onChange={(e) => update(i, 'descuento_item', e.target.value)} />
                }
              </td>
              {showIva && (
                <td>
                  {readonly
                    ? `${it.iva_porcentaje ?? 21}%`
                    : (
                      <select className="inp inp-sm sel" value={it.alicuota_iva_id || ''} onChange={(e) => selectAlic(i, e.target.value)}>
                        {alicuotas.map(a => <option key={a.id} value={a.id}>{a.porcentaje}%</option>)}
                      </select>
                    )
                  }
                </td>
              )}
              <td className="td-right td-bold">{$ar(calcSubtotalItem(it.cantidad, it.precio_unitario, it.descuento_item))}</td>
              {!readonly && (
                <td style={{ textAlign: 'center' }}>
                  <button onClick={() => remove(i)} style={{ background: 'none', border: 'none', cursor: 'pointer', color: 'var(--red-500)', fontSize: 19, lineHeight: 1, padding: 0 }}>×</button>
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
```

- [ ] **Step 4: Verify**

`cd frontend && npm run dev`. Even before Task 6 wires the hook, existing forms (Presupuestos,
Remitos, Facturas, Notas, Cuenta2) already pass `items`/`productos`/`onChange` into `ItemsTable`, so
this alone should render: open any comprobante creation modal, confirm the grid shows Producto /
Descripción / Pallets / Unidades / Precio / Dto% / Subtotal columns, typing `1` in the Producto
field shows a native suggestion list, and typing a Pallets value updates Unidades and Subtotal live.
Check the browser console for errors.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/UI/index.jsx
git commit -m "feat(ui): ItemsTable — searchable product combobox + pallets/unidades columns"
```

---

### Task 6: Wire pallets defaults + `usePalletsVacios` into the comprobante forms

**Files:**
- Modify: `frontend/src/components/Forms/ComprobanteForm.jsx`
- Modify: `frontend/src/components/Forms/RemitoXForm.jsx`
- Modify: `frontend/src/views/Notas/NotaForm.jsx`

**Interfaces:**
- Consumes: `usePalletsVacios` (Task 4), `ItemsTable`'s new item shape (Task 5).
- Produces: n/a (leaf forms).

- [ ] **Step 1: `ComprobanteForm.jsx` — import + `ITEM_BASE` + hook call**

```javascript
// src/components/Forms/ComprobanteForm.jsx
// Formulario reutilizable para Factura, Presupuesto y Remito
import { useState } from 'react'
import { ItemsTable, TotalesBox, TotalesBoxMulti, Modal } from '../UI'
import { calcTotalesMulti } from '../../utils'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0 }
```
becomes
```javascript
// src/components/Forms/ComprobanteForm.jsx
// Formulario reutilizable para Factura, Presupuesto y Remito
import { useState } from 'react'
import { ItemsTable, TotalesBox, TotalesBoxMulti, Modal } from '../UI'
import { calcTotalesMulti } from '../../utils'
import { usePalletsVacios } from '../../hooks/usePalletsVacios'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0, pallets: 1, unidades_por_pallet: 1 }
```

Then, right after the `const [showWarn, setShowWarn] = useState(warnVencido)` line, add the hook
call:

```javascript
  const [loading, setLoading] = useState(false)
  const [showWarn, setShowWarn] = useState(warnVencido)
```
becomes
```javascript
  const [loading, setLoading] = useState(false)
  const [showWarn, setShowWarn] = useState(warnVencido)

  usePalletsVacios(form.items, (items) => setForm(f => ({ ...f, items })), productos)
```

- [ ] **Step 2: `RemitoXForm.jsx` — import + `ITEM_BASE` + hook call**

```javascript
// src/components/Forms/RemitoXForm.jsx
// Remito X de Cuenta 2 — único comprobante del circuito informal (cuenta2.md §1.3).
// Un solo formulario sirve venta y compra vía `tipoSector`, igual que ComprobanteForm sirve
// presupuesto/remito/factura vía `tipo`. Dos diferencias con el circuito oficial:
//   * el número lo tipea el usuario (talonario de papel, sin punto de venta fiscal);
//   * no hay IVA — TotalesBoxC2 en lugar de TotalesBox, e ItemsTable sin `alicuotas`.
import { useState } from 'react'
import { ItemsTable, TotalesBoxC2, Modal } from '../UI'
import { hoy } from '../../utils'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0 }
```
becomes
```javascript
// src/components/Forms/RemitoXForm.jsx
// Remito X de Cuenta 2 — único comprobante del circuito informal (cuenta2.md §1.3).
// Un solo formulario sirve venta y compra vía `tipoSector`, igual que ComprobanteForm sirve
// presupuesto/remito/factura vía `tipo`. Dos diferencias con el circuito oficial:
//   * el número lo tipea el usuario (talonario de papel, sin punto de venta fiscal);
//   * no hay IVA — TotalesBoxC2 en lugar de TotalesBox, e ItemsTable sin `alicuotas`.
import { useState } from 'react'
import { ItemsTable, TotalesBoxC2, Modal } from '../UI'
import { hoy } from '../../utils'
import { usePalletsVacios } from '../../hooks/usePalletsVacios'
import toast from 'react-hot-toast'

const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0, pallets: 1, unidades_por_pallet: 1 }
```

Then, right after the `const [loading, setLoading] = useState(false)` line, add the hook call:

```javascript
  const [loading, setLoading] = useState(false)

  // Auto-aplicar el descuento de la entidad al seleccionarla (mismo criterio que onCliChange).
```
becomes
```javascript
  const [loading, setLoading] = useState(false)

  usePalletsVacios(form.items, (items) => setForm(f => ({ ...f, items })), productos)

  // Auto-aplicar el descuento de la entidad al seleccionarla (mismo criterio que onCliChange).
```

- [ ] **Step 3: `NotaForm.jsx` — `ITEM_BASE` only (no hook: a credit/debit note doesn't need new
  wood pallets)**

```javascript
const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0 }
```
becomes
```javascript
const ITEM_BASE = { producto_id: '', descripcion: '', cantidad: 1, precio_unitario: 0, descuento_item: 0, pallets: 1, unidades_por_pallet: 1 }
```

- [ ] **Step 4: Verify**

`cd frontend && npm run dev`, log in:
1. Open **Presupuestos → Nuevo**. Add an item, type `1` in the product field, press Enter — it
   should resolve to `[1] Bloque Liso de 19x19x39 Portante — 105 un/pallet`. Set Pallets to `2`;
   Unidades should show `210` and Subtotal `$ 330.136,80`. A second line "Pallet de Madera Vacío"
   should auto-appear with Pallets `2`.
2. Add a second bloque item with 1 pallet; the auto pallet-vacío line should update to `3`.
3. Manually change the pallet-vacío line's Pallets to `10`; change one of the bloque items' pallets
   again — the pallet-vacío line should **not** be overwritten (stays `10`).
4. Delete the pallet-vacío line via `×`; change a bloque item's pallets again — the line should
   reappear with the new total (deletion is respected only until the total actually changes again).
5. Save the presupuesto, confirm totals match, no console errors.
6. Repeat a short version (add item, confirm auto pallet line) in **Remitos → Nuevo** and in
   **Cuenta 2 → (venta) → Nuevo Remito X**.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/components/Forms/ComprobanteForm.jsx frontend/src/components/Forms/RemitoXForm.jsx frontend/src/views/Notas/NotaForm.jsx
git commit -m "feat(forms): wire usePalletsVacios and pallets defaults into comprobante forms"
```

---

### Task 7: Productos admin view — "Unidades por Pallet" column + edit field

**Files:**
- Modify: `frontend/src/views/Productos/index.jsx`

**Interfaces:**
- Consumes: `unidades_por_pallet` (Tasks 1, 3).
- Produces: n/a (leaf view).

- [ ] **Step 1: Update `BLANK`**

```javascript
const BLANK = { codigo: '', descripcion: '', precio_sin_iva: 0, activo: true }
```
becomes
```javascript
const BLANK = { codigo: '', descripcion: '', precio_sin_iva: 0, unidades_por_pallet: 1, activo: true }
```

- [ ] **Step 2: Add the table column**

```javascript
              <tr>
                <th>Código</th>
                <th>Descripción</th>
                <th className="th-right">Precio s/IVA</th>
                <th className="th-right">Precio c/IVA 21%</th>
                <th>Estado</th>
                <th style={{ width: 80 }}></th>
              </tr>
```
becomes
```javascript
              <tr>
                <th>Código</th>
                <th>Descripción</th>
                <th className="th-right">Un./Pallet</th>
                <th className="th-right">Precio s/IVA</th>
                <th className="th-right">Precio c/IVA 21%</th>
                <th>Estado</th>
                <th style={{ width: 80 }}></th>
              </tr>
```

and

```javascript
                <tr key={p.id}>
                  <td><span className="code">{p.codigo}</span></td>
                  <td className="td-bold">{p.descripcion}</td>
                  <td className="td-right">{$ar(p.precio_sin_iva)}</td>
```
becomes
```javascript
                <tr key={p.id}>
                  <td><span className="code">{p.codigo}</span></td>
                  <td className="td-bold">{p.descripcion}</td>
                  <td className="td-right">{p.unidades_por_pallet}</td>
                  <td className="td-right">{$ar(p.precio_sin_iva)}</td>
```

- [ ] **Step 3: Add the edit field to the modal**

```javascript
          <div className="field"><label className="lbl">Precio sin IVA ($)</label><input type="number" className="inp inp-right" value={modal.form.precio_sin_iva} min="0" onChange={e => upd('precio_sin_iva', e.target.value)} /></div>
          <div style={{ background: 'var(--blue-50)', borderRadius: 6, padding: '8px 12px', fontSize: 13, color: 'var(--blue-700)' }}>
```
becomes
```javascript
          <div className="field"><label className="lbl">Precio sin IVA ($)</label><input type="number" className="inp inp-right" value={modal.form.precio_sin_iva} min="0" onChange={e => upd('precio_sin_iva', e.target.value)} /></div>
          <div className="field"><label className="lbl">Unidades por pallet</label><input type="number" className="inp inp-right" value={modal.form.unidades_por_pallet} min="1" step="1" onChange={e => upd('unidades_por_pallet', e.target.value)} /></div>
          <div style={{ background: 'var(--blue-50)', borderRadius: 6, padding: '8px 12px', fontSize: 13, color: 'var(--blue-700)' }}>
```

- [ ] **Step 4: Verify**

`cd frontend && npm run dev`, log in, open **Productos**. Confirm the table now shows a "Un./Pallet"
column with 25 rows ordered `1..25`, `24` shows `1` and `25` shows `1`, `1` shows `105`. Open
"Editar" on product `1`, change Unidades por pallet, save, confirm the table reflects the change.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/views/Productos/index.jsx
git commit -m "feat(productos): show and edit unidades_por_pallet in the admin view"
```

---

### Task 8: End-to-end manual verification

**Files:** none (verification only).

- [ ] **Step 1: Full flow, dev server**

`cd frontend && npm run dev`, log in, and walk through:

1. **Productos**: 25 rows, numeric order, `24`/`25` show `Un./Pallet = 1`.
2. **Presupuestos → Nuevo**: search by typing `holanda` (partial text) → finds both Adoquín Holanda
   products (`20`, `21`); pick one; search by typing `23` → resolves to Cordón; set pallets on both;
   confirm the wood-pallet line auto-sums correctly (excludes itself and any transporte line from
   the sum); add product `25` (Servicio de Transporte) — confirm its suggested price is `$
   300.000,00` and remains freely editable. Save.
3. **Remitos → Nuevo**: same auto pallet-vacío behavior.
4. **Facturas → Nuevo**, link the presupuesto/remito from steps 2–3 if the flow allows it — confirm
   items (including pallets) carry over.
5. **Notas** (from an existing factura): add an item — confirm Pallets/Unidades columns render (no
   auto pallet-vacío line expected here, per Task 6 Step 3).
6. **Cuenta 2 → Remitos X**: repeat the pallets + auto-line flow for both `venta` and `compra`
   sectors.
7. Open the browser console throughout — zero errors expected.

- [ ] **Step 2: Report results**

No commit for this task — it's a verification pass. If any step fails, fix forward in the relevant
task's files and re-verify before considering the plan complete.
