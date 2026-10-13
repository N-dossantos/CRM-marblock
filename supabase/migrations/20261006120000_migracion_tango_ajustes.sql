-- Ajustes de schema para cargar la historia de Tango (PLAN_MIGRACION_TANGO.md D1 y D2;
-- D1 cubre Ventas y Compras).
-- D3 = (b): los descuentos 5 / 7 / 18 % se redondean al valor permitido, así que el CHECK de
-- clientes.descuento_porcentaje no se toca.

-- D1: importe imputado por factura (GVA07.IMPORT_CAN / CPA05.IMPORT_CAN). NULL = recibo creado por la app.
ALTER TABLE recibo_facturas         ADD COLUMN importe DECIMAL(14,2);
ALTER TABLE pago_proveedor_facturas ADD COLUMN importe DECIMAL(14,2);

-- Con importe imputado (historia de Tango) se usa ese importe; sin él (app) se mantiene el
-- cálculo anterior: todos los medios del recibo. SET search_path: lo fijó 20260727120004 (lint 0011)
-- y CREATE OR REPLACE lo borraría si no se repite.
CREATE OR REPLACE FUNCTION recalcular_estado_factura(p_factura_id INTEGER)
RETURNS VOID AS $$
DECLARE
  v_total    DECIMAL(14,2);
  v_cobrado  DECIMAL(14,2);
  v_nc_total DECIMAL(14,2);
BEGIN
  SELECT total INTO v_total FROM facturas WHERE id = p_factura_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT COALESCE(SUM(COALESCE(rf.importe,
           (SELECT COALESCE(SUM(rm.monto), 0) FROM recibo_medios rm WHERE rm.recibo_id = rf.recibo_id))), 0)
    INTO v_cobrado
  FROM recibo_facturas rf
  WHERE rf.factura_id = p_factura_id;

  SELECT COALESCE(SUM(total), 0) INTO v_nc_total
  FROM notas WHERE factura_id = p_factura_id AND tipo = 'NC';

  v_cobrado := v_cobrado + v_nc_total;

  UPDATE facturas SET
    estado = CASE
      WHEN v_cobrado <= 0              THEN 'pendiente'
      WHEN v_cobrado >= v_total - 0.01 THEN 'cobrada'
      ELSE                                  'parcial'
    END,
    updated_at = NOW()
  WHERE id = p_factura_id AND estado != 'anulada';
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

-- D2: las 30 NC/ND que Tango tiene "a cuenta" o anuladas no cuelgan de ninguna factura.
ALTER TABLE notas ALTER COLUMN factura_id DROP NOT NULL;

-- D1 en Compras: espeja recalcular_estado_factura. Con importe imputado (historia de Tango) se usa
-- ese importe; sin él (app) se mantiene el cálculo anterior: todos los medios y retenciones del pago.
-- Mismo SET search_path que la definición de 20260730120006.
CREATE OR REPLACE FUNCTION recalcular_estado_factura_compra(p_factura_compra_id integer)
RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_total  numeric;
  v_pagado numeric;
  v_nc     numeric;
BEGIN
  SELECT total INTO v_total FROM facturas_compra WHERE id = p_factura_compra_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT COALESCE(SUM(COALESCE(pf.importe,
           (SELECT COALESCE(SUM(m.monto), 0) FROM pago_proveedor_medios m
             WHERE m.pago_proveedor_id = pf.pago_proveedor_id)
         + (SELECT COALESCE(SUM(r.monto), 0) FROM retenciones r
             WHERE r.pago_proveedor_id = pf.pago_proveedor_id))), 0)
    INTO v_pagado
  FROM pago_proveedor_facturas pf
  WHERE pf.factura_compra_id = p_factura_compra_id;

  SELECT COALESCE(SUM(total), 0) INTO v_nc
  FROM notas_compra
  WHERE factura_compra_id = p_factura_compra_id AND tipo = 'NC';

  v_pagado := v_pagado + v_nc;

  UPDATE facturas_compra SET
    estado = CASE
      WHEN v_pagado <= 0              THEN 'pendiente'
      WHEN v_pagado >= v_total - 0.01 THEN 'pagada'
      ELSE                                 'parcial'
    END,
    updated_at = NOW()
  WHERE id = p_factura_compra_id AND estado <> 'anulada';
END;
$$;
