-- =============================================================
-- CRM Ventas — Pallet de Madera Vacío y Servicio de Transporte quedan excluidos del descuento
-- general del cliente (%): son costos de paso, no productos negociables. El descuento por ítem
-- (descuento_item) sigue disponible en esas filas sin cambios; sólo el % automático del cliente
-- deja de aplicárseles.
--
-- Afecta a crm_calc_totales_multi_alicuota (Presupuestos/Facturas de Ventas — Compras también la
-- llama, pero sus ítems de materiales nunca traen 'es_pallet_vacio'/'es_transporte' en el jsonb,
-- así que COALESCE(...,false) los deja sin cambios de comportamiento) y a crm_calc_totales_cuenta2
-- (Remito X). El crm_calc_totales() original (21% fijo, sin agrupar) quedó sin llamadores desde la
-- migración multi-alícuota del 02/08 — no se toca.
--
-- CREATE OR REPLACE con la misma firma preserva los grants existentes.
-- =============================================================

CREATE OR REPLACE FUNCTION crm_calc_totales_multi_alicuota(
  p_items             jsonb,
  p_descuento_general numeric DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_subtotal          numeric := 0;
  v_subtotal_desc     numeric := 0;   -- base descontable: excluye pallet vacío / transporte
  v_desc              numeric := 0;
  v_neto              numeric := 0;
  v_iva               numeric := 0;
  v_detalle           jsonb;
BEGIN
  SELECT
    COALESCE(SUM(neto), 0),
    COALESCE(SUM(neto) FILTER (WHERE NOT excluido), 0)
    INTO v_subtotal, v_subtotal_desc
  FROM (
    SELECT
      (it->>'cantidad')::numeric * (it->>'precio_unitario')::numeric
        * (1 - COALESCE((it->>'descuento_item')::numeric, 0) / 100) AS neto,
      COALESCE((it->>'es_pallet_vacio')::boolean, false)
        OR COALESCE((it->>'es_transporte')::boolean, false) AS excluido
    FROM jsonb_array_elements(p_items) AS it
  ) x;

  v_desc := v_subtotal_desc * (COALESCE(p_descuento_general, 0) / 100);
  v_neto := v_subtotal - v_desc;

  -- Desglose por alícuota: cada grupo pasa entero el neto de las líneas excluidas y prorratea el
  -- % del cliente sólo sobre las demás.
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
           SUM(
             CASE WHEN x.excluido THEN x.neto
                  ELSE x.neto * (1 - COALESCE(p_descuento_general, 0) / 100)
             END
           ) AS neto_grp
    FROM (
      SELECT
        it,
        (it->>'cantidad')::numeric * (it->>'precio_unitario')::numeric
          * (1 - COALESCE((it->>'descuento_item')::numeric, 0) / 100) AS neto,
        COALESCE((it->>'es_pallet_vacio')::boolean, false)
          OR COALESCE((it->>'es_transporte')::boolean, false) AS excluido
      FROM jsonb_array_elements(p_items) AS it
    ) x
    JOIN alicuotas_iva a
      ON a.id = COALESCE(NULLIF(x.it->>'alicuota_iva_id', '')::int,
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

CREATE OR REPLACE FUNCTION crm_calc_totales_cuenta2(
  p_items             jsonb,
  p_descuento_general numeric DEFAULT 0
)
RETURNS TABLE (
  subtotal        numeric,
  descuento_monto numeric,
  total           numeric
)
LANGUAGE plpgsql IMMUTABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_subtotal      numeric := 0;
  v_subtotal_desc numeric := 0;
  v_desc          numeric := 0;
BEGIN
  SELECT
    COALESCE(SUM(neto), 0),
    COALESCE(SUM(neto) FILTER (WHERE NOT excluido), 0)
    INTO v_subtotal, v_subtotal_desc
  FROM (
    SELECT
      (it->>'cantidad')::numeric * (it->>'precio_unitario')::numeric
        * (1 - COALESCE((it->>'descuento_item')::numeric, 0) / 100) AS neto,
      COALESCE((it->>'es_pallet_vacio')::boolean, false)
        OR COALESCE((it->>'es_transporte')::boolean, false) AS excluido
    FROM jsonb_array_elements(p_items) AS it
  ) x;

  v_desc := v_subtotal_desc * (COALESCE(p_descuento_general, 0) / 100);

  subtotal        := round(v_subtotal, 2);
  descuento_monto := round(v_desc, 2);
  total           := round(v_subtotal - v_desc, 2);
  RETURN NEXT;
END;
$$;
