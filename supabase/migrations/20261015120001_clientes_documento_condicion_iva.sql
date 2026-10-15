-- =============================================================
-- ARCA — documento y condición IVA del cliente (PLAN_ARCA.md §3 y §3.2, Fase 2)
--
-- ARCA pide DocTipo + DocNro y CondicionIVAReceptorId (RG 5616). `clientes.cuit` era el único
-- documento y `clientes.condicion_iva` un texto libre: no sirven para facturar.
--
--   * doc_tipo / doc_nro: documento canónico (80 CUIT, 96 DNI), reemplaza `cuit`.
--   * condicion_iva_afip_id → condiciones_iva_afip: reemplaza el texto; su `clase` decide la letra.
--   * `cuit` y `condicion_iva` se borran: una sola fuente de verdad (AGENTS.md).
--
-- Las lecturas que devolvían c.cuit / c.condicion_iva pasan a devolver doc_tipo, doc_nro,
-- condicion_iva (la descripción del catálogo, con la misma clave), condicion_iva_afip_id y clase.
-- crear_factura y actualizar_factura rechazan una letra distinta de la clase del cliente.
--
-- ⚠ Prod: aplicar DESPUÉS de la carga de Tango (el ETL escribe cuit/condicion_iva) y junto con el
-- frontend que lee las columnas nuevas.
-- =============================================================

-- ── 1) Columnas nuevas + backfill ────────────────────────────────
ALTER TABLE clientes
  ADD COLUMN doc_tipo              SMALLINT,
  ADD COLUMN doc_nro               VARCHAR(20),
  ADD COLUMN condicion_iva_afip_id SMALLINT REFERENCES condiciones_iva_afip(id);

-- Documento: el CUIT sin guiones. Un número de 7–8 dígitos cargado en el campo CUIT es un DNI.
-- Los CUIT de relleno de la carga de Tango (00-00000000-0 del consumidor final genérico y los
-- 99-… de CUIT repetidos) quedan como 80 + 11 dígitos: se cargan, pero no se pueden facturar
-- (arca_comprobante_para_emitir exige dígito verificador válido) hasta corregirlos.
UPDATE clientes SET
  doc_nro  = regexp_replace(cuit, '\D', '', 'g'),
  doc_tipo = CASE WHEN length(regexp_replace(cuit, '\D', '', 'g')) BETWEEN 7 AND 8 THEN 96 ELSE 80 END;

-- Texto → catálogo (§3.2). Monotributista va a 6; si alguno es social (13) o promovido (16) se
-- corrige a mano. Tango no tiene categoría de monotributo: revisar los Consumidor Final con CUIT
-- cuyo último comprobante fue A, y los Resp. Inscripto cuyo último comprobante fue B.
UPDATE clientes SET condicion_iva_afip_id = CASE condicion_iva
  WHEN 'Resp. Inscripto'  THEN 1
  WHEN 'Monotributista'   THEN 6
  WHEN 'Exento'           THEN 4
  WHEN 'Consumidor Final' THEN 5
END;

-- Lo que no se pudo convertir se corrige a mano antes de reintentar: la migración no adivina.
DO $$
DECLARE v text;
BEGIN
  SELECT string_agg(format('%s (id %s): "%s"', razon_social, id, condicion_iva), '; ') INTO v
  FROM clientes WHERE condicion_iva_afip_id IS NULL;
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'Condición IVA sin equivalente en el catálogo de ARCA: %', v;
  END IF;

  SELECT string_agg(format('%s (id %s): "%s"', razon_social, id, cuit), '; ') INTO v
  FROM clientes
  WHERE NOT (length(doc_nro) = 11 OR length(doc_nro) BETWEEN 7 AND 8);
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'Documento que no es CUIT (11 dígitos) ni DNI (7–8): %', v;
  END IF;
END $$;

