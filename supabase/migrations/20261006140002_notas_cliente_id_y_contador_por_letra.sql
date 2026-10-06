-- =============================================================
-- Ventas — `notas.cliente_id` (H22) y contador de NC/ND por letra (H16)
-- PLAN_MIGRACION_TANGO.md §3 (H22 y H16), decididos el 2026-10-06.
--
-- ── H22: notas sin factura quedaban sin cliente ──────────────────
-- `notas` nunca tuvo `cliente_id`: el cliente se deducía con JOIN a `facturas`. Mientras
-- `factura_id` era NOT NULL eso alcanzaba, pero D2 (20261006120000) lo volvió nullable para las 30
-- NC/ND que Tango tiene "a cuenta" o anuladas sin imputar. Esas notas —23 reales, 18 clientes,
-- $5,59 M netos— quedaban SIN cliente: invisibles en `notas_list` y ausentes del saldo de la cuenta
-- corriente, así que la base no podía reproducir `GVA14.SALDO_CC`, que es el control de aceptación
-- de la Tarea 10 del cutover.
--
-- La columna es la fuente de verdad de acá en adelante; el backfill la llena desde la factura para
-- todo lo existente y las lecturas usan COALESCE(n.cliente_id, f.cliente_id) para no depender de
-- que el backfill haya corrido en todos los entornos.
--
-- ── H16: NC A y NC B compartían numerador ────────────────────────
-- `contadores.tipo` es PK y `crear_nota` elegía 'nota_credito' / 'nota_debito' sin mirar la letra,
-- así que una NC B tomaba el número que seguía de la serie A. Son series fiscales distintas: en
-- Tango la N/C A 0002 va por 165 y la N/C B 0002 por 1. La unicidad ya la relajó 20261006130000
-- (no hay choque de PK), pero la numeración igual salía mal. Se parte en cuatro contadores.
-- Las filas de `contadores` no se siembran acá: las carga el cutover con el último número de cada
-- serie confirmado contra ARCA (D5, `supabase/tango/05_cargar.sh`).
-- =============================================================

-- ── 1) notas.cliente_id ──────────────────────────────────────────
-- Nullable sólo porque el backfill corre después del ADD; a partir del cutover está siempre llena
-- (la carga la trae de GVA12.COD_CLIENT y `crear_nota` la setea desde la factura).
ALTER TABLE notas ADD COLUMN IF NOT EXISTS cliente_id INTEGER REFERENCES clientes(id);

UPDATE notas n SET cliente_id = f.cliente_id
FROM facturas f
WHERE f.id = n.factura_id AND n.cliente_id IS NULL;

-- FK sin índice = seq scan al listar las notas de un cliente y al borrar un cliente.
CREATE INDEX IF NOT EXISTS idx_notas_cliente ON notas(cliente_id);

COMMENT ON COLUMN notas.cliente_id IS
  'Cliente de la nota. Redundante con facturas.cliente_id cuando factura_id no es NULL, y la única '
  'fuente cuando la nota no está imputada (NC/ND "a cuenta" de Tango, H22).';

-- ── 2) crear_nota: cliente_id + contador por letra ───────────────
-- Misma firma que 20260821140000 ⇒ CREATE OR REPLACE alcanza y los grants se conservan.
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

  -- La nota hereda la letra de la factura, y cada letra tiene su propia serie fiscal (H16).
  v_contador := CASE p_tipo WHEN 'NC' THEN 'nota_credito' ELSE 'nota_debito' END
                || CASE v_fac.tipo WHEN 'B' THEN '_b' ELSE '' END;

  v_tot  := crm_calc_totales_multi_alicuota(p_items, 0);
  v_perc := crm_calc_percepciones(p_percepciones, (v_tot->>'neto_gravado')::numeric);

  SELECT * INTO v_num FROM siguiente_numero(v_contador);

  INSERT INTO notas
    (numero, punto_venta, numero_comp, tipo, tipo_letra, fecha, factura_id, cliente_id, motivo,
     subtotal, descuento_monto, neto_gravado, iva_monto, percepciones_monto, total, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, p_tipo, v_fac.tipo, CURRENT_DATE,
     p_factura_id, v_fac.cliente_id, p_motivo,
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

-- ── 3) notas_list: LEFT JOIN y cliente propio ────────────────────
-- Era INNER JOIN contra facturas y clientes: una nota sin factura no aparecía. Ahora el cliente
-- sale de la nota (con fallback a la factura) y la factura es opcional.
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
      (SELECT json_agg(json_build_object(
                'id', pc.id, 'tipo_percepcion', pc.tipo_percepcion, 'jurisdiccion', pc.jurisdiccion,
                'base_imponible', pc.base_imponible, 'alicuota', pc.alicuota, 'monto', pc.monto
              ) ORDER BY pc.tipo_percepcion, pc.jurisdiccion)
         FROM percepciones pc WHERE pc.nota_id = n.id) AS percepciones,
      json_agg(json_build_object(
        'id', ni.id, 'producto_id', ni.producto_id, 'codigo', pr.codigo, 'descripcion', ni.descripcion,
        'cantidad', ni.cantidad, 'precio_unitario', ni.precio_unitario,
        'descuento_item', ni.descuento_item, 'subtotal', ni.subtotal, 'orden', ni.orden,
        'alicuota_iva_id', ni.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', ni.pallets, 'unidades_por_pallet', ni.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
      ) ORDER BY ni.orden) FILTER (WHERE ni.id IS NOT NULL) AS items
    FROM notas n
    LEFT JOIN facturas f ON f.id = n.factura_id
    LEFT JOIN clientes c ON c.id = COALESCE(n.cliente_id, f.cliente_id)
    LEFT JOIN nota_items ni ON ni.nota_id = n.id
    LEFT JOIN productos pr ON pr.id = ni.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = ni.alicuota_iva_id
    WHERE (p_id IS NULL OR n.id = p_id)
      AND (p_tipo IS NULL OR n.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR COALESCE(n.cliente_id, f.cliente_id) = p_cliente_id)
      AND (p_q IS NULL OR n.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR f.numero ILIKE '%'||p_q||'%')
    GROUP BY n.id, f.numero, f.tipo, c.razon_social, c.cuit, c.condicion_iva, c.direccion
    ORDER BY n.fecha DESC
  ) t;
