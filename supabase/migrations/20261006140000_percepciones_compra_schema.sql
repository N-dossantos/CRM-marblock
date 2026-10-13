-- =============================================================
-- Compras — percepciones SUFRIDAS (IVA / IIBB / Ganancias / Imp. internos)
-- PLAN_MAESTRO.md §3.9 paso 1 · decisión D9 = (a) de PLAN_MIGRACION_TANGO.md
--
-- Motivo: los proveedores le perciben a Marblock y Compras no tiene dónde registrarlo.
-- `facturas_compra.total` liquida neto + IVA, `factura_compra_iva_detalle` sólo admite
-- 0 / 10,5 / 21 / 27 % y `retenciones` exige un `pago_proveedor_id` (modela lo que la empresa
-- retiene al pagar, no lo que le perciben al comprar). Hoy no se puede cargar una factura de
-- Loma Negra con su total correcto: el saldo con el proveedor queda corto y la percepción de IVA
-- —que es pago a cuenta computable contra el IVA a pagar— no queda registrada en ningún lado.
--
-- Fuente en Tango (`MARBLOCK_SA.bak` del 25/09; H13 del plan de migración):
--   * slots `COD_IVA1..5` de `CPA04` con código 3 (PERCEPCION DE IVA 3 %) o 4 (PERCEPCION 10 %),
--     mezclados con el IVA verdadero — 1.272 comprobantes, activos hasta el 19/09/2026;
--   * `CPA18` (703 filas) con los códigos 51 / 54 (IIBB Bs. As. / CABA), 40 / 52 (impuestos
--     internos) y 53 (ganancias), colgando de FP / CP / DP, nunca de una O/P.
--
-- NO se reutiliza la tabla `percepciones` de Ventas (20260821140000): modela percepciones
-- PRACTICADAS, con FK a facturas / notas. Son el otro lado del mostrador.
--
-- ADITIVA Y RETROCOMPATIBLE, igual que la de Ventas: `percepciones_monto` DEFAULT 0 ⇒ ninguna fila
-- ni formulario actual cambia de total. Idempotente.
-- =============================================================

-- ── 1) Tabla de detalle ──────────────────────────────────────────
-- factura_compra_id XOR nota_compra_id: una percepción cuelga de un comprobante y de uno solo.
CREATE TABLE IF NOT EXISTS percepciones_compra (
  id                SERIAL PRIMARY KEY,
  factura_compra_id INTEGER REFERENCES facturas_compra(id) ON DELETE CASCADE,
  nota_compra_id    INTEGER REFERENCES notas_compra(id)    ON DELETE CASCADE,
  tipo              VARCHAR(20)   NOT NULL,
  jurisdiccion      VARCHAR(60),                      -- provincia; sólo aplica a IIBB
  base_imponible    DECIMAL(14,2) NOT NULL DEFAULT 0,
  alicuota          DECIMAL(5,2)  NOT NULL DEFAULT 0,
  monto             DECIMAL(14,2) NOT NULL,
  created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CONSTRAINT percepciones_compra_tipo_chk
    CHECK (tipo IN ('iva','iibb','ganancias','imp_internos')),
  CONSTRAINT percepciones_compra_owner_chk
    CHECK ((factura_compra_id IS NOT NULL) <> (nota_compra_id IS NOT NULL))
);

-- FK sin índice = seq scan en cada DELETE CASCADE del padre y en cada lectura del detalle.
CREATE INDEX IF NOT EXISTS idx_percepciones_compra_factura
  ON percepciones_compra(factura_compra_id) WHERE factura_compra_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_percepciones_compra_nota
  ON percepciones_compra(nota_compra_id)    WHERE nota_compra_id    IS NOT NULL;

COMMENT ON TABLE percepciones_compra IS
  'Percepciones sufridas por comprobante de compra (D9). Mismo criterio que percepciones de Ventas, '
  'pero del lado del comprador: el importe es el que liquidó el proveedor, no se recalcula.';
COMMENT ON COLUMN percepciones_compra.tipo IS
  'iva y iibb son pagos a cuenta computables; imp_internos y ganancias se informan aparte.';
COMMENT ON COLUMN percepciones_compra.monto IS
  'Importe impreso en la factura del proveedor. base_imponible y alicuota quedan como dato informativo.';

-- Deliberadamente SIN check de signo en `monto`: las NC de proveedor devuelven percepciones con
-- signo contrario y un CHECK acá bloquearía la carga histórica en vez de dejarla auditar.