ALTER TABLE clientes
  ALTER COLUMN doc_tipo              SET NOT NULL,
  ALTER COLUMN doc_nro               SET NOT NULL,
  ALTER COLUMN condicion_iva_afip_id SET NOT NULL,
  ADD CONSTRAINT chk_cli_doc_tipo CHECK (doc_tipo IN (80, 96)),
  ADD CONSTRAINT chk_cli_doc_nro  CHECK (doc_nro ~ '^[0-9]+$' AND CASE doc_tipo
    WHEN 80 THEN length(doc_nro) = 11
    ELSE length(doc_nro) BETWEEN 7 AND 8 END),
  -- Mismo criterio que el UNIQUE de `cuit` que reemplaza.
  ADD CONSTRAINT clientes_doc_key UNIQUE (doc_tipo, doc_nro);

CREATE INDEX idx_clientes_condicion_iva ON clientes(condicion_iva_afip_id);

COMMENT ON COLUMN clientes.doc_tipo IS 'Tipo de documento ARCA: 80 CUIT, 96 DNI.';
COMMENT ON COLUMN clientes.doc_nro IS 'Número de documento, sólo dígitos (CUIT 11, DNI 7–8).';
COMMENT ON COLUMN clientes.condicion_iva_afip_id IS
  'Condición IVA del receptor (RG 5616). La clase del catálogo decide la letra de la factura.';

-- Las funciones de lectura que las usaban se reemplazan abajo, en la misma transacción.
ALTER TABLE clientes DROP COLUMN cuit, DROP COLUMN condicion_iva;

-- ── 2) Letra = clase de la condición IVA (§3.2) ──────────────────
-- ARCA rechaza la combinación (p. ej. Factura B a un monotributista); mejor que no llegue.
CREATE FUNCTION crm_validar_letra_cliente(p_cliente_id integer, p_letra text)
RETURNS void
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_clase char(1);
  v_cond  text;
BEGIN
  SELECT ci.clase, ci.descripcion INTO v_clase, v_cond
  FROM clientes c JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
  WHERE c.id = p_cliente_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cliente no encontrado';
  END IF;
  IF v_clase <> p_letra THEN
    RAISE EXCEPTION 'El cliente es %: le corresponde comprobante %, no %.', v_cond, v_clase, p_letra;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION crm_validar_letra_cliente(integer, text) FROM PUBLIC, anon, authenticated;

-- Misma firma y cuerpo que 20260821140000_ventas_percepciones, más la validación de letra.
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
  PERFORM crm_validar_letra_cliente(p_cliente_id, p_tipo);

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

-- Misma firma y cuerpo que 20260821140000_ventas_percepciones, más la validación de letra: el
-- cliente puede cambiar, la letra de la factura no.
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
  PERFORM crm_validar_letra_cliente(p_cliente_id, v_cur.tipo);

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

-- ── 3) Lecturas: documento y condición del catálogo ──────────────
-- Mismas firmas que la última versión de cada una (CREATE OR REPLACE conserva los grants). Donde
-- había c.cuit va doc_tipo + doc_nro (el frontend y el PDF los formatean); donde había
-- c.condicion_iva va la descripción del catálogo con la misma clave, más el id y la clase.
-- Buscar por documento compara sólo los dígitos de lo tipeado (y nada si no hay dígitos).

-- 20260727120011
CREATE OR REPLACE FUNCTION clientes_list(
  p_q text DEFAULT NULL, p_activo boolean DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.*, ci.descripcion AS condicion_iva, ci.clase,
      COALESCE(SUM(f.total) FILTER (WHERE f.estado <> 'anulada'), 0)               AS total_facturado,
      COALESCE(SUM(f.total) FILTER (WHERE f.estado IN ('pendiente','parcial')), 0) AS saldo_pendiente
    FROM clientes c
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN facturas f ON f.cliente_id = c.id
    WHERE (p_q IS NULL OR c.razon_social ILIKE '%'||p_q||'%'
           OR (regexp_replace(p_q, '\D', '', 'g') <> ''
               AND c.doc_nro LIKE '%'||regexp_replace(p_q, '\D', '', 'g')||'%'))
      AND (p_activo IS NULL OR c.activo = p_activo)
    GROUP BY c.id, ci.id
    ORDER BY c.razon_social
  ) t;
