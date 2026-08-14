-- =============================================================
-- CRM — Fase A / migración 0104: totales multi-alícuota (Compras)  §4.4
-- Contrato de totales generales igual a crm_calc_totales(), pero agrupando por alícuota:
-- las facturas de proveedor mezclan 0/10.5/21/27 legítimamente y el Libro IVA Compras
-- necesita el desglose. Devuelve jsonb: totales generales + `detalle` (una fila por alícuota,
-- lista para persistir en factura_compra_iva_detalle).
--
-- Cada ítem trae `alicuota_iva_id`; si viene vacío se asume la fila de 21% (comportamiento
-- implícito de hoy). El descuento general se prorratea sobre el neto de cada grupo.
-- STABLE (no IMMUTABLE): lee la tabla alicuotas_iva.
-- =============================================================

CREATE OR REPLACE FUNCTION crm_calc_totales_multi_alicuota(
  p_items             jsonb,
  p_descuento_general numeric DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_subtotal numeric := 0;
  v_desc     numeric := 0;
  v_neto     numeric := 0;
  v_iva      numeric := 0;
  v_factor   numeric := 0;   -- (1 - dto_general/100), prorrateo del descuento sobre cada grupo
  v_detalle  jsonb;
BEGIN
  -- subtotal = Σ neto por ítem (pre-descuento general)
  SELECT COALESCE(SUM(
           (it->>'cantidad')::numeric
         * (it->>'precio_unitario')::numeric
         * (1 - COALESCE((it->>'descuento_item')::numeric, 0) / 100)
         ), 0)
    INTO v_subtotal
  FROM jsonb_array_elements(p_items) AS it;

  v_desc   := v_subtotal * (COALESCE(p_descuento_general, 0) / 100);
  v_neto   := v_subtotal - v_desc;
  v_factor := 1 - COALESCE(p_descuento_general, 0) / 100;

  -- Desglose por alícuota (neto post-descuento general + IVA del grupo).
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'alicuota_iva_id', g.alicuota_iva_id,
           'porcentaje',      g.porcentaje,
           'neto_gravado',    round(g.neto_grp, 2),
           'iva_monto',       round(g.neto_grp * g.porcentaje / 100, 2)
         ) ORDER BY g.porcentaje), '[]'::jsonb),
         COALESCE(SUM(round(g.neto_grp * g.porcentaje / 100, 2)), 0)
    INTO v_detalle, v_iva
  FROM (
    SELECT a.id AS alicuota_iva_id, a.porcentaje,
           SUM( (it->>'cantidad')::numeric
              * (it->>'precio_unitario')::numeric
              * (1 - COALESCE((it->>'descuento_item')::numeric, 0) / 100) ) * v_factor AS neto_grp
    FROM jsonb_array_elements(p_items) AS it
    JOIN alicuotas_iva a
      ON a.id = COALESCE(NULLIF(it->>'alicuota_iva_id', '')::int,
                         (SELECT id FROM alicuotas_iva WHERE porcentaje = 21))
    GROUP BY a.id, a.porcentaje
  ) g;

  RETURN jsonb_build_object(
    'subtotal',        round(v_subtotal, 2),
    'descuento_monto', round(v_desc, 2),
    'neto_gravado',    round(v_neto, 2),
    'iva_monto',       round(v_iva, 2),
    'total',           round(v_neto + v_iva, 2),
    'detalle',         v_detalle
  );
END;
$$;

REVOKE ALL ON FUNCTION crm_calc_totales_multi_alicuota(jsonb, numeric) FROM PUBLIC, anon;
-- Helper interno: sólo lo invocan las RPC SECURITY DEFINER (que corren como owner).