-- ── 2) Agregado en la cabecera ───────────────────────────────────
-- Denormalizado a propósito, igual que en Ventas: `total` tiene que poder liquidarse sin joinear el
-- detalle (lo leen recalcular_estado_factura_compra, informe_cta_cte_proveedor y los pagos).
ALTER TABLE facturas_compra ADD COLUMN IF NOT EXISTS percepciones_monto DECIMAL(14,2) NOT NULL DEFAULT 0;
ALTER TABLE notas_compra    ADD COLUMN IF NOT EXISTS percepciones_monto DECIMAL(14,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN facturas_compra.percepciones_monto IS
  'Suma de percepciones_compra. total = neto_gravado + iva_monto + percepciones_monto.';
COMMENT ON COLUMN notas_compra.percepciones_monto IS
  'Suma de percepciones_compra. total = neto_gravado + iva_monto + percepciones_monto.';

-- ── 3) Helper de cálculo ─────────────────────────────────────────
-- Entrada: [{tipo, jurisdiccion, alicuota, base_imponible?, monto?}, ...]
--   * base_imponible ausente ⇒ neto gravado del comprobante;
--   * monto ausente ⇒ base × alícuota / 100.
-- `monto` explícito gana sobre el calculado, y esto es la diferencia de fondo con Ventas: acá el
-- que liquida la percepción es el proveedor, así que el número autoritativo es el del papel. El
-- cálculo por alícuota existe sólo como comodidad de carga.
CREATE OR REPLACE FUNCTION crm_calc_percepciones_compra(
  p_percepciones jsonb,
  p_neto         numeric DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_bad     text;
  v_total   numeric := 0;
  v_detalle jsonb   := '[]'::jsonb;
BEGIN
  IF p_percepciones IS NULL
     OR jsonb_typeof(p_percepciones) <> 'array'
     OR jsonb_array_length(p_percepciones) = 0 THEN
    RETURN jsonb_build_object('total', 0, 'detalle', '[]'::jsonb);
  END IF;

  SELECT string_agg(DISTINCT COALESCE(NULLIF(trim(p->>'tipo'), ''), '(vacío)'), ', ')
    INTO v_bad
  FROM jsonb_array_elements(p_percepciones) AS p
  WHERE lower(trim(COALESCE(p->>'tipo', ''))) NOT IN ('iva','iibb','ganancias','imp_internos');

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Tipo de percepción de compra inválido: %. Válidos: iva, iibb, ganancias, imp_internos.', v_bad;
  END IF;

  WITH calc AS (
    SELECT
      lower(trim(p->>'tipo'))                             AS tipo,
      NULLIF(trim(COALESCE(p->>'jurisdiccion', '')), '')  AS jurisdiccion,
      round(COALESCE(NULLIF(p->>'base_imponible', '')::numeric, COALESCE(p_neto, 0)), 2) AS base_imponible,
      round(COALESCE(NULLIF(p->>'alicuota', '')::numeric, 0), 2)                          AS alicuota,
      round(COALESCE(
              NULLIF(p->>'monto', '')::numeric,
              COALESCE(NULLIF(p->>'base_imponible', '')::numeric, COALESCE(p_neto, 0))
                * COALESCE(NULLIF(p->>'alicuota', '')::numeric, 0) / 100
            ), 2)                                          AS monto
    FROM jsonb_array_elements(p_percepciones) AS p
  )
  SELECT COALESCE(SUM(c.monto), 0),
         COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.tipo, c.jurisdiccion NULLS FIRST), '[]'::jsonb)
    INTO v_total, v_detalle
  FROM calc c;

  RETURN jsonb_build_object('total', round(v_total, 2), 'detalle', v_detalle);
END;
$$;

-- ── 4) Helper de inserción ───────────────────────────────────────
-- Recibe el `detalle` ya normalizado por crm_calc_percepciones_compra, no el input crudo.
CREATE OR REPLACE FUNCTION crm_insert_percepciones_compra(
  p_factura_compra_id integer,
  p_nota_compra_id    integer,
  p_detalle           jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF p_detalle IS NULL OR jsonb_array_length(p_detalle) = 0 THEN
    RETURN;
  END IF;

  INSERT INTO percepciones_compra
    (factura_compra_id, nota_compra_id, tipo, jurisdiccion, base_imponible, alicuota, monto)
  SELECT p_factura_compra_id, p_nota_compra_id,
         d->>'tipo',
         NULLIF(d->>'jurisdiccion', ''),
         (d->>'base_imponible')::numeric,
         (d->>'alicuota')::numeric,
         (d->>'monto')::numeric
  FROM jsonb_array_elements(p_detalle) AS d;
END;
$$;

-- ── 5) RLS: mismo modelo "shared staff" de la 0002 ───────────────
-- SIN FORCE: las RPC SECURITY DEFINER corren como owner y FORCE bloquearía sus propias escrituras.
ALTER TABLE public.percepciones_compra ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_all ON public.percepciones_compra;
CREATE POLICY staff_all ON public.percepciones_compra FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.percepciones_compra  TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.percepciones_compra_id_seq   TO authenticated;
REVOKE ALL ON public.percepciones_compra                            FROM anon;
REVOKE ALL ON SEQUENCE public.percepciones_compra_id_seq            FROM anon;

-- ── 6) Permisos de los helpers ───────────────────────────────────
-- Internos: sólo los invocan las RPC SECURITY DEFINER, que corren como owner.
REVOKE ALL ON FUNCTION crm_calc_percepciones_compra(jsonb, numeric)             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_insert_percepciones_compra(integer, integer, jsonb)  FROM PUBLIC, anon, authenticated;