$$;

-- 20260727120011
CREATE OR REPLACE FUNCTION informe_ranking_clientes(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.id, c.razon_social, c.doc_tipo, c.doc_nro,
      COUNT(f.id) AS cantidad_facturas, SUM(f.total) AS total_facturado,
      SUM(CASE WHEN f.estado IN ('pendiente','parcial') THEN f.total ELSE 0 END) AS saldo_pendiente,
      MAX(f.fecha) AS ultima_compra
    FROM clientes c
    LEFT JOIN facturas f ON f.cliente_id = c.id AND f.estado <> 'anulada'
      AND (p_desde IS NULL OR p_hasta IS NULL OR f.fecha BETWEEN p_desde AND p_hasta)
    GROUP BY c.id
    HAVING SUM(f.total) > 0
    ORDER BY SUM(f.total) DESC LIMIT 50
  ) t;
$$;

-- 20260727120011
CREATE OR REPLACE FUNCTION informe_ranking_deudores()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.id, c.razon_social, c.doc_tipo, c.doc_nro, c.telefono, c.email,
      COUNT(f.id) AS facturas_pendientes, SUM(f.total) AS total_pendiente,
      MIN(f.fecha) AS factura_mas_antigua,
      (CURRENT_DATE - MIN(f.fecha)::date) AS dias_deuda
    FROM clientes c
    JOIN facturas f ON f.cliente_id = c.id AND f.estado IN ('pendiente','parcial')
    GROUP BY c.id
    ORDER BY SUM(f.total) DESC
  ) t;
$$;

-- 20260727120011
CREATE OR REPLACE FUNCTION informe_remitos_pendientes_facturar()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT r.id, r.numero, r.fecha, c.razon_social, c.doc_tipo, c.doc_nro,
      COUNT(ri.id) AS cantidad_items,
      (CURRENT_DATE - r.fecha::date) AS dias_pendiente
    FROM remitos r
    JOIN clientes c ON c.id = r.cliente_id
    LEFT JOIN remito_items ri ON ri.remito_id = r.id
    WHERE r.estado = 'pendiente'
    GROUP BY r.id, c.id
    ORDER BY r.fecha ASC
  ) t;
$$;

-- 20260727120011
CREATE OR REPLACE FUNCTION informe_ventas(
  p_desde date, p_hasta date, p_cliente_id integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'Parámetros desde y hasta son obligatorios.';
  END IF;
  SELECT jsonb_build_object(
    'totales', (SELECT jsonb_build_object(
      'cantidad_facturas', COUNT(f.id),
      'subtotal',          SUM(f.subtotal),
      'descuento_total',   SUM(f.descuento_monto),
      'neto_gravado',      SUM(f.neto_gravado),
      'iva_total',         SUM(f.iva_monto),
      'total_facturado',   SUM(f.total),
      'total_cobrado',     SUM(CASE WHEN f.estado = 'cobrada' THEN f.total ELSE 0 END),
      'total_pendiente',   SUM(CASE WHEN f.estado IN ('pendiente','parcial') THEN f.total ELSE 0 END))
      FROM facturas f
      WHERE f.estado <> 'anulada' AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)),
    'por_cliente', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT c.id, c.razon_social, c.doc_tipo, c.doc_nro,
        COUNT(f.id) AS cantidad_facturas, SUM(f.total) AS total_facturado,
        SUM(CASE WHEN f.estado IN ('pendiente','parcial') THEN f.total ELSE 0 END) AS pendiente
      FROM facturas f JOIN clientes c ON c.id = f.cliente_id
      WHERE f.estado <> 'anulada' AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      GROUP BY c.id
      ORDER BY SUM(f.total) DESC) x),
    'por_mes', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT TO_CHAR(f.fecha, 'YYYY-MM') AS mes, COUNT(f.id) AS cantidad, SUM(f.total) AS total
      FROM facturas f
      WHERE f.estado <> 'anulada' AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      GROUP BY TO_CHAR(f.fecha, 'YYYY-MM') ORDER BY mes) x),
    'por_producto', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT p.codigo, p.descripcion, SUM(fi.cantidad) AS total_cantidad, SUM(fi.subtotal) AS total_neto
      FROM factura_items fi JOIN facturas f ON f.id = fi.factura_id
      LEFT JOIN productos p ON p.id = fi.producto_id
      WHERE f.estado <> 'anulada' AND f.fecha BETWEEN p_desde AND p_hasta
        AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
      GROUP BY p.codigo, p.descripcion
      ORDER BY SUM(fi.subtotal) DESC LIMIT 20) x)
  ) INTO v;
  RETURN v;
