-- =============================================================
-- PLAN_REMITOS_PENDIENTES — semilla para que el backfill de 20261020160000 tenga algo que
-- asignar en HOMOLOGACIÓN, que no trae remitos con factura_id. Va ANTES de la migración y sólo en
-- ensayo.sql (dentro de su BEGIN … ROLLBACK); no la incluyen verificar.sql ni ensayo_prod.sql.
--
-- Con INSERT directos, en el PV 09998 y con un cliente propio (no toca la fixture de
-- verificar_asignaciones.sql):
--   * una factura A histórica: bloque 1000, pallet 10, transporte 1;
--   * un remito facturado con esa factura_id: bloque 500, pallet 5 y transporte en 0 (el backfill
--     no asigna renglones en 0);
--   * un remito anulado con esa factura_id: bloque 100 (el backfill no lo asigna).
-- El control 1.3 compara, fila por fila, lo que asignó el backfill contra lo esperado.
--
-- ⚠ NUNCA contra producción.
-- =============================================================
DO $$
DECLARE
  v_bloque int := (SELECT id FROM productos WHERE unidades_por_pallet = 105 ORDER BY id LIMIT 1);
  v_pallet int := (SELECT id FROM productos WHERE es_pallet_vacio ORDER BY id LIMIT 1);
  v_transp int := (SELECT id FROM productos WHERE es_transporte ORDER BY id LIMIT 1);
  v_cli int;
  v_fac int;
  v_rem int;
BEGIN
  INSERT INTO clientes (razon_social, doc_tipo, doc_nro, condicion_iva_afip_id)
  VALUES ('PRUEBA BACKFILL', 80, '20999999972', 1) RETURNING id INTO v_cli;

  INSERT INTO facturas (numero, punto_venta, numero_comp, tipo, fecha, cliente_id, estado, estado_fiscal)
  VALUES ('09998-00000001', '09998', 1, 'A', CURRENT_DATE, v_cli, 'pendiente', 'historico')
  RETURNING id INTO v_fac;
  INSERT INTO factura_items (factura_id, producto_id, descripcion, cantidad, precio_unitario, subtotal, orden)
  SELECT v_fac, p.id, p.descripcion, x.c, 1000, x.c * 1000, x.n
  FROM (VALUES (v_bloque, 1000, 1), (v_pallet, 10, 2), (v_transp, 1, 3)) x(p, c, n)
  JOIN productos p ON p.id = x.p;

  INSERT INTO remitos (numero, punto_venta, numero_comp, fecha, cliente_id, factura_id, estado)
  VALUES ('09998-00000001', '09998', 1, CURRENT_DATE, v_cli, v_fac, 'facturado')
  RETURNING id INTO v_rem;
  INSERT INTO remito_items (remito_id, producto_id, descripcion, cantidad, orden)
  SELECT v_rem, p.id, p.descripcion, x.c, x.n
  FROM (VALUES (v_bloque, 500, 1), (v_pallet, 5, 2), (v_transp, 0, 3)) x(p, c, n)
  JOIN productos p ON p.id = x.p;

  INSERT INTO remitos (numero, punto_venta, numero_comp, fecha, cliente_id, factura_id, estado)
  VALUES ('09998-00000002', '09998', 2, CURRENT_DATE, v_cli, v_fac, 'anulado')
  RETURNING id INTO v_rem;
  INSERT INTO remito_items (remito_id, producto_id, descripcion, cantidad, orden)
  SELECT v_rem, p.id, p.descripcion, 100, 1 FROM productos p WHERE p.id = v_bloque;
END $$;
