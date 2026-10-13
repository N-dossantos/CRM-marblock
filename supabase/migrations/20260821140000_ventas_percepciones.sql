-- =============================================================
-- Ventas — percepciones (IIBB / IVA / Ganancias) sobre facturas y notas
--
-- Motivo: el discovery de Tango del 2026-08-21 sobre la base productiva encontró `GVA42`
-- (percepciones de ventas) con 4.846 filas sobre 8.620 comprobantes. El esquema de Ventas liquida
-- `total = neto_gravado + iva_monto`, sin lugar para percepciones — así que más de la mitad del
-- histórico no se puede cargar con fidelidad fiscal y el `POST_LOAD_VERIFY` fallaría en masa.
-- `retenciones` (Compras 0100) NO sirve para esto: modela lo que la empresa *retiene* al pagar a un
-- proveedor (`pago_proveedor_id`, `proveedor_id`), no lo que le *percibe* al cliente.
--
-- Fuente por comprobante en Tango: GVA42 (COD_IMPUES, PORCENTAJE, NETO_GRAV, PERCEP), N filas por
-- (T_COMP, N_COMP) — una por impuesto/jurisdicción. De ahí el modelo cabecera + detalle.
--
-- ADITIVA Y RETROCOMPATIBLE, igual que la migración multi-alícuota del 02/08:
--   * `percepciones_monto` DEFAULT 0 ⇒ las filas y los formularios actuales no cambian de total;
--   * `p_percepciones` es el último parámetro y es opcional ⇒ el frontend actual sigue andando.
-- Idempotente.
--
-- NO se toca `crm_calc_totales_multi_alicuota`: la comparte Compras y la reescribió la migración
-- 20260820120000 (descuento excluye pallet/transporte). Las percepciones se calculan aparte y se
-- suman al total, para no arrastrar Ventas adentro de una función compartida.
-- =============================================================

-- ── 1) Tabla de detalle ──────────────────────────────────────────
-- factura_id XOR nota_id: una percepción cuelga de un comprobante y de uno solo.
CREATE TABLE IF NOT EXISTS percepciones (
  id              SERIAL PRIMARY KEY,
  factura_id      INTEGER REFERENCES facturas(id) ON DELETE CASCADE,
  nota_id         INTEGER REFERENCES notas(id)    ON DELETE CASCADE,
  tipo_percepcion VARCHAR(20)   NOT NULL,
  jurisdiccion    VARCHAR(60),                      -- provincia; sólo aplica a IIBB
  base_imponible  DECIMAL(14,2) NOT NULL DEFAULT 0,
  alicuota        DECIMAL(5,2)  NOT NULL DEFAULT 0,
  monto           DECIMAL(14,2) NOT NULL,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CONSTRAINT percepciones_tipo_chk  CHECK (tipo_percepcion IN ('iibb','iva','ganancias')),
  CONSTRAINT percepciones_owner_chk CHECK ((factura_id IS NOT NULL) <> (nota_id IS NOT NULL))
);

-- FK sin índice = seq scan en cada DELETE CASCADE del padre y en cada lectura del detalle.
CREATE INDEX IF NOT EXISTS idx_percepciones_factura ON percepciones(factura_id) WHERE factura_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_percepciones_nota    ON percepciones(nota_id)    WHERE nota_id    IS NOT NULL;

-- Deliberadamente SIN check de signo en `monto`: todavía no vimos los valores reales de GVA42 y un
-- CHECK acá bloquearía la carga histórica en vez de dejarla auditar. Revisar tras el dry-run.

