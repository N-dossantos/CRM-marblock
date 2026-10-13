-- ══════════════════════════════════════════════════════════════════
-- M12 (PLAN_MIGRACION_TANGO.md, mejoras del smoke) — Libros IVA para el contador.
--
--   * informe_libro_iva_ventas (NUEVO): no había Libro IVA Ventas. Lista por período las facturas
--     A/B y las NC/ND de venta, con cliente, CUIT, condición IVA, neto, IVA, percepciones y total.
--     Las NC van con signo negativo, así la suma de cada columna es el débito fiscal del período.
--     Las anuladas se listan (la numeración no tiene huecos) con importes en 0 — en la base ya
--     están en 0: las facturas anuladas se cargan así y las NC/ND anuladas de Tango traen total 0.
--
--   * informe_iva_compras: listaba sólo facturas_compra; las NC/ND de proveedores (478 en la carga
--     de Tango) no aparecían y el libro quedaba incompleto. Ahora entran como renglones con
--     `comprobante` = 'NC' / 'ND' (las facturas, 'FAC'); las NC con signo negativo en neto, IVA,
--     percepciones y total, y los totales y el resumen de percepciones las descuentan. Las notas no
--     tienen desglose por alícuota (no hay nota_compra_iva_detalle): `iva_detalle` va vacío.
--     Las claves que ya existían no cambian; se agregan `comprobante` e `id`.
--
-- Ambas son de sólo lectura (STABLE, sin SECURITY DEFINER): corren como `authenticated` y RLS aplica.
-- ══════════════════════════════════════════════════════════════════

-- ── Libro IVA Ventas ──────────────────────────────────────────────
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
      c.razon_social, c.cuit, c.condicion_iva,
      f.estado = 'anulada' AS anulada,
      f.neto_gravado, f.iva_monto, COALESCE(f.percepciones_monto, 0) AS percepciones_monto, f.total
    FROM facturas f JOIN clientes c ON c.id = f.cliente_id
    WHERE f.fecha BETWEEN p_desde AND p_hasta
    UNION ALL
    SELECT n.id, n.fecha, n.tipo::text, n.tipo_letra::text,
      n.punto_venta, n.numero_comp, n.numero,
      c.razon_social, c.cuit, c.condicion_iva,
      n.total = 0 AS anulada,
      s.signo * n.neto_gravado, s.signo * n.iva_monto,
      s.signo * COALESCE(n.percepciones_monto, 0), s.signo * n.total
    FROM notas n
    JOIN clientes c ON c.id = n.cliente_id
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

