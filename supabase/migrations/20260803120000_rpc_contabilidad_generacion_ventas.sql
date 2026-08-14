-- =============================================================
-- CRM — Fase F / WS2 / migración 0400: Ventas → Contabilidad (enganche)
-- system_plan_fase_f_integracion_ventas.md §3.
--
-- Completa la interfaz de generación de asientos por el lado de Ventas y deja el disparo
-- CABLEADO PERO APAGADO. Tres piezas:
--   1) generar_asiento_desde_nota(p_nota_id)      — la interfaz que faltaba (NC/ND). Stub que
--      lanza excepción, exactamente como los 3 de 0303: la matriz de imputación sigue bloqueada.
--   2) generar_asientos_ventas_pendientes(desde, hasta) — backfill idempotente por
--      (referencia_tipo, referencia_id): asienta lo que quedó sin asiento en un período.
--   3) El disparo automático, guardado por config_empresa('contabilidad_auto_asientos').
--      Default 'off' (lo siembra 0401) ⇒ HOY ES UN NO-OP y no cambia el comportamiento actual.
--
-- Nota de diseño — por qué trigger diferido y no una línea al final de crear_factura/crear_nota:
-- el disparo se implementa como CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED en vez de
-- reescribir el cuerpo de crear_factura/crear_nota (recreadas hace poco en
-- 20260802120001_rpc_ventas_multialicuota.sql).
--   * Aditivo de verdad: no duplica ~200 líneas de RPC que habría que mantener en sincronía.
--   * Correcto respecto de los ítems: crear_factura inserta la cabecera y DESPUÉS los ítems; un
--     AFTER INSERT normal correría con el comprobante todavía sin líneas ni totales. Diferido
--     corre al COMMIT, con el comprobante completo.
--   * Es el mismo mecanismo que ya usa trg_asiento_balanceado (0300) — patrón conocido del repo.
--   * Cubre cualquier alta, no sólo la que entra por la RPC.
-- La carga de datos de Tango no se ve afectada: el load corre con
-- session_replication_role = replica (DATA_MIGRATION.md), que desactiva los triggers.
--
-- Cuando se valide la matriz (Fase E §8 pasos 2-3): reemplazar el cuerpo de los generar_asiento_*
-- y recién ahí poner el flag en 'on'. Idempotente (CREATE OR REPLACE / DROP IF EXISTS).
-- =============================================================

-- ── 1) Interfaz que faltaba: notas de crédito / débito ────────────
CREATE OR REPLACE FUNCTION generar_asiento_desde_nota(p_nota_id integer)
RETURNS asientos_contables
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  RAISE EXCEPTION
    'Generación automática de asientos pendiente: la matriz de imputación contable (NC/ND: reversa '
    'de ventas + IVA DF) debe cargarse y validarse con el contador/Tango (Fase E §3/§8). Cargá el asiento con crear_asiento por ahora.';
END;
$$;

-- ── Helper: ¿está prendida la generación automática? ──────────────
-- Se lee de config_empresa (clave/valor). Ausente o distinto de 'on' ⇒ apagado.
CREATE OR REPLACE FUNCTION contabilidad_auto_asientos_on()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT COALESCE(
    (SELECT lower(btrim(valor)) = 'on' FROM config_empresa WHERE clave = 'contabilidad_auto_asientos'),
    FALSE);
$$;

-- ── Helper: ¿este comprobante ya tiene asiento? ───────────────────
-- La idempotencia es por (referencia_tipo, referencia_id) — mismo criterio que el ledger de
-- tesorería. Usa idx_asientos_referencia (0300). Los anulados no cuentan: se puede reasentar.
CREATE OR REPLACE FUNCTION asiento_existe_para(p_referencia_tipo text, p_referencia_id integer)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM asientos_contables
    WHERE referencia_tipo = p_referencia_tipo
      AND referencia_id   = p_referencia_id
      AND estado <> 'anulado');
$$;