END;
$$;

-- 20260821130000
CREATE OR REPLACE FUNCTION informe_facturas_pendientes_remitir()
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT f.id, f.numero, f.fecha, f.total, f.estado, c.razon_social, c.doc_tipo, c.doc_nro,
      (CURRENT_DATE - f.fecha::date) AS dias_pendiente
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    WHERE f.remito_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM remitos rr WHERE rr.factura_id = f.id)
      AND f.estado <> 'anulada'
    ORDER BY f.fecha ASC
  ) t;
$$;

-- 20261009130000
CREATE OR REPLACE FUNCTION facturas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL, p_tipo text DEFAULT NULL,
  p_cliente_id integer DEFAULT NULL, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL,
  p_solo_sin_remito boolean DEFAULT false, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT f.id, count(*) OVER () AS total_filas
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
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
                       OR (regexp_replace(p_q, '\D', '', 'g') <> ''
                           AND c.doc_nro LIKE '%'||regexp_replace(p_q, '\D', '', 'g')||'%'))
    ORDER BY f.fecha DESC, f.numero DESC, f.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
  SELECT to_jsonb(t) FROM (
    SELECT f.*,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase, c.direccion, c.email, c.telefono,
      COALESCE(r.numero, (SELECT min(rr.numero) FROM remitos rr WHERE rr.factura_id = f.id))
        AS remito_numero,
      (SELECT json_agg(json_build_object('id', rr.id, 'numero', rr.numero) ORDER BY rr.numero)
         FROM remitos rr WHERE rr.factura_id = f.id) AS remitos,
      (SELECT json_agg(json_build_object(
                'id', pc.id, 'tipo_percepcion', pc.tipo_percepcion, 'jurisdiccion', pc.jurisdiccion,
                'base_imponible', pc.base_imponible, 'alicuota', pc.alicuota, 'monto', pc.monto
              ) ORDER BY pc.tipo_percepcion, pc.jurisdiccion)
         FROM percepciones pc WHERE pc.factura_id = f.id) AS percepciones,
      p.numero AS presupuesto_numero,
      json_agg(json_build_object(
        'id', fi.id, 'producto_id', fi.producto_id, 'codigo', pr.codigo, 'descripcion', fi.descripcion,
        'cantidad', fi.cantidad, 'precio_unitario', fi.precio_unitario,
        'descuento_item', fi.descuento_item, 'subtotal', fi.subtotal, 'orden', fi.orden,
        'alicuota_iva_id', fi.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', fi.pallets, 'unidades_por_pallet', fi.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
      ) ORDER BY fi.orden) FILTER (WHERE fi.id IS NOT NULL) AS items,
      pg.total_filas
    FROM pagina pg
    JOIN facturas f ON f.id = pg.id
    JOIN clientes c ON c.id = f.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN remitos r ON r.id = f.remito_id
    LEFT JOIN presupuestos p ON p.id = f.presupuesto_id
    LEFT JOIN factura_items fi ON fi.factura_id = f.id
    LEFT JOIN productos pr ON pr.id = fi.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = fi.alicuota_iva_id
    GROUP BY f.id, c.id, ci.id, r.numero, p.numero, pg.total_filas
    ORDER BY f.fecha DESC, f.numero DESC, f.id DESC
  ) t;
$$;

