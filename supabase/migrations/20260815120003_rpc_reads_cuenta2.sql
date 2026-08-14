-- =============================================================
-- CRM — Cuenta 2 / migración 0503: RPC de lectura + informes del circuito informal
-- Mismo criterio que 20260727120011_rpc_reads_informes.sql: SECURITY INVOKER (las lecturas
-- corren como el usuario autenticado, bajo RLS), `anon` revocado, y cada `*_list` sirve
-- también de get-by-id vía el argumento opcional p_id.
--
-- informe_cta_cte_cuenta2 es el espejo exacto de informe_cta_cte: NO hay tabla de saldos,
-- el saldo sale de SUM(debe-haber) OVER (...) sobre el UNION de remitos + movimientos.
-- Devuelve las filas con la forma {fecha, comprobante, tipo, debe, haber, saldo} que la
-- vista de cuenta corriente ya sabe renderizar.
-- Idempotente (CREATE OR REPLACE).
-- =============================================================

-- ──────────────────────────────────────────────────────────────
-- ENTIDADES (list/get) — con el saldo de cta. cte. resuelto para el picker.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION clientes_cuenta2_list(
  p_q text DEFAULT NULL, p_activo boolean DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT c.*,
      COALESCE((SELECT SUM(r.total) FROM cuenta2_remitos r WHERE r.cliente_id = c.id), 0)
      + COALESCE((SELECT SUM(m.debe - m.haber) FROM cuenta2_movimientos m WHERE m.cliente_id = c.id), 0)
        AS saldo,
      COALESCE((SELECT SUM(r.total) FROM cuenta2_remitos r WHERE r.cliente_id = c.id), 0)
        AS total_remitado
    FROM clientes_cuenta2 c
    WHERE (p_q IS NULL OR c.nombre ILIKE '%'||p_q||'%' OR c.telefono ILIKE '%'||p_q||'%')
      AND (p_activo IS NULL OR c.activo = p_activo)
    ORDER BY c.nombre
  ) t;
$$;

CREATE OR REPLACE FUNCTION proveedores_cuenta2_list(
  p_q text DEFAULT NULL, p_activo boolean DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT p.*,
      COALESCE((SELECT SUM(r.total) FROM cuenta2_remitos r WHERE r.proveedor_id = p.id), 0)
      + COALESCE((SELECT SUM(m.debe - m.haber) FROM cuenta2_movimientos m WHERE m.proveedor_id = p.id), 0)
        AS saldo,
      COALESCE((SELECT SUM(r.total) FROM cuenta2_remitos r WHERE r.proveedor_id = p.id), 0)
        AS total_remitado
    FROM proveedores_cuenta2 p
    WHERE (p_q IS NULL OR p.nombre ILIKE '%'||p_q||'%' OR p.telefono ILIKE '%'||p_q||'%')
      AND (p_activo IS NULL OR p.activo = p_activo)
    ORDER BY p.nombre
  ) t;
$$;

-- ──────────────────────────────────────────────────────────────
-- REMITOS X (list/get) — ítems agregados, con el código de producto para la tabla.
-- ──────────────────────────────────────────────────────────────
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
        'subtotal', ri.subtotal, 'orden', ri.orden
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

-- ──────────────────────────────────────────────────────────────
-- MOVIMIENTOS (cobros / pagos / ajustes) — list plana con datos del cheque asociado.
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION movimientos_cuenta2_list(
  p_tipo_sector text    DEFAULT NULL,
  p_entidad_id  integer DEFAULT NULL,
  p_desde       date    DEFAULT NULL,
  p_hasta       date    DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT m.*,
      COALESCE(cl.nombre, pv.nombre) AS entidad_nombre,
      COALESCE(m.cliente_id, m.proveedor_id) AS entidad_id,
      ch.numero AS cheque_numero,
      ch.banco  AS cheque_banco,
      ch.estado AS cheque_estado
    FROM cuenta2_movimientos m
    LEFT JOIN clientes_cuenta2    cl ON cl.id = m.cliente_id
    LEFT JOIN proveedores_cuenta2 pv ON pv.id = m.proveedor_id
    LEFT JOIN cuenta2_cheques     ch ON ch.id = m.cheque_id
    WHERE (p_tipo_sector IS NULL OR m.tipo_sector = p_tipo_sector)
      AND (p_entidad_id IS NULL OR m.cliente_id = p_entidad_id OR m.proveedor_id = p_entidad_id)
      AND (p_desde IS NULL OR m.fecha >= p_desde)
      AND (p_hasta IS NULL OR m.fecha <= p_hasta)
    ORDER BY m.fecha DESC, m.id DESC
  ) t;
$$;

-- ──────────────────────────────────────────────────────────────
-- INFORME CTA. CTE. CUENTA 2  (§1.7) — espejo de informe_cta_cte.
--   Saldo calculado al leer; positivo = "debe" (ventas) / "le debemos" (compras).
-- ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION informe_cta_cte_cuenta2(
  p_tipo_sector text,
  p_entidad_id  integer,
  p_desde       date DEFAULT NULL,
  p_hasta       date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_ent   jsonb;
  v_movs  jsonb;
  v_saldo numeric;
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
      AND (p_desde IS NULL OR p_hasta IS NULL OR r.fecha BETWEEN p_desde AND p_hasta)
    UNION ALL
    SELECT m.id, m.fecha, m.concepto, m.tipo, m.debe, m.haber
    FROM cuenta2_movimientos m
    WHERE m.tipo_sector = p_tipo_sector
      AND (m.cliente_id = p_entidad_id OR m.proveedor_id = p_entidad_id)
      AND (p_desde IS NULL OR p_hasta IS NULL OR m.fecha BETWEEN p_desde AND p_hasta)
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

  RETURN jsonb_build_object('entidad', v_ent, 'movimientos', v_movs, 'saldo_total', v_saldo);
END;
$$;

-- ── Permisos: sólo staff autenticado; anon denegado ──────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'clientes_cuenta2_list','proveedores_cuenta2_list','remitos_cuenta2_list',
      'movimientos_cuenta2_list','informe_cta_cte_cuenta2'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon;', r.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated;', r.sig);
  END LOOP;
END $$;
