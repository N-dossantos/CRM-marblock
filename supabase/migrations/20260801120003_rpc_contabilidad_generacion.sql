-- =============================================================
-- CRM — Fase E / migración 0303: RPC de generación automática de asientos  ⛔ BLOQUEADA
-- system_plan_fase_e_contabilidad.md §3/§8.
--
-- Estas funciones son la INTERFAZ (firma estable que el frontend/otras RPC pueden
-- referenciar) pero su CUERPO — el mapeo débito/crédito por tipo de operación — es la
-- "matriz de imputación" que:
--   1) depende del plan_de_cuentas real cargado desde Tango (§2.1), y
--   2) DEBE validarse con el contador/Tango, no inventarse (un asiento mal imputado es peor
--      que no tener el módulo).
--
-- Por eso acá lanzan una excepción explícita en lugar de generar un asiento incorrecto.
-- Cuando se desbloquee (§8 pasos 2-3): reemplazar el cuerpo por la construcción de p_lineas
-- según la matriz y delegar en crear_asiento(...). Mientras tanto, cargar a mano con
-- crear_asiento. Idempotente (CREATE OR REPLACE).
-- =============================================================

CREATE OR REPLACE FUNCTION generar_asiento_desde_factura(p_factura_id integer)
RETURNS asientos_contables
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  RAISE EXCEPTION
    'Generación automática de asientos pendiente: la matriz de imputación contable (venta A/B, IVA) '
    'debe cargarse y validarse con el contador/Tango (Fase E §3/§8). Cargá el asiento con crear_asiento por ahora.';
END;
$$;

CREATE OR REPLACE FUNCTION generar_asiento_desde_pago_proveedor(p_pago_id integer)
RETURNS asientos_contables
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  RAISE EXCEPTION
    'Generación automática de asientos pendiente: la matriz de imputación contable (pago, retenciones) '
    'debe cargarse y validarse con el contador/Tango (Fase E §3/§8). Cargá el asiento con crear_asiento por ahora.';
END;
$$;

CREATE OR REPLACE FUNCTION generar_asiento_desde_movimiento_tesoreria(p_mov_id integer)
RETURNS asientos_contables
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  RAISE EXCEPTION
    'Generación automática de asientos pendiente: la matriz de imputación contable (cobranza, depósito, '
    'cheque, gasto bancario) debe cargarse y validarse con el contador/Tango (Fase E §3/§8). Cargá el asiento con crear_asiento por ahora.';
END;
$$;

-- ── Permisos: sólo staff autenticado; anon denegado ──────────────
REVOKE ALL ON FUNCTION generar_asiento_desde_factura(integer)                FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION generar_asiento_desde_factura(integer)              TO authenticated;
REVOKE ALL ON FUNCTION generar_asiento_desde_pago_proveedor(integer)         FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION generar_asiento_desde_pago_proveedor(integer)       TO authenticated;
REVOKE ALL ON FUNCTION generar_asiento_desde_movimiento_tesoreria(integer)   FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION generar_asiento_desde_movimiento_tesoreria(integer) TO authenticated;