-- 20261009130000
CREATE OR REPLACE FUNCTION remitos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_estado text DEFAULT NULL,
  p_cliente_id integer DEFAULT NULL, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT r.id, count(*) OVER () AS total_filas
    FROM remitos r
    JOIN clientes c ON c.id = r.cliente_id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_estado IS NULL OR r.estado = p_estado)
      AND (p_cliente_id IS NULL OR r.cliente_id = p_cliente_id)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
  SELECT to_jsonb(t) FROM (
    SELECT r.*,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase, c.direccion, c.email, c.telefono,
      f.numero AS factura_numero,
      json_agg(json_build_object(
        'id', ri.id, 'producto_id', ri.producto_id, 'codigo', pr.codigo, 'descripcion', ri.descripcion,
        'cantidad', ri.cantidad, 'precio_unitario', ri.precio_unitario,
        'descuento_item', ri.descuento_item, 'subtotal', ri.subtotal, 'orden', ri.orden,
        'alicuota_iva_id', ri.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', ri.pallets, 'unidades_por_pallet', ri.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
      ) ORDER BY ri.orden) FILTER (WHERE ri.id IS NOT NULL) AS items,
      pg.total_filas
    FROM pagina pg
    JOIN remitos r ON r.id = pg.id
    JOIN clientes c ON c.id = r.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN facturas f ON f.id = r.factura_id
    LEFT JOIN remito_items ri ON ri.remito_id = r.id
    LEFT JOIN productos pr ON pr.id = ri.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = ri.alicuota_iva_id
    GROUP BY r.id, c.id, ci.id, f.numero, pg.total_filas
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
  ) t;
$$;

-- 20261009130001
CREATE OR REPLACE FUNCTION recibos_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL, p_cliente_id integer DEFAULT NULL,
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL, p_limit integer DEFAULT NULL, p_offset integer DEFAULT 0
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH pagina AS (
    SELECT r.id, count(*) OVER () AS total_filas, sum(r.total) OVER () AS total_importe
    FROM recibos r
    JOIN clientes c ON c.id = r.cliente_id
    WHERE (p_id IS NULL OR r.id = p_id)
      AND (p_cliente_id IS NULL OR r.cliente_id = p_cliente_id)
      AND (p_desde IS NULL OR r.fecha >= p_desde)
      AND (p_hasta IS NULL OR r.fecha <= p_hasta)
      AND (p_q IS NULL OR r.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
    LIMIT p_limit OFFSET COALESCE(p_offset, 0)
  )
  SELECT to_jsonb(t) FROM (
    SELECT r.*,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase,
      COALESCE(
        json_agg(DISTINCT jsonb_build_object('factura_id', rf.factura_id, 'numero', f.numero))
          FILTER (WHERE rf.id IS NOT NULL), '[]'
      ) AS facturas,
      COALESCE(
        json_agg(DISTINCT jsonb_build_object(
          'id', rm.id, 'tipo', rm.tipo, 'detalle', rm.detalle,
          'numero_cheque', rm.numero_cheque, 'banco', rm.banco, 'titular', rm.titular,
          'cuit_titular', rm.cuit_titular, 'fecha_emision', rm.fecha_emision,
          'fecha_vcto', rm.fecha_vcto, 'monto', rm.monto
        )) FILTER (WHERE rm.id IS NOT NULL), '[]'
      ) AS medios,
      pg.total_filas, pg.total_importe
    FROM pagina pg
    JOIN recibos r ON r.id = pg.id
    JOIN clientes c ON c.id = r.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN recibo_facturas rf ON rf.recibo_id = r.id
    LEFT JOIN facturas f ON f.id = rf.factura_id
    LEFT JOIN recibo_medios rm ON rm.recibo_id = r.id
    GROUP BY r.id, c.id, ci.id, pg.total_filas, pg.total_importe
    ORDER BY r.fecha DESC, r.numero DESC, r.id DESC
  ) t;
$$;

-- 20260819120003
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
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase, c.direccion, c.email, c.telefono,
      json_agg(json_build_object(
        'id', pi.id, 'producto_id', pi.producto_id, 'codigo', pr.codigo, 'descripcion', pi.descripcion,
        'cantidad', pi.cantidad, 'precio_unitario', pi.precio_unitario,
        'descuento_item', pi.descuento_item, 'subtotal', pi.subtotal, 'orden', pi.orden,
        'alicuota_iva_id', pi.alicuota_iva_id, 'iva_porcentaje', ai.porcentaje,
        'pallets', pi.pallets, 'unidades_por_pallet', pi.unidades_por_pallet,
        'es_pallet_vacio', pr.es_pallet_vacio, 'es_transporte', pr.es_transporte
      ) ORDER BY pi.orden) FILTER (WHERE pi.id IS NOT NULL) AS items
    FROM presupuestos p
    JOIN clientes c ON c.id = p.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN presupuesto_items pi ON pi.presupuesto_id = p.id
    LEFT JOIN productos pr ON pr.id = pi.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = pi.alicuota_iva_id
    WHERE (p_id IS NULL OR p.id = p_id)
      AND (p_estado IS NULL OR p.estado = p_estado)
      AND (p_q IS NULL OR p.numero ILIKE '%'||p_q||'%' OR c.razon_social ILIKE '%'||p_q||'%')
    GROUP BY p.id, c.id, ci.id
    ORDER BY p.fecha DESC, p.numero DESC
  ) t;
