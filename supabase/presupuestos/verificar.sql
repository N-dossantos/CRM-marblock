-- Ejecutar en una base de prueba con las migraciones aplicadas. Todo se revierte.
-- psql "$TEST_DATABASE_URL" -X -f supabase/presupuestos/verificar.sql
\set ON_ERROR_STOP 1
BEGIN;
CREATE FUNCTION pg_temp.ok(c boolean, m text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF c IS TRUE THEN RAISE NOTICE 'OK %', m; ELSE RAISE EXCEPTION 'FALLA %', m; END IF;
END $$;

INSERT INTO contadores(tipo, punto_venta, ultimo_numero)
VALUES ('presupuesto', '09998', 0) ON CONFLICT (tipo) DO NOTHING;

SET LOCAL ROLE authenticated;
DO $$
DECLARE
  p presupuestos;
  c integer;
  f integer;
  r integer;
  j jsonb;
  items jsonb := '[{"descripcion":"Bloque de prueba","cantidad":2,"precio_unitario":100,"pallets":1,"unidades_por_pallet":2}]';
BEGIN
  INSERT INTO clientes(razon_social, doc_tipo, doc_nro, condicion_iva_afip_id)
  VALUES ('Cliente prueba presupuestos', 96, '98765432', 5) RETURNING id INTO c;

  SELECT * INTO p FROM crear_presupuesto(NULL, items, 10,
    'Tel: 11 1234 5678 / ana@example.com', '  Ana sin cuenta  ');
  PERFORM pg_temp.ok(p.cliente_id IS NULL AND p.destinatario = 'Ana sin cuenta', 'crear sin cliente, nombre recortado');
  PERFORM pg_temp.ok(p.total = 217.80, 'totales calculados en servidor');
  PERFORM pg_temp.ok((SELECT count(*) = 1 FROM clientes WHERE doc_nro = '98765432'), 'no se crea un cliente ficticio');
  SELECT x INTO j FROM presupuestos_list(p_id => p.id) x;
  PERFORM pg_temp.ok(j->>'razon_social' = 'Ana sin cuenta' AND jsonb_array_length(j->'items') = 1,
    'detalle sin cliente incluye destinatario e ítems');
  PERFORM pg_temp.ok(j->>'observaciones' LIKE '%ana@example.com%', 'contacto disponible para PDF');
  PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM presupuestos_list(p_q => 'Ana sin cuenta')), 'buscar por nombre');
  PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM presupuestos_list(p_q => 'ana@example.com')), 'buscar por mail');
  PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM presupuestos_list(p_q => '11 1234 5678')), 'buscar por teléfono');

  SELECT * INTO p FROM actualizar_presupuesto(p.id, c, items, p_destinatario => 'Nombre alternativo');
  PERFORM pg_temp.ok(p.cliente_id = c AND p.destinatario = 'Nombre alternativo', 'vincular cliente conservando nombre libre');
  SELECT * INTO p FROM actualizar_presupuesto(p.id, NULL, items, p_observaciones => 'nuevo@example.com', p_destinatario => 'Otra persona');
  PERFORM pg_temp.ok(p.cliente_id IS NULL AND p.destinatario = 'Otra persona', 'editar y desvincular cliente');

  BEGIN
    PERFORM crear_presupuesto(NULL, items, p_destinatario => '   ');
    RAISE EXCEPTION 'FALLA aceptó destinatario vacío';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'Ingrese el nombre del destinatario.' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM actualizar_presupuesto(p.id, NULL, items, p_destinatario => '');
    RAISE EXCEPTION 'FALLA aceptó edición sin destinatario';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'Ingrese el nombre del destinatario.' THEN RAISE; END IF;
  END;
  PERFORM pg_temp.ok(true, 'validación de nombre en creación y edición');

  UPDATE presupuestos SET fecha_vcto = CURRENT_DATE - 1 WHERE id = p.id;
  BEGIN
    PERFORM actualizar_presupuesto(p.id, NULL, items, p_destinatario => 'Otra persona');
    RAISE EXCEPTION 'FALLA guardó presupuesto vencido sin confirmar';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'PRESUPUESTO_VENCIDO' THEN RAISE; END IF;
  END;
  PERFORM actualizar_presupuesto(p.id, NULL, items, p_forzar_vencido => true, p_destinatario => 'Otra persona');
  PERFORM pg_temp.ok(true, 'vencimiento exige confirmación y permite continuar');
  PERFORM presupuesto_set_estado(p.id, 'aceptado');
  PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM presupuestos_list(p_id => p.id, p_estado => 'aceptado')), 'filtrar por estado sin cliente');
  BEGIN
    PERFORM eliminar_presupuesto(p.id);
    RAISE EXCEPTION 'FALLA eliminó un presupuesto aceptado';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'No se puede eliminar un presupuesto aceptado:%' THEN RAISE; END IF;
  END;
  PERFORM pg_temp.ok(true, 'aceptado no se elimina');
  UPDATE presupuestos SET estado = 'vencido' WHERE id = p.id;

  -- Se borran los ítems y se conservan los documentos derivados.
  INSERT INTO facturas(tipo, fecha, cliente_id, presupuesto_id, estado_fiscal)
  VALUES ('B', CURRENT_DATE, c, p.id, 'borrador') RETURNING id INTO f;
  INSERT INTO remitos(numero, punto_venta, numero_comp, fecha, cliente_id, presupuesto_id)
  VALUES ('09998-99999999', '09998', 99999999, CURRENT_DATE, c, p.id) RETURNING id INTO r;
  PERFORM eliminar_presupuesto(p.id);
  PERFORM pg_temp.ok(NOT EXISTS(SELECT 1 FROM presupuestos WHERE id = p.id), 'eliminar presupuesto');
  PERFORM pg_temp.ok(NOT EXISTS(SELECT 1 FROM presupuesto_items WHERE presupuesto_id = p.id), 'eliminar ítems por cascada');
  PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM facturas WHERE id = f AND presupuesto_id IS NULL), 'conservar factura derivada');
  PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM remitos WHERE id = r AND presupuesto_id IS NULL), 'conservar remito derivado');
  PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM audit_log WHERE tabla = 'presupuestos'
    AND registro_id = p.id::text AND accion = 'DELETE'), 'el borrado queda en audit_log');
  BEGIN
    PERFORM eliminar_presupuesto(p.id);
    RAISE EXCEPTION 'FALLA eliminar inexistente devuelve éxito';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'Presupuesto no encontrado' THEN RAISE; END IF;
  END;

  SELECT * INTO p FROM crear_presupuesto(c, items);
  SELECT x INTO j FROM presupuestos_list(p_id => p.id) x;
  PERFORM pg_temp.ok(j->>'razon_social' = 'Cliente prueba presupuestos', 'cliente registrado sigue funcionando');
  UPDATE presupuestos SET estado = 'convertido' WHERE id = p.id;
  BEGIN
    PERFORM eliminar_presupuesto(p.id);
    RAISE EXCEPTION 'FALLA eliminó un presupuesto convertido';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'No se puede eliminar un presupuesto convertido:%' THEN RAISE; END IF;
  END;
  PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM presupuestos WHERE id = p.id), 'convertido no se elimina');
END $$;
RESET ROLE;

SELECT pg_temp.ok(NOT has_function_privilege('anon', 'crear_presupuesto(integer,jsonb,numeric,text,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'actualizar_presupuesto(integer,integer,jsonb,numeric,text,varchar,boolean,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'eliminar_presupuesto(integer)', 'EXECUTE'), 'RPC sólo para usuarios autenticados');
SELECT pg_temp.ok(to_regprocedure('crear_presupuesto(integer,jsonb,numeric,text)') IS NULL
  AND to_regprocedure('actualizar_presupuesto(integer,integer,jsonb,numeric,text,varchar,boolean)') IS NULL,
  'no quedan firmas obsoletas');
ROLLBACK;
