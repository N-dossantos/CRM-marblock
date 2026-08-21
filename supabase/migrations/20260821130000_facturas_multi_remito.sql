-- =============================================================
-- Ventas — facturar varios remitos en una sola factura
--
-- El esquema ya lo soportaba: remitos.factura_id es un FK a facturas SIN UNIQUE
-- (schema 0001, idx_remitos_factura), o sea N remitos pueden apuntar a la misma
-- factura. El que modelaba mal la relación era facturas.remito_id — el lado "1"
-- de algo que en realidad es "N". Esta migración NO toca tablas: sólo cambia las
-- funciones para que la fuente de verdad pase a ser remitos.factura_id.
--
-- facturas.remito_id se sigue escribiendo (con el remito de número más bajo) para
-- no romper a los lectores que todavía lo leen — el template del PDF
-- (functions/pdf/templates.ts) y VentaDetalle.jsx. Queda como denormalización de
-- compatibilidad, no como fuente de verdad.
--
-- factura_anular NO se toca: ya liberaba con `WHERE factura_id = p_id`, que es
-- plural desde el día uno.
-- =============================================================

-- ── crear_factura: p_remito_id integer → p_remito_ids integer[] ──────────────
-- DROP + CREATE en vez de agregar un parámetro con default: CREATE OR REPLACE con
-- una lista de argumentos distinta no reemplaza, crea una sobrecarga, y dos
-- crear_factura conviviendo es justo la ambigüedad que no queremos en PostgREST.
DROP FUNCTION IF EXISTS crear_factura(integer, jsonb, varchar, numeric, integer, integer, text);

CREATE OR REPLACE FUNCTION crear_factura(
  p_cliente_id        integer,
  p_items             jsonb,
  p_tipo              varchar   DEFAULT 'A',
  p_descuento_general numeric   DEFAULT 0,
  p_remito_ids        integer[] DEFAULT NULL,
  p_presupuesto_id    integer   DEFAULT NULL,
  p_observaciones     text      DEFAULT NULL
)
RETURNS facturas
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_num      record;
  v_tot      jsonb;
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

  SELECT * INTO v_num FROM siguiente_numero(v_contador);

  INSERT INTO facturas
    (numero, punto_venta, numero_comp, tipo, fecha, cliente_id, remito_id, presupuesto_id,
     descuento_general, subtotal, descuento_monto, neto_gravado, iva_alicuota, iva_monto, total,
     estado, observaciones)
  VALUES
    (v_num.numero_formateado, v_num.punto_venta, v_num.numero, p_tipo, CURRENT_DATE, p_cliente_id,
     v_primero, p_presupuesto_id, COALESCE(p_descuento_general, 0),
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric, (v_tot->>'neto_gravado')::numeric,
     v_iva_alic, (v_tot->>'iva_monto')::numeric, (v_tot->>'total')::numeric,
     'pendiente', p_observaciones)
  RETURNING * INTO v_fac;

  PERFORM crm_insert_factura_items(v_fac.id, p_items);

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

-- ── facturas_list: expone los N remitos vinculados ───────────────────────────
-- Recreada desde 20260819120003 agregando `remitos` (array json) y corrigiendo
-- `remito_numero` / `p_solo_sin_remito` para que miren remitos.factura_id.
-- Los remitos van como subconsulta correlacionada, no como JOIN: un join
-- multiplicaría las filas y rompería el json_agg de los ítems.
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
      -- Compat: el PDF y VentaDetalle siguen mostrando un único número.
      COALESCE(r.numero, (SELECT min(rr.numero) FROM remitos rr WHERE rr.factura_id = f.id))
        AS remito_numero,
      (SELECT json_agg(json_build_object('id', rr.id, 'numero', rr.numero) ORDER BY rr.numero)
         FROM remitos rr WHERE rr.factura_id = f.id) AS remitos,
      p.numero AS presupuesto_numero,
      json_agg(json_build_object(
        'id', fi.id, 'producto_id', fi.producto_id, 'codigo', pr.codigo, 'descripcion', fi.descripcion,
        'cantidad', fi.cantidad, 'precio_unitario', fi.precio_unitario,
        'descuento_item', fi.descuento_item, 'subtotal', fi.subtotal, 'orden', fi.orden,
        'alicuota_iva_id', fi.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', fi.pallets, 'unidades_por_pallet', fi.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
      ) ORDER BY fi.orden) FILTER (WHERE fi.id IS NOT NULL) AS items
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    LEFT JOIN remitos r ON r.id = f.remito_id
    LEFT JOIN presupuestos p ON p.id = f.presupuesto_id
    LEFT JOIN factura_items fi ON fi.factura_id = f.id
    LEFT JOIN productos pr ON pr.id = fi.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = fi.alicuota_iva_id
    WHERE (p_id IS NULL OR f.id = p_id)
      AND (p_estado IS NULL OR f.estado = p_estado)
      AND (p_tipo IS NULL OR f.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      AND (p_desde IS NULL OR f.fecha >= p_desde)
      AND (p_hasta IS NULL OR f.fecha <= p_hasta)
      AND (NOT p_solo_sin_remito OR (
             f.remito_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM remitos rr WHERE rr.factura_id = f.id)
             AND f.estado <> 'anulada'))
      AND (p_q IS NULL OR f.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR c.cuit ILIKE '%'||p_q||'%')
    GROUP BY f.id, c.id, r.numero, p.numero
    ORDER BY f.fecha DESC, f.numero DESC
  ) t;
$$;

-- ── informe: facturas pendientes de remitir ──────────────────────────────────
-- Mismo criterio que p_solo_sin_remito: una factura está "sin remitir" cuando
-- ningún remito la apunta (antes sólo miraba facturas.remito_id, que con
-- multi-remito deja de ser suficiente).
CREATE OR REPLACE FUNCTION informe_facturas_pendientes_remitir()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT f.id, f.numero, f.fecha, f.total, f.estado, c.razon_social, c.cuit,
      (CURRENT_DATE - f.fecha::date) AS dias_pendiente
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    WHERE f.remito_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM remitos rr WHERE rr.factura_id = f.id)
      AND f.estado <> 'anulada'
    ORDER BY f.fecha ASC
  ) t;
$$;

-- ── Permisos ─────────────────────────────────────────────────────────────────
-- El DROP se llevó los grants de crear_factura; hay que rehacerlos (y revocar de
-- anon explícitamente: las default privileges de Supabase le dan EXECUTE directo
-- y REVOKE ... FROM PUBLIC no lo alcanza — ver migraciones 0004/0010).
REVOKE ALL ON FUNCTION crear_factura(integer, jsonb, varchar, numeric, integer[], integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_factura(integer, jsonb, varchar, numeric, integer[], integer, text) TO authenticated;

REVOKE ALL ON FUNCTION facturas_list(integer, text, text, text, integer, date, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION facturas_list(integer, text, text, text, integer, date, date, boolean) TO authenticated;

REVOKE ALL ON FUNCTION informe_facturas_pendientes_remitir() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION informe_facturas_pendientes_remitir() TO authenticated;
