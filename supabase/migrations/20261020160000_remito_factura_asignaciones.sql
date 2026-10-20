-- =============================================================
-- CRM Ventas — remitos contra facturas pendientes de remitir (PLAN_MAESTRO §3.11), 1 de 4:
-- asignaciones remito–factura y cálculo de lo pendiente.
--
-- 1) remito_item_facturas: "tantas unidades de este renglón del remito salen de esta factura". Un
--    remito puede descontar de varias facturas, y una factura se entrega en varios remitos.
-- 2) Backfill: cada remito no anulado con factura_id recibe una asignación 'tango' por renglón,
--    por la cantidad completa. Así lo pendiente queda igual que hoy. No toca remitos.estado ni
--    remitos.factura_id, que se conserva como denormalización (la primera factura asignada).
-- 3) Lecturas: la clave de emparejamiento de un renglón, lo pendiente de remitir por factura y
--    producto, lo que le falta facturar a cada renglón de un remito, y la RPC
--    facturas_pendientes_remitir para "Nuevo remito".
-- 4) crm_remito_recalcular: factura_id y estado de un remito a partir de sus asignaciones. Lo
--    llaman las RPC de escritura de las migraciones siguientes.
--
-- Sin BEGIN/COMMIT: se ensaya dentro de una transacción (supabase/remitos/ensayo.sql).
-- =============================================================

-- ── 1) Tabla ─────────────────────────────────────────────────────
-- El producto es el del renglón del remito. factura_id sin CASCADE: una factura con asignaciones
-- no se borra sin liberarlas antes (descartar el borrador lo hace explícitamente).
CREATE TABLE remito_item_facturas (
  id             SERIAL       PRIMARY KEY,
  remito_item_id INTEGER      NOT NULL REFERENCES remito_items(id) ON DELETE CASCADE,
  factura_id     INTEGER      NOT NULL REFERENCES facturas(id),
  cantidad       NUMERIC      NOT NULL CONSTRAINT chk_rif_cantidad CHECK (cantidad > 0),
  origen         VARCHAR(10)  NOT NULL CONSTRAINT chk_rif_origen CHECK (origen IN ('remito','factura','tango')),
  created_at     TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_remito_item_facturas_factura ON remito_item_facturas(factura_id);
CREATE INDEX idx_remito_item_facturas_item    ON remito_item_facturas(remito_item_id);

COMMENT ON TABLE remito_item_facturas IS
  'Cuánto de cada renglón de remito sale de cada factura (PLAN_MAESTRO §3.11).';
COMMENT ON COLUMN remito_item_facturas.origen IS
  'Dueño de la asignación: remito (la creó el remito con "Lleva"; se edita o anula con él), '
  'factura (la creó una factura armada desde el remito) o tango (backfill; igual que factura).';

-- ── RLS y permisos ───────────────────────────────────────────────
-- Modelo "shared staff" de 20260727120002: authenticated CRUD completo, anon denegado (grant
-- revocado y sin policy). SIN FORCE: las RPC SECURITY DEFINER corren como owner y FORCE
-- bloquearía sus escrituras.
ALTER TABLE remito_item_facturas ENABLE ROW LEVEL SECURITY;
CREATE POLICY staff_all ON remito_item_facturas FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON remito_item_facturas             TO authenticated;
GRANT USAGE, SELECT                 ON SEQUENCE remito_item_facturas_id_seq TO authenticated;
REVOKE ALL ON remito_item_facturas                    FROM anon;
REVOKE ALL ON SEQUENCE remito_item_facturas_id_seq    FROM anon;

-- ── 2) Backfill ──────────────────────────────────────────────────
-- Antes del trigger de auditoría, para no llenar audit_log con una fila por renglón histórico.
INSERT INTO remito_item_facturas (remito_item_id, factura_id, cantidad, origen)
SELECT ri.id, r.factura_id, ri.cantidad, 'tango'
FROM remitos r
JOIN remito_items ri ON ri.remito_id = r.id
WHERE r.factura_id IS NOT NULL AND r.estado <> 'anulado' AND ri.cantidad > 0
ORDER BY ri.id;

CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON remito_item_facturas
  FOR EACH ROW EXECUTE FUNCTION audit_trigger();

-- ── 3) Lecturas ──────────────────────────────────────────────────
-- Corren como el que llama (sin SECURITY DEFINER), con las policies de siempre.

-- Clave de emparejamiento de un renglón entre factura, NC y remito: el producto; sin producto
-- (artículos de Tango que el CRM no tiene), la descripción sin espacios en los bordes y en
-- minúsculas. claveItem (frontend) tiene que dar exactamente lo mismo.
CREATE FUNCTION crm_clave_item(p_producto_id integer, p_descripcion text)
RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = public, pg_temp AS $$
  SELECT CASE WHEN p_producto_id IS NOT NULL THEN 'p' || p_producto_id
              ELSE 'd' || lower(btrim(p_descripcion)) END;
