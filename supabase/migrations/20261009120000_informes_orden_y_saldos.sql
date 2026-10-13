-- ══════════════════════════════════════════════════════════════════
-- Mejoras del smoke del dry-run (2026-10-09) — PLAN_MIGRACION_TANGO.md, M5 y M8.
--
--   * informe_dashboard: "Últimas facturas emitidas" ordenaba por created_at. En la carga
--     masiva de Tango todas las facturas comparten el mismo created_at (una transacción), así que
--     el orden salía arbitrario y aparecían facturas viejas del PV 00001. Ahora ordena por fecha
--     del comprobante (y número / id para desempatar).
--     Además "Total por cobrar" y "Top deudores" sumaban el total ENTERO de las facturas
--     pendientes/parciales, sin restar lo cobrado ni las NC. Ahora usan el saldo de cada factura,
--     con la misma cuenta que recalcular_estado_factura (total − imputado en recibos − NC).
--
--   * informe_cta_cte / informe_cta_cte_proveedor: con período, el saldo corrido arrancaba de 0 en
--     vez del saldo anterior al período, y el filtro sólo se aplicaba si venían las DOS fechas.
--     Ahora:
--       - `desde` y `hasta` filtran por separado;
--       - si hay `desde`, la primera fila es SALDO ANTERIOR (todo lo previo a `desde`) y el saldo
--         corrido parte de ahí;
--       - `saldo_total` es el saldo al `hasta` (o el saldo actual sin `hasta`), que coincide con
--         el saldo de esa fecha en la vista sin filtro.
--     Se agregan `saldo_anterior`, `desde` y `hasta` a la respuesta. La forma de `movimientos` no
--     cambia (la fila sintética usa las mismas claves), así que el PDF la imprime sin cambios.
--
-- Las tres conservan su firma: los grants vigentes siguen aplicando; se re-afirman al final.
-- ══════════════════════════════════════════════════════════════════

-- ── M5: dashboard ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION informe_dashboard()
RETURNS jsonb
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  -- Saldo de cada factura impaga. `rf.importe` NULL = imputación vieja de un recibo a una sola
  -- factura: cuenta el recibo entero (igual que recalcular_estado_factura).
  WITH saldos AS (
    SELECT f.id, f.cliente_id,
      GREATEST(f.total
        - COALESCE((SELECT SUM(COALESCE(rf.importe,
              (SELECT COALESCE(SUM(rm.monto), 0) FROM recibo_medios rm WHERE rm.recibo_id = rf.recibo_id)))
            FROM recibo_facturas rf WHERE rf.factura_id = f.id), 0)
        - COALESCE((SELECT SUM(n.total) FROM notas n WHERE n.factura_id = f.id AND n.tipo = 'NC'), 0),
        0) AS saldo
    FROM facturas f
    WHERE f.estado IN ('pendiente','parcial')
  )
  SELECT jsonb_build_object(
    'kpis', jsonb_build_object(
      'total_clientes',       (SELECT COUNT(*) FROM clientes WHERE activo),
      'total_productos',      (SELECT COUNT(*) FROM productos WHERE activo),
      'total_por_cobrar',     (SELECT COALESCE(SUM(saldo),0) FROM saldos),
      'remitos_pendientes',   (SELECT COUNT(*) FROM remitos WHERE estado = 'pendiente'),
      'presupuestos_activos', (SELECT COUNT(*) FROM presupuestos WHERE estado IN ('borrador','enviado')),
      'cheques_vencidos',     (SELECT COUNT(*) FROM cheques WHERE estado = 'en_cartera' AND fecha_vcto < CURRENT_DATE)
    ),
    'ultimas_facturas', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT f.id, f.numero, f.fecha, f.total, f.estado, f.tipo, c.razon_social
      FROM facturas f JOIN clientes c ON c.id = f.cliente_id
      WHERE f.estado <> 'anulada'
      ORDER BY f.fecha DESC, f.numero DESC, f.id DESC LIMIT 8) x),
    'top_deudores', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT c.id, c.razon_social, SUM(s.saldo) AS saldo_pendiente
      FROM clientes c JOIN saldos s ON s.cliente_id = c.id
      GROUP BY c.id, c.razon_social
      HAVING SUM(s.saldo) > 0
      ORDER BY SUM(s.saldo) DESC LIMIT 5) x),
    'cheques_por_vencer', (SELECT COALESCE(jsonb_agg(x), '[]') FROM (
      SELECT ch.numero, ch.banco, ch.monto, ch.fecha_vcto, ch.estado, c.razon_social AS cliente_razon_social
      FROM cheques ch LEFT JOIN clientes c ON c.id = ch.cliente_id
      WHERE ch.estado = 'en_cartera' AND ch.fecha_vcto BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '7 days'
      ORDER BY ch.fecha_vcto LIMIT 5) x)
  );