-- ── 2) Agregado en la cabecera ───────────────────────────────────
-- Denormalizado a propósito: `total` tiene que poder liquidarse sin joinear el detalle (lo leen
-- recalcular_estado_factura, los informes y el PDF).
ALTER TABLE facturas ADD COLUMN IF NOT EXISTS percepciones_monto DECIMAL(14,2) NOT NULL DEFAULT 0;
ALTER TABLE notas    ADD COLUMN IF NOT EXISTS percepciones_monto DECIMAL(14,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN facturas.percepciones_monto IS
  'Suma de percepciones (tabla percepciones). total = neto_gravado + iva_monto + percepciones_monto.';
COMMENT ON COLUMN notas.percepciones_monto IS
  'Suma de percepciones (tabla percepciones). total = neto_gravado + iva_monto + percepciones_monto.';

-- ── 3) Helper de cálculo ─────────────────────────────────────────
-- Entrada: [{tipo_percepcion, jurisdiccion, alicuota, base_imponible?, monto?}, ...]
--   * base_imponible ausente ⇒ neto gravado del comprobante;
--   * monto ausente ⇒ base × alícuota / 100.
-- `monto` explícito gana sobre el calculado: la ETL histórica manda GVA42.PERCEP tal cual, para no
-- re-derivar (y así no discutir) importes que ya se declararon a AFIP.
CREATE OR REPLACE FUNCTION crm_calc_percepciones(
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

  SELECT string_agg(DISTINCT COALESCE(NULLIF(trim(p->>'tipo_percepcion'), ''), '(vacío)'), ', ')
    INTO v_bad
  FROM jsonb_array_elements(p_percepciones) AS p
  WHERE lower(trim(COALESCE(p->>'tipo_percepcion', ''))) NOT IN ('iibb','iva','ganancias');

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Tipo de percepción inválido: %. Válidos: iibb, iva, ganancias.', v_bad;
  END IF;

  WITH calc AS (
    SELECT
      lower(trim(p->>'tipo_percepcion'))                  AS tipo_percepcion,
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
         COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.tipo_percepcion, c.jurisdiccion NULLS FIRST), '[]'::jsonb)
    INTO v_total, v_detalle
  FROM calc c;

  RETURN jsonb_build_object('total', round(v_total, 2), 'detalle', v_detalle);
END;
$$;

-- ── 4) Helper de inserción ───────────────────────────────────────
-- Recibe el `detalle` ya normalizado por crm_calc_percepciones (no el input crudo).
CREATE OR REPLACE FUNCTION crm_insert_percepciones(
  p_factura_id integer,
  p_nota_id    integer,
  p_detalle    jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF p_detalle IS NULL OR jsonb_array_length(p_detalle) = 0 THEN
    RETURN;
  END IF;

  INSERT INTO percepciones
    (factura_id, nota_id, tipo_percepcion, jurisdiccion, base_imponible, alicuota, monto)
  SELECT p_factura_id, p_nota_id,
         d->>'tipo_percepcion',
         NULLIF(d->>'jurisdiccion', ''),
         (d->>'base_imponible')::numeric,
         (d->>'alicuota')::numeric,
         (d->>'monto')::numeric
  FROM jsonb_array_elements(p_detalle) AS d;
END;
$$;

-- ── 5) crear_factura: + p_percepciones ───────────────────────────
-- DROP + CREATE y no CREATE OR REPLACE: con una lista de argumentos distinta, REPLACE crea una
-- sobrecarga en vez de reemplazar, y dos crear_factura conviviendo es ambigüedad en PostgREST
-- (mismo razonamiento que la migración 20260821130000).
DROP FUNCTION IF EXISTS crear_factura(integer, jsonb, varchar, numeric, integer[], integer, text);