END;
$$;

-- 20261006140002
CREATE OR REPLACE FUNCTION notas_list(
  p_id integer DEFAULT NULL, p_q text DEFAULT NULL,
  p_tipo text DEFAULT NULL, p_cliente_id integer DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT n.*,
      f.numero AS factura_numero, f.tipo AS factura_tipo,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      c.condicion_iva_afip_id, ci.clase, c.direccion,
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
    LEFT JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    LEFT JOIN nota_items ni ON ni.nota_id = n.id
    LEFT JOIN productos pr ON pr.id = ni.producto_id
    LEFT JOIN alicuotas_iva ai ON ai.id = ni.alicuota_iva_id
    WHERE (p_id IS NULL OR n.id = p_id)
      AND (p_tipo IS NULL OR n.tipo = p_tipo)
      AND (p_cliente_id IS NULL OR COALESCE(n.cliente_id, f.cliente_id) = p_cliente_id)
      AND (p_q IS NULL OR n.numero ILIKE '%'||p_q||'%'
                       OR c.razon_social ILIKE '%'||p_q||'%'
                       OR f.numero ILIKE '%'||p_q||'%')
    GROUP BY n.id, f.numero, f.tipo, c.id, ci.id
    ORDER BY n.fecha DESC
  ) t;
$$;

