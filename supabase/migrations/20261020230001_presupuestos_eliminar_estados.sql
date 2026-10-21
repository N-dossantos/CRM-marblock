-- Un presupuesto aceptado, rechazado o convertido es historia del cliente: sólo se eliminan
-- los que están en borrador, enviados o vencidos.
CREATE OR REPLACE FUNCTION eliminar_presupuesto(p_id integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_estado varchar;
BEGIN
  SELECT estado INTO v_estado FROM presupuestos WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Presupuesto no encontrado';
  END IF;
  IF v_estado NOT IN ('borrador', 'enviado', 'vencido') THEN
    RAISE EXCEPTION 'No se puede eliminar un presupuesto %: sólo los que están en borrador, enviados o vencidos.', v_estado;
  END IF;
  DELETE FROM presupuestos WHERE id = p_id;
END;
$$;

NOTIFY pgrst, 'reload schema';