-- ── Libro IVA Compras: + NC/ND de proveedores ─────────────────────
CREATE OR REPLACE FUNCTION informe_iva_compras(p_desde date, p_hasta date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = public, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'Parámetros desde y hasta son obligatorios.';
  END IF;

  WITH libro AS (
    SELECT fc.id, fc.fecha, 'FAC'::text AS comprobante, fc.tipo::text AS tipo,
      fc.punto_venta, fc.numero, p.razon_social, p.cuit,
      fc.neto_gravado, fc.iva_monto, fc.percepciones_monto, fc.total,
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'porcentaje', a.porcentaje, 'neto_gravado', d.neto_gravado, 'iva_monto', d.iva_monto
              ) ORDER BY a.porcentaje), '[]')
       FROM factura_compra_iva_detalle d JOIN alicuotas_iva a ON a.id = d.alicuota_iva_id
       WHERE d.factura_compra_id = fc.id) AS iva_detalle,
      COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                WHERE pc.factura_compra_id = fc.id AND pc.tipo = 'iva'), 0)  AS percepcion_iva,
      COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                WHERE pc.factura_compra_id = fc.id AND pc.tipo = 'iibb'), 0) AS percepcion_iibb,
      COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                WHERE pc.factura_compra_id = fc.id
                  AND pc.tipo IN ('ganancias','imp_internos')), 0)           AS percepcion_otros,
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'tipo', pc.tipo, 'jurisdiccion', pc.jurisdiccion,
                'alicuota', pc.alicuota, 'monto', pc.monto
              ) ORDER BY pc.tipo, pc.jurisdiccion NULLS FIRST), '[]')
       FROM percepciones_compra pc WHERE pc.factura_compra_id = fc.id) AS percepciones
    FROM facturas_compra fc
    JOIN proveedores p ON p.id = fc.proveedor_id
    WHERE fc.estado <> 'anulada' AND fc.fecha BETWEEN p_desde AND p_hasta
    UNION ALL
    SELECT nc.id, nc.fecha, nc.tipo::text, nc.tipo_letra::text,
      nc.punto_venta, nc.numero, p.razon_social, p.cuit,
      s.signo * nc.neto_gravado, s.signo * nc.iva_monto,
      s.signo * COALESCE(nc.percepciones_monto, 0), s.signo * nc.total,
      '[]'::jsonb,
      s.signo * COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                          WHERE pc.nota_compra_id = nc.id AND pc.tipo = 'iva'), 0),
      s.signo * COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                          WHERE pc.nota_compra_id = nc.id AND pc.tipo = 'iibb'), 0),
      s.signo * COALESCE((SELECT SUM(pc.monto) FROM percepciones_compra pc
                          WHERE pc.nota_compra_id = nc.id
                            AND pc.tipo IN ('ganancias','imp_internos')), 0),
      (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'tipo', pc.tipo, 'jurisdiccion', pc.jurisdiccion,
                'alicuota', pc.alicuota, 'monto', s.signo * pc.monto
              ) ORDER BY pc.tipo, pc.jurisdiccion NULLS FIRST), '[]')
       FROM percepciones_compra pc WHERE pc.nota_compra_id = nc.id)
    FROM notas_compra nc
    JOIN proveedores p ON p.id = nc.proveedor_id
    CROSS JOIN LATERAL (SELECT CASE WHEN nc.tipo = 'NC' THEN -1 ELSE 1 END AS signo) s
    WHERE nc.fecha BETWEEN p_desde AND p_hasta
  )
  SELECT jsonb_build_object(
    'comprobantes', (SELECT COALESCE(jsonb_agg(to_jsonb(l) ORDER BY l.fecha, l.comprobante, l.numero), '[]')
                     FROM libro l),
    -- Percepciones por tipo y jurisdicción, para el resumen del libro (las de NC restan).
    'percepciones_resumen', (SELECT COALESCE(jsonb_agg(z ORDER BY z.tipo, z.jurisdiccion NULLS FIRST), '[]') FROM (
      SELECT pc.tipo, pc.jurisdiccion, COUNT(*) AS comprobantes,
        SUM(CASE WHEN nc.tipo = 'NC' THEN -pc.monto ELSE pc.monto END) AS monto
      FROM percepciones_compra pc
      LEFT JOIN facturas_compra fc ON fc.id = pc.factura_compra_id
      LEFT JOIN notas_compra    nc ON nc.id = pc.nota_compra_id
      WHERE COALESCE(fc.fecha, nc.fecha) BETWEEN p_desde AND p_hasta
        AND COALESCE(fc.estado, 'ok') <> 'anulada'
      GROUP BY pc.tipo, pc.jurisdiccion
    ) z),
    'retenciones', (SELECT COALESCE(jsonb_agg(y ORDER BY y.fecha), '[]') FROM (
      SELECT r.fecha, r.tipo_retencion, r.jurisdiccion, r.numero_certificado, r.monto,
        p.razon_social, p.cuit
      FROM retenciones r JOIN proveedores p ON p.id = r.proveedor_id
      WHERE r.fecha BETWEEN p_desde AND p_hasta
    ) y),
    'totales', (SELECT jsonb_build_object(
      'neto_gravado',       COALESCE(SUM(l.neto_gravado), 0),
      'iva_monto',          COALESCE(SUM(l.iva_monto), 0),
      'percepciones_monto', COALESCE(SUM(l.percepciones_monto), 0),
      'total',              COALESCE(SUM(l.total), 0),
      'percepcion_iva',     COALESCE(SUM(l.percepcion_iva), 0),
      'percepcion_iibb',    COALESCE(SUM(l.percepcion_iibb), 0),
      'retenciones',        COALESCE((SELECT SUM(r.monto) FROM retenciones r
                                      WHERE r.fecha BETWEEN p_desde AND p_hasta), 0))
      FROM libro l)
  ) INTO v;
  RETURN v;
END;
$$;

REVOKE ALL ON FUNCTION informe_libro_iva_ventas(date, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION informe_iva_compras(date, date)      FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION informe_libro_iva_ventas(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION informe_iva_compras(date, date)      TO authenticated;
