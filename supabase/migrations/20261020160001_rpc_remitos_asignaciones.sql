-- =============================================================
-- CRM Ventas — remitos contra facturas pendientes de remitir (PLAN_MAESTRO §3.11), 2 de 4:
-- remitos que descuentan de facturas (crear, editar, anular).
--
-- Cada elemento de p_items de crear_remito y actualizar_remito puede traer, además de sus claves
-- de siempre, "asignaciones": [{"factura_id": int, "cantidad": numeric}], lo que carga "Lleva" en
-- "Facturas pendientes de remitir". Las firmas no cambian.
--
-- 1) crm_remito_bloqueado: el remito se usó para armar una factura (asignaciones 'factura' o
--    'tango' a facturas no anuladas). No se edita ni se anula. remitos_list lo va a mostrar.
-- 2) crm_remito_asignar: valida las asignaciones contra lo pendiente de cada factura, con las
--    facturas bloqueadas, las graba con origen 'remito' y recalcula el estado del remito.
-- 3) crear_remito y actualizar_remito graban las asignaciones. Un remito facturado sólo con
--    asignaciones 'remito' se puede editar y anular: lo pendiente vuelve a sus facturas.
-- 4) remito_anular borra las asignaciones 'remito' del remito.
--
-- Sin BEGIN/COMMIT: se ensaya dentro de una transacción (supabase/remitos/ensayo.sql).
-- =============================================================

-- ── 1) crm_remito_bloqueado ──────────────────────────────────────
-- Lectura: corre como el que llama, con las policies de siempre. Una asignación 'factura' a un
-- borrador también bloquea: los renglones ya se copiaron a la factura.
CREATE FUNCTION crm_remito_bloqueado(p_remito_id integer)
RETURNS boolean
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1
    FROM remito_items ri
    JOIN remito_item_facturas a ON a.remito_item_id = ri.id
    JOIN facturas f ON f.id = a.factura_id
    WHERE ri.remito_id = p_remito_id
      AND a.origen IN ('factura','tango')
      AND f.estado <> 'anulada');
$$;

