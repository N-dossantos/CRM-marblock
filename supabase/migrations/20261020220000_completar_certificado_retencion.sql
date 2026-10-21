-- Completar la documentación de una retención histórica una vez recibido el certificado.
CREATE FUNCTION completar_certificado_retencion(
  p_id integer,
  p_tipo_retencion varchar,
  p_numero_certificado varchar,
  p_fecha date,
  p_codigo_regimen varchar DEFAULT NULL,
  p_jurisdiccion varchar DEFAULT NULL
)
RETURNS recibo_retenciones
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_ret recibo_retenciones;
BEGIN
  IF p_tipo_retencion NOT IN ('Ganancias', 'IVA', 'IIBB', 'SUSS')
     OR NULLIF(btrim(p_numero_certificado), '') IS NULL
     OR p_fecha IS NULL
     OR (p_tipo_retencion = 'IIBB' AND NULLIF(btrim(p_jurisdiccion), '') IS NULL) THEN
    RAISE EXCEPTION 'Completá impuesto, número y fecha del certificado; para IIBB también jurisdicción.';
  END IF;

  BEGIN
    UPDATE recibo_retenciones SET
      tipo_retencion = p_tipo_retencion,
      numero_certificado = btrim(p_numero_certificado),
      fecha = p_fecha,
      codigo_regimen = NULLIF(btrim(p_codigo_regimen), ''),
      jurisdiccion = NULLIF(btrim(p_jurisdiccion), ''),
      pendiente_documentacion = false
    WHERE id = p_id AND pendiente_documentacion
    RETURNING * INTO v_ret;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Ese certificado ya está registrado para el cliente y el impuesto.';
  END;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La retención no existe o ya tiene certificado.';
  END IF;
  RETURN v_ret;
END;
$$;

REVOKE ALL ON FUNCTION completar_certificado_retencion(integer, varchar, varchar, date, varchar, varchar) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION completar_certificado_retencion(integer, varchar, varchar, date, varchar, varchar) TO authenticated;

NOTIFY pgrst, 'reload schema';
