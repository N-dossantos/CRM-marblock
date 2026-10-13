-- ══════════════════════════════════════════════════════════════════
-- Cuenta 2: saldo anterior en la cuenta corriente filtrada por fecha (2026-10-13).
--
-- informe_cta_cte_cuenta2 tenía el mismo error que M8 arregló en Cuenta 1
-- (20261009120000_informes_orden_y_saldos.sql): con período, el saldo corrido arrancaba de 0 y el
-- filtro sólo se aplicaba si venían las DOS fechas. Ahora:
--   - `desde` y `hasta` filtran por separado;
--   - si hay `desde`, la primera fila es SALDO ANTERIOR (todo lo previo a `desde`) y el saldo
--     corrido parte de ahí, así cada fila muestra el mismo saldo que en la vista sin filtro;
--   - `saldo_total` es SIEMPRE el saldo actual de la entidad, con o sin filtro: la pantalla y el
--     PDF lo rotulan "Saldo actual" (y coincide con el saldo del listado de entidades). A
--     diferencia de Cuenta 1, `hasta` no lo cambia; el saldo a esa fecha es el de la última fila.
-- Se agregan `saldo_anterior`, `desde` y `hasta` a la respuesta. La fila sintética usa las mismas
-- claves que las demás (id NULL), así que la tabla y el PDF la imprimen sin cambios de forma.
-- Orden con desempate por tipo e id (remito y cobro del mismo día salían en orden arbitrario).
--
-- Conserva la firma: los grants vigentes siguen aplicando; se re-afirman al final.
-- ══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION informe_cta_cte_cuenta2(
  p_tipo_sector text,
  p_entidad_id  integer,
  p_desde       date DEFAULT NULL,
  p_hasta       date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_ent      jsonb;
  v_movs     jsonb;
  v_anterior numeric;
  v_saldo    numeric;
BEGIN
  IF p_tipo_sector NOT IN ('venta','compra') THEN
    RAISE EXCEPTION 'Sector inválido: debe ser venta o compra.';
  END IF;

  IF p_tipo_sector = 'venta' THEN
    SELECT to_jsonb(c) INTO v_ent FROM clientes_cuenta2 c WHERE c.id = p_entidad_id;
  ELSE
    SELECT to_jsonb(p) INTO v_ent FROM proveedores_cuenta2 p WHERE p.id = p_entidad_id;
  END IF;
  IF v_ent IS NULL THEN
    RAISE EXCEPTION 'Cliente/proveedor de Cuenta 2 no encontrado';
  END IF;

  WITH movs AS (
    SELECT r.id, r.fecha, r.numero AS comprobante, 'REMITO X'::text AS tipo,
           r.total AS debe, 0::numeric AS haber
    FROM cuenta2_remitos r
    WHERE r.tipo_sector = p_tipo_sector
      AND (r.cliente_id = p_entidad_id OR r.proveedor_id = p_entidad_id)
    UNION ALL
    SELECT m.id, m.fecha, m.concepto, m.tipo, m.debe, m.haber
    FROM cuenta2_movimientos m
    WHERE m.tipo_sector = p_tipo_sector
      AND (m.cliente_id = p_entidad_id OR m.proveedor_id = p_entidad_id)
  ),
  anterior AS (
    SELECT COALESCE(SUM(m.debe - m.haber), 0) AS saldo
    FROM movs m WHERE p_desde IS NOT NULL AND m.fecha < p_desde
  ),
  ordered AS (
    SELECT m.*,
      (SELECT saldo FROM anterior) + SUM(m.debe - m.haber) OVER (
        ORDER BY m.fecha ASC, m.comprobante ASC, m.tipo ASC, m.id ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS saldo
    FROM movs m
    WHERE (p_desde IS NULL OR m.fecha >= p_desde)
      AND (p_hasta IS NULL OR m.fecha <= p_hasta)
  )
  SELECT
    COALESCE((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.fecha, o.comprobante, o.tipo, o.id) FROM ordered o), '[]'),
    (SELECT saldo FROM anterior),
    (SELECT COALESCE(SUM(m.debe - m.haber), 0) FROM movs m)
  INTO v_movs, v_anterior, v_saldo;

  IF p_desde IS NOT NULL THEN
    v_movs := jsonb_build_array(jsonb_build_object(
      'id', NULL, 'fecha', p_desde, 'comprobante', '—', 'tipo', 'SALDO ANTERIOR',
      'debe', 0, 'haber', 0, 'saldo', v_anterior)) || v_movs;
  END IF;

  RETURN jsonb_build_object(
    'entidad', v_ent, 'movimientos', v_movs, 'saldo_total', v_saldo,
    'saldo_anterior', v_anterior, 'desde', p_desde, 'hasta', p_hasta);
END;
$$;

REVOKE ALL ON FUNCTION informe_cta_cte_cuenta2(text, integer, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION informe_cta_cte_cuenta2(text, integer, date, date) TO authenticated;