CREATE OR REPLACE FUNCTION crear_factura(
  p_cliente_id        integer,
  p_items             jsonb,
  p_tipo              varchar   DEFAULT 'A',
  p_descuento_general numeric   DEFAULT 0,
  p_remito_ids        integer[] DEFAULT NULL,
  p_presupuesto_id    integer   DEFAULT NULL,
  p_observaciones     text      DEFAULT NULL,
  p_percepciones      jsonb     DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num      record;
  v_tot      jsonb;
  v_perc     jsonb;
  v_fac      facturas;
  v_contador text;
  v_iva_alic numeric;
  v_rems     integer[];
  v_cant     integer;
  v_primero  integer;
  v_malo     text;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;
  IF p_tipo NOT IN ('A','B') THEN
    RAISE EXCEPTION 'Tipo de factura inválido (A o B).';
  END IF;

  -- Normaliza la lista: sin NULLs y sin repetidos (marcar dos veces el mismo remito
  -- en la grilla no puede contar doble).
  SELECT array_agg(DISTINCT x) INTO v_rems
  FROM unnest(COALESCE(p_remito_ids, ARRAY[]::integer[])) AS x
  WHERE x IS NOT NULL;
  v_rems := COALESCE(v_rems, ARRAY[]::integer[]);
  v_cant := array_length(v_rems, 1);

  IF v_cant > 0 THEN
    -- Un remito inexistente, de otro cliente o ya facturado/anulado invalida la
    -- factura entera: se aborta antes de consumir un número de comprobante.
    SELECT string_agg(t.detalle, '; ') INTO v_malo
    FROM (
      SELECT CASE
               WHEN r.id IS NULL             THEN 'remito id=' || e.rid || ' inexistente'
               WHEN r.cliente_id <> p_cliente_id THEN 'el remito ' || r.numero || ' es de otro cliente'
               ELSE 'el remito ' || r.numero || ' no está pendiente (' || r.estado || ')'
             END AS detalle
      FROM unnest(v_rems) AS e(rid)
      LEFT JOIN remitos r ON r.id = e.rid
      WHERE r.id IS NULL OR r.cliente_id <> p_cliente_id OR r.estado <> 'pendiente'
    ) t;

    IF v_malo IS NOT NULL THEN
      RAISE EXCEPTION 'No se puede facturar: %.', v_malo;
    END IF;

    SELECT r.id INTO v_primero
    FROM remitos r WHERE r.id = ANY(v_rems)
    ORDER BY r.numero LIMIT 1;
  END IF;

  v_contador := CASE p_tipo WHEN 'A' THEN 'factura_a' ELSE 'factura_b' END;

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  -- tasa legacy de cabecera: única alícuota → su %; varias → tasa efectiva (iva/neto).
  v_iva_alic := CASE
    WHEN jsonb_array_length(v_tot->'detalle') = 1 THEN (v_tot->'detalle'->0->>'porcentaje')::numeric
    WHEN (v_tot->>'neto_gravado')::numeric > 0
      THEN round((v_tot->>'iva_monto')::numeric / (v_tot->>'neto_gravado')::numeric * 100, 2)
    ELSE 21
  END;

  -- Percepciones sobre el neto gravado ya descontado.
  v_perc := crm_calc_percepciones(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  SELECT * INTO v_num FROM siguiente_numero(v_contador);

  INSERT INTO facturas
    (numero, punto_venta, numero_comp, tipo, fecha, cliente_id, remito_id, presupuesto_id,
     descuento_general, subtotal, descuento_monto, neto_gravado, iva_alicuota, iva_monto,
     percepciones_monto, total, estado, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, p_tipo, CURRENT_DATE, p_cliente_id,
     v_primero, p_presupuesto_id, COALESCE(p_descuento_general, 0),
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric, (v_tot->>'neto_gravado')::numeric,
     v_iva_alic, (v_tot->>'iva_monto')::numeric,
     (v_perc->>'total')::numeric,
     round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
     'pendiente', p_observaciones)
  RETURNING * INTO v_fac;

  PERFORM crm_insert_factura_items(v_fac.id, p_items);
  PERFORM crm_insert_percepciones(v_fac.id, NULL, v_perc->'detalle');

  IF v_cant > 0 THEN
    UPDATE remitos SET estado = 'facturado', factura_id = v_fac.id, updated_at = NOW()
    WHERE id = ANY(v_rems);
  END IF;
  IF p_presupuesto_id IS NOT NULL THEN
    UPDATE presupuestos SET estado = 'convertido', updated_at = NOW() WHERE id = p_presupuesto_id;
  END IF;

  RETURN v_fac;
END;
$$;

-- ── 6) actualizar_factura: + p_percepciones ──────────────────────
DROP FUNCTION IF EXISTS actualizar_factura(integer, integer, jsonb, numeric, text);

CREATE OR REPLACE FUNCTION actualizar_factura(
  p_id integer, p_cliente_id integer, p_items jsonb, p_descuento_general numeric DEFAULT 0,
  p_observaciones text DEFAULT NULL, p_percepciones jsonb DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur      facturas;
  v_tot      jsonb;
  v_perc     jsonb;
  v_fac      facturas;
  v_iva_alic numeric;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_cur FROM facturas WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura no encontrada';
  END IF;
  IF v_cur.estado <> 'pendiente' THEN
    RAISE EXCEPTION 'Solo se pueden editar facturas en estado pendiente.';
  END IF;

  v_tot := crm_calc_totales_multi_alicuota(p_items, p_descuento_general);
  v_iva_alic := CASE
    WHEN jsonb_array_length(v_tot->'detalle') = 1 THEN (v_tot->'detalle'->0->>'porcentaje')::numeric
    WHEN (v_tot->>'neto_gravado')::numeric > 0
      THEN round((v_tot->>'iva_monto')::numeric / (v_tot->>'neto_gravado')::numeric * 100, 2)
    ELSE 21
  END;

  -- NULL ⇒ se recalculan como vacías y se borra el detalle: editar una factura sin mandar
  -- percepciones las quita, igual que pasa con los ítems (DELETE + re-insert).
  v_perc := crm_calc_percepciones(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  UPDATE facturas SET
    cliente_id         = p_cliente_id,
    descuento_general  = COALESCE(p_descuento_general, 0),
    subtotal           = (v_tot->>'subtotal')::numeric,
    descuento_monto    = (v_tot->>'descuento_monto')::numeric,
    neto_gravado       = (v_tot->>'neto_gravado')::numeric,
    iva_alicuota       = v_iva_alic,
    iva_monto          = (v_tot->>'iva_monto')::numeric,
    percepciones_monto = (v_perc->>'total')::numeric,
    total              = round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
    observaciones      = p_observaciones,
    updated_at         = NOW()
  WHERE id = p_id
  RETURNING * INTO v_fac;

  DELETE FROM factura_items WHERE factura_id = p_id;
  PERFORM crm_insert_factura_items(p_id, p_items);

  DELETE FROM percepciones WHERE factura_id = p_id;
  PERFORM crm_insert_percepciones(p_id, NULL, v_perc->'detalle');

  RETURN v_fac;
END;
$$;

-- ── 7) crear_nota: + p_percepciones ──────────────────────────────
-- Las NC/ND también las llevan: GVA42 se indexa por (T_COMP, N_COMP) y T_COMP incluye N/C y N/D.
DROP FUNCTION IF EXISTS crear_nota(integer, varchar, jsonb, text, text);

CREATE OR REPLACE FUNCTION crear_nota(
  p_factura_id integer, p_tipo varchar, p_items jsonb, p_motivo text DEFAULT NULL,
  p_observaciones text DEFAULT NULL, p_percepciones jsonb DEFAULT NULL
)
RETURNS notas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_fac      facturas;
  v_num      record;
  v_tot      jsonb;
  v_perc     jsonb;
  v_nota     notas;
  v_contador text;
BEGIN
  IF p_factura_id IS NULL THEN
    RAISE EXCEPTION 'La factura de referencia es obligatoria.';
  END IF;
  IF p_tipo NOT IN ('NC','ND') THEN
    RAISE EXCEPTION 'Tipo inválido (NC o ND).';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_fac FROM facturas WHERE id = p_factura_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura no encontrada';
  END IF;
  IF v_fac.estado = 'anulada' THEN
    RAISE EXCEPTION 'No se puede crear nota sobre una factura anulada.';
  END IF;

  v_contador := CASE p_tipo WHEN 'NC' THEN 'nota_credito' ELSE 'nota_debito' END;

  v_tot  := crm_calc_totales_multi_alicuota(p_items, 0);
  v_perc := crm_calc_percepciones(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  SELECT * INTO v_num FROM siguiente_numero(v_contador);

  INSERT INTO notas
    (numero, punto_venta, numero_comp, tipo, tipo_letra, fecha, factura_id, motivo,
     subtotal, descuento_monto, neto_gravado, iva_monto, percepciones_monto, total, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, p_tipo, v_fac.tipo, CURRENT_DATE,
     p_factura_id, p_motivo,
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric, (v_tot->>'neto_gravado')::numeric,
     (v_tot->>'iva_monto')::numeric,
     (v_perc->>'total')::numeric,
     round((v_tot->>'total')::numeric + (v_perc->>'total')::numeric, 2),
     p_observaciones)
  RETURNING * INTO v_nota;

  PERFORM crm_insert_nota_items(v_nota.id, p_items);
  PERFORM crm_insert_percepciones(NULL, v_nota.id, v_perc->'detalle');
  -- El saldo de la factura sale de notas.total, que ahora incluye la percepción.
  PERFORM recalcular_estado_factura(p_factura_id);

  RETURN v_nota;
END;
$$;

-- ── 8) RLS: mismo modelo "shared staff" de la 0002 ───────────────
-- SIN FORCE: las RPC SECURITY DEFINER corren como owner y FORCE bloquearía sus propias escrituras.
ALTER TABLE public.percepciones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_all ON public.percepciones;
CREATE POLICY staff_all ON public.percepciones FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.percepciones      TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.percepciones_id_seq       TO authenticated;
REVOKE ALL ON public.percepciones                                FROM anon;
REVOKE ALL ON SEQUENCE public.percepciones_id_seq                FROM anon;

-- ── 9) Permisos de las funciones ─────────────────────────────────
-- Helpers internos: sólo los invocan las RPC SECURITY DEFINER (que corren como owner).
REVOKE ALL ON FUNCTION crm_calc_percepciones(jsonb, numeric)        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION crm_insert_percepciones(integer, integer, jsonb) FROM PUBLIC, anon, authenticated;

-- Las 3 RPC se recrearon con firma nueva ⇒ hay que re-otorgar (DROP se llevó los grants viejos).
REVOKE ALL ON FUNCTION crear_factura(integer, jsonb, varchar, numeric, integer[], integer, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_factura(integer, integer, jsonb, numeric, text, jsonb)                FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_nota(integer, varchar, jsonb, text, text, jsonb)                           FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_factura(integer, jsonb, varchar, numeric, integer[], integer, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_factura(integer, integer, jsonb, numeric, text, jsonb)                TO authenticated;
GRANT EXECUTE ON FUNCTION crear_nota(integer, varchar, jsonb, text, text, jsonb)                           TO authenticated;