-- ── 2) crm_remito_asignar ────────────────────────────────────────
-- Graba las asignaciones de p_items en los renglones del remito, que ya están insertados: el
-- elemento n de p_items es el renglón con orden n − 1 (crm_insert_remito_items). Las asignaciones
-- con cantidad NULL o 0 no cuentan. Rechaza, en este orden:
--   E1 factura de otro cliente; E2 factura no emitida (ni histórica ni con CAE);
--   E4 un renglón que asigna más de lo que lleva;
--   E3 más que lo pendiente de la factura en ese producto, sumando los renglones del remito que
--      tienen la misma clave. Un producto que la factura no tiene pendiente cuenta como "quedan 0".
-- El servidor nunca asigna más que lo pendiente: lo que se lleva de más va sin asignar y queda
-- pendiente de facturar.
CREATE FUNCTION crm_remito_asignar(p_remito_id integer, p_cliente_id integer, p_items jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_ri   integer[];  -- por asignación: el renglón del remito,
  v_fac  integer[];  -- la factura
  v_cant numeric[];  -- y la cantidad
  v_num  text;
  v_e    record;
BEGIN
  SELECT array_agg(ri.id                                    ORDER BY e.n, a.m),
         array_agg((a.asig->>'factura_id')::integer          ORDER BY e.n, a.m),
         array_agg(NULLIF(a.asig->>'cantidad', '')::numeric  ORDER BY e.n, a.m)
    INTO v_ri, v_fac, v_cant
  FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(item, n)
  CROSS JOIN LATERAL jsonb_array_elements(
      CASE WHEN jsonb_typeof(e.item->'asignaciones') = 'array' THEN e.item->'asignaciones' ELSE '[]' END
    ) WITH ORDINALITY AS a(asig, m)
  JOIN remito_items ri ON ri.remito_id = p_remito_id AND ri.orden = e.n - 1
  WHERE COALESCE(NULLIF(a.asig->>'cantidad', '')::numeric, 0) <> 0;

  IF v_ri IS NOT NULL THEN
    -- Bloquea las facturas, siempre en el mismo orden (dos remitos a la vez no se trancan). Va en
    -- su propia sentencia, antes de leer lo pendiente: en READ COMMITTED cada sentencia toma su
    -- foto, así que la lectura de abajo ya ve lo que grabó el remito que tenía el lock.
    PERFORM 1 FROM facturas WHERE id = ANY(v_fac) ORDER BY id FOR UPDATE;

    SELECT COALESCE(f.numero, '#' || a.factura_id) INTO v_num
    FROM unnest(v_fac) AS a(factura_id)
    LEFT JOIN facturas f ON f.id = a.factura_id
    WHERE f.cliente_id IS DISTINCT FROM p_cliente_id
    LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'La factura % no es de este cliente.', v_num;
    END IF;

    SELECT COALESCE(f.numero, '#' || f.id) INTO v_num
    FROM facturas f
    WHERE f.id = ANY(v_fac) AND f.estado_fiscal NOT IN ('historico','autorizado')
    ORDER BY f.id
    LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'La factura % no está emitida: sólo se remite contra facturas con CAE o históricas.', v_num;
    END IF;

    SELECT ri.descripcion, sum(a.cantidad) AS asignado, ri.cantidad INTO v_e
    FROM unnest(v_ri, v_cant) AS a(remito_item_id, cantidad)
    JOIN remito_items ri ON ri.id = a.remito_item_id
    GROUP BY ri.id
    HAVING sum(a.cantidad) > ri.cantidad
    ORDER BY ri.orden
    LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El renglón "%" asigna % a facturas pero lleva %.',
        v_e.descripcion, trim_scale(v_e.asignado), trim_scale(v_e.cantidad);
    END IF;

    -- Por (factura, clave); la descripción del mensaje es la del primer renglón con esa clave.
    SELECT COALESCE(f.numero, '#' || f.id) AS numero, s.descripcion,
           COALESCE(p.pendiente, 0) AS quedan, s.cantidad INTO v_e
    FROM (
      SELECT a.factura_id, crm_clave_item(ri.producto_id, ri.descripcion) AS clave,
             (array_agg(ri.descripcion ORDER BY ri.orden))[1] AS descripcion,
             sum(a.cantidad) AS cantidad
      FROM unnest(v_ri, v_fac, v_cant) AS a(remito_item_id, factura_id, cantidad)
      JOIN remito_items ri ON ri.id = a.remito_item_id
      GROUP BY 1, 2
    ) s
    JOIN facturas f ON f.id = s.factura_id
    LEFT JOIN crm_facturas_pendientes(p_cliente_id) p ON p.factura_id = s.factura_id AND p.clave = s.clave
    WHERE s.cantidad > COALESCE(p.pendiente, 0)
    ORDER BY f.id, s.clave
    LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'La factura % ya no tiene pendiente suficiente de "%": quedan %, se quieren remitir %. Volvé a abrir el remito para ver lo pendiente actualizado.',
        v_e.numero, v_e.descripcion, trim_scale(v_e.quedan), trim_scale(v_e.cantidad);
    END IF;

    INSERT INTO remito_item_facturas (remito_item_id, factura_id, cantidad, origen)
    SELECT a.remito_item_id, a.factura_id, a.cantidad, 'remito'
    FROM unnest(v_ri, v_fac, v_cant) WITH ORDINALITY AS a(remito_item_id, factura_id, cantidad, n)
    ORDER BY a.n;
  END IF;

  PERFORM crm_remito_recalcular(p_remito_id);
END;
$$;

-- ── 3) crear_remito ──────────────────────────────────────────────
-- Misma firma y cuerpo que 20260820120002, más las asignaciones.
CREATE OR REPLACE FUNCTION crear_remito(
  p_cliente_id        integer,
  p_numero            varchar,
  p_items             jsonb,
  p_observaciones     text    DEFAULT NULL,
  p_presupuesto_id    integer DEFAULT NULL,
  p_condiciones_venta varchar DEFAULT NULL,
  p_domicilio_obra    varchar DEFAULT NULL,
  p_telefono_entrega  varchar DEFAULT NULL
)
RETURNS remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_numero varchar;
  v_pv     CHAR(5);
  v_comp   INTEGER;
  v_rem    remitos;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  v_numero := NULLIF(trim(p_numero), '');
  IF v_numero IS NULL THEN
    RAISE EXCEPTION 'El número del remito es obligatorio.';
  END IF;
  IF v_numero !~ '^\d{5}-\d{8}$' THEN
    RAISE EXCEPTION 'El número % no tiene el formato PPPPP-NNNNNNNN (ej. 00002-00000123).', v_numero;
  END IF;

  v_pv   := split_part(v_numero, '-', 1);
  v_comp := split_part(v_numero, '-', 2)::INTEGER;

  BEGIN
    INSERT INTO remitos
      (numero, punto_venta, numero_comp, fecha, cliente_id, presupuesto_id, estado, observaciones,
       condiciones_venta, domicilio_obra, telefono_entrega)
    VALUES
      (v_numero, v_pv, v_comp, CURRENT_DATE,
       p_cliente_id, p_presupuesto_id, 'pendiente', p_observaciones,
       NULLIF(trim(p_condiciones_venta), ''), NULLIF(trim(p_domicilio_obra), ''),
       NULLIF(trim(p_telefono_entrega), ''))
    RETURNING * INTO v_rem;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'El remito % ya fue emitido.', v_numero;
  END;

  PERFORM crm_insert_remito_items(v_rem.id, p_items);
  PERFORM crm_remito_asignar(v_rem.id, p_cliente_id, p_items);

  IF p_presupuesto_id IS NOT NULL THEN
    UPDATE presupuestos SET estado = 'convertido', updated_at = NOW() WHERE id = p_presupuesto_id;
  END IF;

  UPDATE contadores
     SET ultimo_numero = v_comp,
         punto_venta   = v_pv
   WHERE tipo = 'remito'
     AND (punto_venta <> v_pv OR ultimo_numero < v_comp);

  RETURN v_rem;
