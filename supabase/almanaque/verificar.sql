-- Homologación, con la migración aplicada dentro de la transacción de ensayo.sql.
\set ON_ERROR_STOP 1
CREATE FUNCTION pg_temp.ok(c boolean, m text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF c IS TRUE THEN RAISE NOTICE 'OK %', m; ELSE RAISE EXCEPTION 'FALLA %', m; END IF;
END $$;
SET LOCAL TIME ZONE 'America/Argentina/Buenos_Aires';
SELECT set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users ORDER BY created_at LIMIT 1), true) IS NOT NULL AS usuario_de_prueba;

SET LOCAL ROLE authenticated;
DO $$
DECLARE n integer; instante timestamptz := now();
BEGIN
 INSERT INTO almanaque(fecha, texto) VALUES (CURRENT_DATE - 1, 'Prueba de almanaque') RETURNING id INTO n;
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM almanaque WHERE id=n AND NOT hecha AND hecha_en IS NULL), 'alta pendiente compartida');
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM almanaque WHERE fecha<CURRENT_DATE AND NOT hecha AND id=n), 'atrasada visible');
 UPDATE almanaque SET fecha=CURRENT_DATE, texto='Texto corregido' WHERE id=n;
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM almanaque WHERE id=n AND texto='Texto corregido' AND fecha=CURRENT_DATE), 'edición de texto y fecha');
 UPDATE almanaque SET hecha=true, hecha_en=instante WHERE id=n;
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM almanaque WHERE id=n AND hecha AND hecha_en=instante), 'tildar con fecha de finalización');
 UPDATE almanaque SET hecha=false, hecha_en=NULL WHERE id=n;
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM almanaque WHERE id=n AND NOT hecha AND hecha_en IS NULL), 'destildar limpia fecha');
 BEGIN
   UPDATE almanaque SET hecha=true WHERE id=n;
   RAISE EXCEPTION 'FALLA permite estado incoherente';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
   INSERT INTO almanaque(fecha,texto) VALUES (CURRENT_DATE,'   ');
   RAISE EXCEPTION 'FALLA permite texto vacío';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
   INSERT INTO almanaque(fecha,texto) VALUES (CURRENT_DATE,repeat('a',201));
   RAISE EXCEPTION 'FALLA permite más de 200 caracteres';
 EXCEPTION WHEN check_violation THEN NULL; END;
 UPDATE almanaque SET texto=repeat('ñ',200) WHERE id=n;
 PERFORM pg_temp.ok(true, 'texto de 1 a 200 caracteres y coherencia hecha/hecha_en');
 DELETE FROM almanaque WHERE id=n;
 PERFORM pg_temp.ok(NOT EXISTS(SELECT 1 FROM almanaque WHERE id=n), 'borrado físico');
 PERFORM pg_temp.ok((SELECT count(*)>=6 FROM audit_log WHERE tabla='almanaque' AND registro_id=n::text), 'alta, edición, tildado y borrado auditados');
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM audit_log WHERE tabla='almanaque' AND registro_id=n::text AND usuario_id=auth.uid() AND accion='DELETE'), 'auditoría identifica usuario');
END $$;
RESET ROLE;

DO $$
BEGIN
 BEGIN
   SET LOCAL ROLE anon;
   PERFORM count(*) FROM almanaque;
   RAISE EXCEPTION 'FALLA anon pudo leer';
 EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; END;
 BEGIN
   SET LOCAL ROLE anon;
   INSERT INTO almanaque(fecha,texto) VALUES (CURRENT_DATE,'No autorizado');
   RAISE EXCEPTION 'FALLA anon pudo escribir';
 EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; END;
 PERFORM pg_temp.ok(true, 'anon no puede leer ni escribir');
END $$;
SELECT pg_temp.ok(relrowsecurity AND NOT relforcerowsecurity, 'RLS habilitado sin FORCE')
FROM pg_class WHERE oid='public.almanaque'::regclass;