$$;

-- ── 4) informe_cta_cte: las notas sin factura también cuentan ────
-- Las dos ramas de notas filtraban por `f.cliente_id`, así que una nota sin factura quedaba fuera
-- del saldo. Ahora se filtra por el cliente de la nota, con fallback a la factura.
CREATE OR REPLACE FUNCTION informe_cta_cte(
  p_cliente_id integer, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_cli   jsonb;
  v_movs  jsonb;
  v_saldo numeric;
BEGIN
  SELECT to_jsonb(c) INTO v_cli FROM clientes c WHERE c.id = p_cliente_id;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'Cliente no encontrado';
  END IF;

  WITH movs AS (
    SELECT f.id, f.fecha, f.numero AS comprobante, 'FACTURA'::text AS tipo,
           f.total AS debe, 0::numeric AS haber
    FROM facturas f
    WHERE f.cliente_id = p_cliente_id AND f.estado <> 'anulada'
      AND (p_desde IS NULL OR p_hasta IS NULL OR f.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    SELECT r.id, r.fecha, r.numero, 'RECIBO', 0::numeric, r.total
    FROM recibos r
    WHERE r.cliente_id = p_cliente_id
      AND (p_desde IS NULL OR p_hasta IS NULL OR r.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    SELECT n.id, n.fecha, n.numero, 'NOTA CRED.', 0::numeric, n.total
    FROM notas n LEFT JOIN facturas f ON f.id = n.factura_id
    WHERE COALESCE(n.cliente_id, f.cliente_id) = p_cliente_id AND n.tipo = 'NC'
      AND (p_desde IS NULL OR p_hasta IS NULL OR n.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    SELECT n.id, n.fecha, n.numero, 'NOTA DEB.', n.total, 0::numeric
    FROM notas n LEFT JOIN facturas f ON f.id = n.factura_id
    WHERE COALESCE(n.cliente_id, f.cliente_id) = p_cliente_id AND n.tipo = 'ND'
      AND (p_desde IS NULL OR p_hasta IS NULL OR n.fecha BETWEEN p_desde AND p_hasta)
  ),
  ordered AS (
    SELECT m.*,
      SUM(m.debe - m.haber) OVER (
        ORDER BY m.fecha ASC, m.comprobante ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS saldo
    FROM movs m
  )
  SELECT
    COALESCE(jsonb_agg(to_jsonb(ordered) ORDER BY ordered.fecha ASC, ordered.comprobante ASC), '[]'),
    COALESCE((SELECT o.saldo FROM ordered o ORDER BY o.fecha DESC, o.comprobante DESC LIMIT 1), 0)
  INTO v_movs, v_saldo
  FROM ordered;

  RETURN jsonb_build_object('cliente', v_cli, 'movimientos', v_movs, 'saldo_total', v_saldo);
END;
$$;

-- Las tres funciones se reemplazaron con la misma firma: los grants de 20260727120004 /
-- 20260730120011 siguen vigentes. Se re-afirman por si alguna se recreó fuera de orden.
REVOKE ALL ON FUNCTION crear_nota(integer, varchar, jsonb, text, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION notas_list(integer, text, text, integer)               FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION informe_cta_cte(integer, date, date)                   FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_nota(integer, varchar, jsonb, text, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION notas_list(integer, text, text, integer)               TO authenticated;
GRANT EXECUTE ON FUNCTION informe_cta_cte(integer, date, date)                   TO authenticated;
