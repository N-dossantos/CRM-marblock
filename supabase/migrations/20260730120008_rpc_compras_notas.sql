-- =============================================================
-- CRM — Fase A / migración 0108: RPC notas de compra (NC/ND)  §4.5/§4.11
-- Siempre ligadas a una factura de compra. NC reduce lo que debemos, ND lo aumenta;
-- ambas re-disparan recalcular_estado_factura_compra. Numeración del proveedor (parámetros).
-- proveedor_id se deriva de la factura. Totales server-side (multi-alícuota, sin desglose
-- persistido: notas_compra no tiene tabla de detalle IVA).
-- =============================================================

CREATE OR REPLACE FUNCTION crm_insert_nota_compra_items(
  p_nota_compra_id integer, p_items jsonb
)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO nota_compra_items
    (nota_compra_id, material_id, descripcion, cantidad, precio_unitario, descuento_item, subtotal, orden)
  SELECT
    p_nota_compra_id,
    NULLIF(e.item->>'material_id', '')::integer,
    e.item->>'descripcion',
    (e.item->>'cantidad')::numeric,
    (e.item->>'precio_unitario')::numeric,
    COALESCE((e.item->>'descuento_item')::numeric, 0),
    round((e.item->>'cantidad')::numeric
        * (e.item->>'precio_unitario')::numeric
        * (1 - COALESCE((e.item->>'descuento_item')::numeric, 0) / 100), 2),
    (e.ord - 1)::integer
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, ord);
END;
$$;

CREATE OR REPLACE FUNCTION crear_nota_compra(
  p_factura_compra_id integer,
  p_tipo              varchar,
  p_punto_venta       text,
  p_numero_comp       integer,
  p_fecha             date,
  p_items             jsonb,
  p_tipo_letra        varchar DEFAULT 'A',
  p_motivo            text    DEFAULT NULL,
  p_observaciones     text    DEFAULT NULL
)
RETURNS notas_compra
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_prov   integer;
  v_tot    jsonb;
  v_numero varchar;
  v_nc     notas_compra;
BEGIN
  IF p_tipo NOT IN ('NC','ND') THEN
    RAISE EXCEPTION 'Tipo de nota inválido (NC/ND).';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT proveedor_id INTO v_prov FROM facturas_compra WHERE id = p_factura_compra_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Factura de compra no encontrada';
  END IF;

  v_numero := lpad(p_punto_venta, 5, '0') || '-' || lpad(p_numero_comp::text, 8, '0');
  v_tot    := crm_calc_totales_multi_alicuota(p_items, 0);

  INSERT INTO notas_compra
    (proveedor_id, tipo, tipo_letra, punto_venta, numero_comp, numero, fecha, factura_compra_id,
     motivo, subtotal, descuento_monto, neto_gravado, iva_monto, total, observaciones)
  VALUES
    (v_prov, p_tipo, COALESCE(p_tipo_letra, 'A'), lpad(p_punto_venta, 5, '0'), p_numero_comp,
     v_numero, p_fecha, p_factura_compra_id, p_motivo,
     (v_tot->>'subtotal')::numeric, (v_tot->>'descuento_monto')::numeric,
     (v_tot->>'neto_gravado')::numeric, (v_tot->>'iva_monto')::numeric,
     (v_tot->>'total')::numeric, p_observaciones)
  RETURNING * INTO v_nc;

  PERFORM crm_insert_nota_compra_items(v_nc.id, p_items);
  PERFORM recalcular_estado_factura_compra(p_factura_compra_id);
  RETURN v_nc;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Ya existe una nota % del proveedor con ese punto de venta y número (%).', p_tipo, v_numero;
END;
$$;

REVOKE ALL ON FUNCTION crm_insert_nota_compra_items(integer, jsonb)                                    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION crear_nota_compra(integer, varchar, text, integer, date, jsonb, varchar, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crear_nota_compra(integer, varchar, text, integer, date, jsonb, varchar, text, text) TO authenticated;
