-- =============================================================
-- CRM — Fase A / migración 0105: RPC proveedores_list  §4.13/§4.14
-- Espeja clientes_list (0011): lista + saldo, buscando por razón social OR CUIT.
-- El resto de proveedores (get/create/update) es ABM simple vía PostgREST, como clientes.
-- Materiales es ABM simple vía PostgREST (como productos) — sin RPC.
-- SECURITY INVOKER (lectura bajo RLS del caller). anon revocado.
-- =============================================================

CREATE OR REPLACE FUNCTION proveedores_list(
  p_q text DEFAULT NULL, p_activo boolean DEFAULT NULL
)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT to_jsonb(t) FROM (
    SELECT p.*,
      COALESCE(SUM(fc.total) FILTER (WHERE fc.estado <> 'anulada'), 0)               AS total_comprado,
      COALESCE(SUM(fc.total) FILTER (WHERE fc.estado IN ('pendiente','parcial')), 0) AS saldo_pendiente
    FROM proveedores p
    LEFT JOIN facturas_compra fc ON fc.proveedor_id = p.id
    WHERE (p_q IS NULL OR p.razon_social ILIKE '%'||p_q||'%' OR p.cuit ILIKE '%'||p_q||'%')
      AND (p_activo IS NULL OR p.activo = p_activo)
    GROUP BY p.id
    ORDER BY p.razon_social
  ) t;
$$;

REVOKE ALL ON FUNCTION proveedores_list(text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION proveedores_list(text, boolean) TO authenticated;