END;
$$;

-- ── actualizar_remito ────────────────────────────────────────────
-- Misma firma y cuerpo que 20261015130000. Ya no exige estado 'pendiente' ni factura_id NULL: se
-- rechaza si está anulado (E7) o bloqueado (E5). Sus asignaciones 'remito' se van con los
-- renglones (CASCADE) y se vuelven a grabar con los nuevos. FOR UPDATE: el remito no cambia de
-- estado entre los chequeos y el final de la transacción.
CREATE OR REPLACE FUNCTION actualizar_remito(
  p_id                integer,
  p_cliente_id        integer,
  p_items             jsonb,
  p_observaciones     text    DEFAULT NULL,
  p_condiciones_venta varchar DEFAULT NULL,
  p_domicilio_obra    varchar DEFAULT NULL,
  p_telefono_entrega  varchar DEFAULT NULL
)
RETURNS remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cur remitos;
  v_rem remitos;
BEGIN
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'El cliente es obligatorio.';
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Debe incluir al menos un ítem.';
  END IF;

  SELECT * INTO v_cur FROM remitos WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Remito no encontrado';
  END IF;
  IF v_cur.estado = 'anulado' THEN
    RAISE EXCEPTION 'No se puede editar un remito anulado.';
  END IF;
  IF crm_remito_bloqueado(p_id) THEN
    RAISE EXCEPTION 'El remito % se usó para armar una factura: no se puede editar.', v_cur.numero;
  END IF;

  UPDATE remitos SET
    cliente_id        = p_cliente_id,
    observaciones     = p_observaciones,
    condiciones_venta = NULLIF(trim(p_condiciones_venta), ''),
    domicilio_obra    = NULLIF(trim(p_domicilio_obra), ''),
    telefono_entrega  = NULLIF(trim(p_telefono_entrega), ''),
    updated_at        = NOW()
  WHERE id = p_id
  RETURNING * INTO v_rem;

  DELETE FROM remito_items WHERE remito_id = p_id;
  PERFORM crm_insert_remito_items(p_id, p_items);
  PERFORM crm_remito_asignar(p_id, p_cliente_id, p_items);
  RETURN v_rem;
END;
$$;

-- ── 4) remito_anular ─────────────────────────────────────────────
-- Misma firma que 20261015130000. Se anula aunque esté facturado, si lo facturado son sólo sus
-- asignaciones 'remito': se borran y lo pendiente vuelve a sus facturas. Bloqueado: E5.
CREATE OR REPLACE FUNCTION remito_anular(p_id integer)
RETURNS remitos
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_rem remitos;
BEGIN
  SELECT * INTO v_rem FROM remitos WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR v_rem.estado = 'anulado' THEN
    RAISE EXCEPTION 'Remito no encontrado o ya anulado.';
  END IF;
  IF crm_remito_bloqueado(p_id) THEN
    RAISE EXCEPTION 'El remito % se usó para armar una factura: no se puede anular.', v_rem.numero;
  END IF;

  DELETE FROM remito_item_facturas a
  USING remito_items ri
  WHERE ri.id = a.remito_item_id AND ri.remito_id = p_id AND a.origen = 'remito';

  UPDATE remitos SET estado = 'anulado', factura_id = NULL, updated_at = NOW()
  WHERE id = p_id
  RETURNING * INTO v_rem;
  RETURN v_rem;
END;
$$;

-- ── Permisos ─────────────────────────────────────────────────────
-- REVOKE explícito en las nuevas: los DEFAULT PRIVILEGES de Supabase le dan EXECUTE a anon y
-- authenticated a toda función nueva. crm_remito_bloqueado es de lectura y authenticated tiene que
-- poder llamarla (remitos_list); crm_remito_asignar escribe: sólo desde las RPC de remitos.
REVOKE ALL ON FUNCTION crm_remito_bloqueado(integer)                 FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_remito_bloqueado(integer)              TO authenticated;
REVOKE ALL ON FUNCTION crm_remito_asignar(integer, integer, jsonb)   FROM PUBLIC, anon, authenticated;

-- Las reemplazadas conservan sus grants; se reafirman por la convención del proyecto.
REVOKE ALL ON FUNCTION crear_remito(integer, varchar, jsonb, text, integer, varchar, varchar, varchar) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION actualizar_remito(integer, integer, jsonb, text, varchar, varchar, varchar)     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION remito_anular(integer)                                                          FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION crear_remito(integer, varchar, jsonb, text, integer, varchar, varchar, varchar) TO authenticated;
GRANT EXECUTE ON FUNCTION actualizar_remito(integer, integer, jsonb, text, varchar, varchar, varchar)     TO authenticated;
GRANT EXECUTE ON FUNCTION remito_anular(integer)                                                          TO authenticated;