$$;

-- ── M8: cuenta corriente de clientes ──────────────────────────────
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
  SELECT to_jsonb(c) INTO v_cli FROM clientes c WHERE c.id = p_cliente_id;
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

-- ── M8: cuenta corriente de proveedores (mismo error, mismo arreglo) ──
CREATE OR REPLACE FUNCTION informe_cta_cte_proveedor(
  p_proveedor_id integer, p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE
  v_prov     jsonb;
  v_movs     jsonb;
  v_anterior numeric;
  v_saldo    numeric;
BEGIN
  SELECT to_jsonb(p) INTO v_prov FROM proveedores p WHERE p.id = p_proveedor_id;
  IF v_prov IS NULL THEN
    RAISE EXCEPTION 'Proveedor no encontrado';
  END IF;

  WITH movs AS (
    -- Factura de compra: debe (le debemos)
    SELECT fc.fecha, fc.numero AS comprobante, 'FACTURA'::text AS tipo,
           fc.total AS debe, 0::numeric AS haber
    FROM facturas_compra fc
    WHERE fc.proveedor_id = p_proveedor_id AND fc.estado <> 'anulada'
    UNION ALL
    -- Nota de crédito: haber
    SELECT nc.fecha, nc.numero, 'NOTA CRED.', 0::numeric, nc.total
    FROM notas_compra nc
    WHERE nc.proveedor_id = p_proveedor_id AND nc.tipo = 'NC'
    UNION ALL
    -- Nota de débito: debe
    SELECT nc.fecha, nc.numero, 'NOTA DEB.', nc.total, 0::numeric
    FROM notas_compra nc
    WHERE nc.proveedor_id = p_proveedor_id AND nc.tipo = 'ND'
    UNION ALL
    -- Pago: haber
    SELECT pp.fecha, pp.numero, 'PAGO', 0::numeric, pp.total
    FROM pagos_proveedor pp
    WHERE pp.proveedor_id = p_proveedor_id
    UNION ALL
    -- Retención: haber (reduce lo que debemos al proveedor)
    SELECT r.fecha, COALESCE(r.numero_certificado, 'RET '||r.tipo_retencion), 'RETENCIÓN', 0::numeric, r.monto
    FROM retenciones r
    WHERE r.proveedor_id = p_proveedor_id
  ),
  anterior AS (
    SELECT COALESCE(SUM(m.debe - m.haber), 0) AS saldo
    FROM movs m WHERE p_desde IS NOT NULL AND m.fecha < p_desde
  ),
  ordered AS (
    SELECT m.*,
      (SELECT saldo FROM anterior) + SUM(m.debe - m.haber) OVER (
        ORDER BY m.fecha ASC, m.comprobante ASC, m.tipo ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS saldo
    FROM movs m
    WHERE (p_desde IS NULL OR m.fecha >= p_desde)
      AND (p_hasta IS NULL OR m.fecha <= p_hasta)
  )
  SELECT
    COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.fecha, o.comprobante, o.tipo), '[]'),
    (SELECT saldo FROM anterior),
    (SELECT saldo FROM anterior) + COALESCE(SUM(o.debe - o.haber), 0)
  INTO v_movs, v_anterior, v_saldo
  FROM ordered o;

  IF p_desde IS NOT NULL THEN
    v_movs := jsonb_build_array(jsonb_build_object(
      'fecha', p_desde, 'comprobante', '—', 'tipo', 'SALDO ANTERIOR',
      'debe', 0, 'haber', 0, 'saldo', v_anterior)) || v_movs;
  END IF;

  RETURN jsonb_build_object(
    'proveedor', v_prov, 'movimientos', v_movs, 'saldo_total', v_saldo,
    'saldo_anterior', v_anterior, 'desde', p_desde, 'hasta', p_hasta);
END;
$$;

REVOKE ALL ON FUNCTION informe_dashboard()                               FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION informe_cta_cte(integer, date, date)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION informe_cta_cte_proveedor(integer, date, date)    FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION informe_dashboard()                            TO authenticated;
GRANT EXECUTE ON FUNCTION informe_cta_cte(integer, date, date)           TO authenticated;
GRANT EXECUTE ON FUNCTION informe_cta_cte_proveedor(integer, date, date) TO authenticated;