$$;

-- Lo pendiente de remitir por (factura, clave), sólo lo que es > 0 (§3.11, "Regla de cálculo"):
--   pendiente = facturado − asignado a remitos no anulados − acreditado por NC.
-- Entran las facturas no anuladas, históricas o con CAE (los borradores no). Las NC restan sólo
-- con sus renglones con producto; las NC sin producto y las ND no tocan lo pendiente.
-- p_cliente_id NULL: todos los clientes. p_excluir_remito_id: no cuenta las asignaciones 'remito'
-- de ese remito, para editarlo viendo lo que tenía disponible.
CREATE FUNCTION crm_facturas_pendientes(p_cliente_id integer, p_excluir_remito_id integer DEFAULT NULL)
RETURNS TABLE (factura_id integer, clave text, producto_id integer, descripcion text,
               facturado numeric, remitido numeric, acreditado numeric, pendiente numeric)
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH fac AS (
    SELECT f.id
    FROM facturas f
    WHERE f.estado <> 'anulada'
      AND f.estado_fiscal IN ('historico','autorizado')
      AND (p_cliente_id IS NULL OR f.cliente_id = p_cliente_id)
  ),
  -- El mismo producto en dos renglones es una sola fila; la descripción es la del primero.
  facturado AS (
    SELECT fi.factura_id, crm_clave_item(fi.producto_id, fi.descripcion) AS clave,
           min(fi.producto_id) AS producto_id,
           (array_agg(fi.descripcion ORDER BY fi.orden, fi.id))[1] AS descripcion,
           sum(fi.cantidad) AS cantidad
    FROM factura_items fi
    JOIN fac ON fac.id = fi.factura_id
    GROUP BY 1, 2
  ),
  remitido AS (
    SELECT a.factura_id, crm_clave_item(ri.producto_id, ri.descripcion) AS clave, sum(a.cantidad) AS cantidad
    FROM remito_item_facturas a
    JOIN fac ON fac.id = a.factura_id
    JOIN remito_items ri ON ri.id = a.remito_item_id
    JOIN remitos r ON r.id = ri.remito_id
    WHERE r.estado <> 'anulado'
      AND (p_excluir_remito_id IS NULL OR r.id <> p_excluir_remito_id OR a.origen <> 'remito')
    GROUP BY 1, 2
  ),
  acreditado AS (
    SELECT n.factura_id, crm_clave_item(ni.producto_id, ni.descripcion) AS clave, sum(ni.cantidad) AS cantidad
    FROM notas n
    JOIN fac ON fac.id = n.factura_id
    JOIN nota_items ni ON ni.nota_id = n.id
    WHERE n.tipo = 'NC'
      AND n.estado_fiscal IN ('historico','autorizado')
      AND ni.producto_id IS NOT NULL
    GROUP BY 1, 2
  )
  SELECT * FROM (
    SELECT fa.factura_id, fa.clave, fa.producto_id, fa.descripcion::text,
           fa.cantidad, COALESCE(re.cantidad, 0), COALESCE(ac.cantidad, 0),
           fa.cantidad - COALESCE(re.cantidad, 0) - COALESCE(ac.cantidad, 0)
    FROM facturado fa
    LEFT JOIN remitido   re ON re.factura_id = fa.factura_id AND re.clave = fa.clave
    LEFT JOIN acreditado ac ON ac.factura_id = fa.factura_id AND ac.clave = fa.clave
  ) t (factura_id, clave, producto_id, descripcion, facturado, remitido, acreditado, pendiente)
  WHERE t.pendiente > 0;
$$;

-- Lo que le falta facturar a cada renglón de un remito: cantidad − asignado a facturas no
-- anuladas. Lo asignado a un borrador cuenta: queda reservado hasta emitirlo o descartarlo.
CREATE FUNCTION crm_remito_items_sin_facturar(p_remito_id integer)
RETURNS TABLE (remito_item_id integer, clave text, cantidad numeric, asignado numeric, sin_facturar numeric)
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT ri.id, crm_clave_item(ri.producto_id, ri.descripcion), ri.cantidad,
         COALESCE(a.asignado, 0), ri.cantidad - COALESCE(a.asignado, 0)
  FROM remito_items ri
  LEFT JOIN LATERAL (
    SELECT sum(x.cantidad) AS asignado
    FROM remito_item_facturas x
    JOIN facturas f ON f.id = x.factura_id
    WHERE x.remito_item_id = ri.id AND f.estado <> 'anulada'
  ) a ON true
  WHERE ri.remito_id = p_remito_id
  ORDER BY ri.orden, ri.id;