-- ── 2) Backfill de un período (idempotente) ───────────────────────
-- Recorre facturas y notas del rango que todavía no tengan asiento y las asienta. Devuelve el
-- conteo por tipo. Mientras la matriz esté bloqueada, generar_asiento_desde_* lanza excepción:
-- esta función sólo será útil una vez completada (por eso no se llama desde ningún lado todavía).
CREATE OR REPLACE FUNCTION generar_asientos_ventas_pendientes(
  p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r            record;
  v_facturas   integer := 0;
  v_notas      integer := 0;
BEGIN
  FOR r IN
    SELECT f.id FROM facturas f
    WHERE f.estado <> 'anulada'
      AND (p_desde IS NULL OR f.fecha >= p_desde)
      AND (p_hasta IS NULL OR f.fecha <= p_hasta)
      AND NOT asiento_existe_para('facturas', f.id)
    ORDER BY f.fecha, f.id
  LOOP
    PERFORM generar_asiento_desde_factura(r.id);
    v_facturas := v_facturas + 1;
  END LOOP;

  -- notas no tiene columna `estado` (no se anulan en este esquema): sin filtro de estado.
  FOR r IN
    SELECT n.id FROM notas n
    WHERE (p_desde IS NULL OR n.fecha >= p_desde)
      AND (p_hasta IS NULL OR n.fecha <= p_hasta)
      AND NOT asiento_existe_para('notas', n.id)
    ORDER BY n.fecha, n.id
  LOOP
    PERFORM generar_asiento_desde_nota(r.id);
    v_notas := v_notas + 1;
  END LOOP;

  RETURN jsonb_build_object('facturas', v_facturas, 'notas', v_notas);
END;
$$;

-- ── 3) Disparo automático, apagado por defecto ────────────────────
-- Un solo trigger function para facturas y notas: TG_TABLE_NAME decide a qué generador llamar.
CREATE OR REPLACE FUNCTION trg_generar_asiento_venta()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NOT contabilidad_auto_asientos_on() THEN
    RETURN NULL;                                  -- flag 'off' ⇒ no-op (el caso de hoy)
  END IF;
  IF asiento_existe_para(TG_TABLE_NAME::text, NEW.id) THEN
    RETURN NULL;                                  -- idempotente
  END IF;

  IF TG_TABLE_NAME = 'facturas' THEN
    -- Una factura anulada no genera asiento. `notas` no tiene columna estado (no se anulan),
    -- por eso el chequeo va acá adentro y no antes del IF.
    IF NEW.estado = 'anulada' THEN
      RETURN NULL;
    END IF;
    PERFORM generar_asiento_desde_factura(NEW.id);
  ELSE
    PERFORM generar_asiento_desde_nota(NEW.id);
  END IF;
  RETURN NULL;
END;
$$;

-- DEFERRABLE INITIALLY DEFERRED: corre al COMMIT, cuando la factura/nota ya tiene sus ítems y
-- totales (crear_factura inserta cabecera y después líneas).
DROP TRIGGER IF EXISTS trg_asiento_auto_factura ON facturas;
CREATE CONSTRAINT TRIGGER trg_asiento_auto_factura
  AFTER INSERT ON facturas
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION trg_generar_asiento_venta();

DROP TRIGGER IF EXISTS trg_asiento_auto_nota ON notas;
CREATE CONSTRAINT TRIGGER trg_asiento_auto_nota
  AFTER INSERT ON notas
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION trg_generar_asiento_venta();

-- ── Permisos: sólo staff autenticado; anon denegado ──────────────
-- Regla de MIGRATION_PLAN.md: REVOKE explícito por función, helpers incluidos — ALTER DEFAULT
-- PRIVILEGES no alcanza para funciones creadas después (lección de 0004/0010).
REVOKE ALL ON FUNCTION generar_asiento_desde_nota(integer)                     FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION generar_asiento_desde_nota(integer)                   TO authenticated;
REVOKE ALL ON FUNCTION generar_asientos_ventas_pendientes(date, date)          FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION generar_asientos_ventas_pendientes(date, date)        TO authenticated;
-- Helpers internos: nadie los llama desde el cliente.
REVOKE ALL ON FUNCTION contabilidad_auto_asientos_on()                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION asiento_existe_para(text, integer)                      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION trg_generar_asiento_venta()                             FROM PUBLIC, anon, authenticated;