-- 20261013120000
CREATE OR REPLACE FUNCTION informe_libro_iva_ventas(p_desde date, p_hasta date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'Parámetros desde y hasta son obligatorios.';
  END IF;

  WITH libro AS (
    SELECT f.id, f.fecha, 'FAC'::text AS comprobante, f.tipo::text AS letra,
      f.punto_venta, f.numero_comp, f.numero,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion AS condicion_iva,
      f.estado = 'anulada' AS anulada,
      f.neto_gravado, f.iva_monto, COALESCE(f.percepciones_monto, 0) AS percepciones_monto, f.total
    FROM facturas f
    JOIN clientes c ON c.id = f.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    WHERE f.fecha BETWEEN p_desde AND p_hasta
    UNION ALL
    SELECT n.id, n.fecha, n.tipo::text, n.tipo_letra::text,
      n.punto_venta, n.numero_comp, n.numero,
      c.razon_social, c.doc_tipo, c.doc_nro, ci.descripcion,
      n.total = 0 AS anulada,
      s.signo * n.neto_gravado, s.signo * n.iva_monto,
      s.signo * COALESCE(n.percepciones_monto, 0), s.signo * n.total
    FROM notas n
    JOIN clientes c ON c.id = n.cliente_id
    JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
    CROSS JOIN LATERAL (SELECT CASE WHEN n.tipo = 'NC' THEN -1 ELSE 1 END AS signo) s
    WHERE n.fecha BETWEEN p_desde AND p_hasta
  )
  SELECT jsonb_build_object(
    'comprobantes', (SELECT COALESCE(jsonb_agg(to_jsonb(l)
                       ORDER BY l.fecha, l.punto_venta, l.comprobante, l.letra, l.numero_comp), '[]')
                     FROM libro l),
    -- Una fila por comprobante y letra (FAC A, FAC B, NC A, …) para el resumen del libro.
    'resumen', (SELECT COALESCE(jsonb_agg(r ORDER BY r.comprobante, r.letra), '[]') FROM (
      SELECT comprobante, letra, COUNT(*) AS cantidad,
        SUM(neto_gravado) AS neto_gravado, SUM(iva_monto) AS iva_monto,
        SUM(percepciones_monto) AS percepciones_monto, SUM(total) AS total
      FROM libro GROUP BY comprobante, letra
    ) r),
    'totales', (SELECT jsonb_build_object(
      'cantidad',           COUNT(*),
      'neto_gravado',       COALESCE(SUM(neto_gravado), 0),
      'iva_monto',          COALESCE(SUM(iva_monto), 0),
      'percepciones_monto', COALESCE(SUM(percepciones_monto), 0),
      'total',              COALESCE(SUM(total), 0))
      FROM libro)
  ) INTO v;
  RETURN v;
END;
$$;

-- 20261009120000: el cliente sale como fila completa; se le suma la descripción y la clase.
CREATE OR REPLACE FUNCTION informe_cta_cte(
  p_cliente_id integer, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_cli      jsonb;
  v_movs     jsonb;
  v_anterior numeric;
  v_saldo    numeric;
BEGIN
  SELECT to_jsonb(c) || jsonb_build_object('condicion_iva', ci.descripcion, 'clase', ci.clase)
    INTO v_cli
  FROM clientes c JOIN condiciones_iva_afip ci ON ci.id = c.condicion_iva_afip_id
  WHERE c.id = p_cliente_id;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'Cliente no encontrado';
  END IF;

  WITH movs AS (
    SELECT f.id, f.fecha, f.numero AS comprobante, 'FACTURA'::text AS tipo,
           f.total AS debe, 0::numeric AS haber
    FROM facturas f
    WHERE f.cliente_id = p_cliente_id AND f.estado <> 'anulada'
    UNION ALL
    SELECT r.id, r.fecha, r.numero, 'RECIBO', 0::numeric, r.total
    FROM recibos r
    WHERE r.cliente_id = p_cliente_id
    UNION ALL
    SELECT n.id, n.fecha, n.numero, 'NOTA CRED.', 0::numeric, n.total
    FROM notas n LEFT JOIN facturas f ON f.id = n.factura_id
    WHERE COALESCE(n.cliente_id, f.cliente_id) = p_cliente_id AND n.tipo = 'NC'
    UNION ALL
    SELECT n.id, n.fecha, n.numero, 'NOTA DEB.', n.total, 0::numeric
    FROM notas n LEFT JOIN facturas f ON f.id = n.factura_id
    WHERE COALESCE(n.cliente_id, f.cliente_id) = p_cliente_id AND n.tipo = 'ND'
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
    COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.fecha, o.comprobante, o.tipo, o.id), '[]'),
    (SELECT saldo FROM anterior),
    (SELECT saldo FROM anterior) + COALESCE(SUM(o.debe - o.haber), 0)
  INTO v_movs, v_anterior, v_saldo
  FROM ordered o;

  IF p_desde IS NOT NULL THEN
    v_movs := jsonb_build_array(jsonb_build_object(
      'id', NULL, 'fecha', p_desde, 'comprobante', '—', 'tipo', 'SALDO ANTERIOR',
      'debe', 0, 'haber', 0, 'saldo', v_anterior)) || v_movs;
  END IF;

  RETURN jsonb_build_object(
    'cliente', v_cli, 'movimientos', v_movs, 'saldo_total', v_saldo,
    'saldo_anterior', v_anterior, 'desde', p_desde, 'hasta', p_hasta);
END;
$$;