$$;

-- "Facturas pendientes de remitir" de un cliente, de la más vieja a la más nueva: una fila por
-- factura con sus productos pendientes. unidades_por_pallet y las marcas salen del catálogo (los
-- renglones de Tango traen 1 y pallets NULL); sin producto, 1 y false.
CREATE FUNCTION facturas_pendientes_remitir(p_cliente_id integer, p_excluir_remito_id integer DEFAULT NULL)
RETURNS SETOF jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  WITH p AS (
    SELECT * FROM crm_facturas_pendientes(p_cliente_id, p_excluir_remito_id)
  ),
  -- Los productos en el orden de los renglones de la factura.
  pos AS (
    SELECT fi.factura_id, crm_clave_item(fi.producto_id, fi.descripcion) AS clave,
           min(fi.orden) AS orden, min(fi.id) AS id
    FROM factura_items fi
    WHERE fi.factura_id IN (SELECT factura_id FROM p)
    GROUP BY 1, 2
  )
  SELECT jsonb_build_object(
    'id', f.id, 'numero', f.numero, 'tipo', f.tipo, 'fecha', f.fecha,
    'items', jsonb_agg(jsonb_build_object(
      'clave', p.clave, 'producto_id', p.producto_id, 'descripcion', p.descripcion,
      'facturado', p.facturado, 'remitido', p.remitido, 'acreditado', p.acreditado,
      'pendiente', p.pendiente,
      'unidades_por_pallet', COALESCE(pr.unidades_por_pallet, 1),
      'es_pallet_vacio', COALESCE(pr.es_pallet_vacio, false),
      'es_transporte', COALESCE(pr.es_transporte, false)
    ) ORDER BY o.orden, o.id))
  FROM p
  JOIN facturas f ON f.id = p.factura_id
  JOIN pos o ON o.factura_id = p.factura_id AND o.clave = p.clave
  LEFT JOIN productos pr ON pr.id = p.producto_id
  GROUP BY f.id
  ORDER BY f.fecha, f.id;
$$;

-- ── 4) crm_remito_recalcular ─────────────────────────────────────
-- factura_id = la factura de la primera asignación (por id), o NULL. estado = 'facturado' si cada
-- renglón está asignado, por toda su cantidad, a facturas no anuladas históricas o con CAE; si
-- no, 'pendiente' (le queda algo sin facturar o reservado por un borrador). Un remito anulado no
-- se toca.
CREATE FUNCTION crm_remito_recalcular(p_remito_id integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  UPDATE remitos r SET
    factura_id = (
      SELECT a.factura_id
      FROM remito_item_facturas a
      JOIN remito_items ri ON ri.id = a.remito_item_id
      WHERE ri.remito_id = r.id
      ORDER BY a.id
      LIMIT 1),
    estado = CASE WHEN NOT EXISTS (
        SELECT 1 FROM remito_items ri
        WHERE ri.remito_id = r.id
          AND ri.cantidad > COALESCE((
            SELECT sum(a.cantidad)
            FROM remito_item_facturas a JOIN facturas f ON f.id = a.factura_id
            WHERE a.remito_item_id = ri.id AND f.estado <> 'anulada'
              AND f.estado_fiscal IN ('historico','autorizado')), 0))
      THEN 'facturado' ELSE 'pendiente' END,
    updated_at = NOW()
  WHERE r.id = p_remito_id AND r.estado <> 'anulado';
END;
$$;

-- ── Permisos ─────────────────────────────────────────────────────
-- REVOKE explícito: los DEFAULT PRIVILEGES de Supabase le dan EXECUTE a anon y authenticated a
-- toda función nueva. Las lecturas corren como authenticated, que tiene que poder llamar también
-- a las crm_* de lectura que usa la RPC. crm_remito_recalcular escribe: sólo desde otras RPC.
REVOKE ALL ON FUNCTION crm_clave_item(integer, text)                       FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_clave_item(integer, text)                    TO authenticated;
REVOKE ALL ON FUNCTION crm_facturas_pendientes(integer, integer)           FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_facturas_pendientes(integer, integer)        TO authenticated;
REVOKE ALL ON FUNCTION crm_remito_items_sin_facturar(integer)              FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_remito_items_sin_facturar(integer)           TO authenticated;
REVOKE ALL ON FUNCTION facturas_pendientes_remitir(integer, integer)       FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION facturas_pendientes_remitir(integer, integer)    TO authenticated;

REVOKE ALL ON FUNCTION crm_remito_recalcular(integer)                      FROM PUBLIC, anon, authenticated;
