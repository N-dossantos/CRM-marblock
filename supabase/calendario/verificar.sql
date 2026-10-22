-- Homologación, con la migración aplicada dentro de la transacción de ensayo.sql.
-- Termina con una fila "N OK: …"; ante la primera falla corta con "FALLA …".
\set ON_ERROR_STOP 1
CREATE TEMP TABLE resultados(m text, t timestamptz DEFAULT clock_timestamp());
GRANT INSERT ON resultados TO authenticated;
CREATE FUNCTION pg_temp.ok(c boolean, m text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF c IS TRUE THEN RAISE NOTICE 'OK %', m; INSERT INTO pg_temp.resultados(m) VALUES (m);
 ELSE RAISE EXCEPTION 'FALLA %', m; END IF;
END $$;
SET LOCAL TIME ZONE 'America/Argentina/Buenos_Aires';
SELECT set_config('request.jwt.claim.sub', (SELECT id::text FROM auth.users ORDER BY created_at LIMIT 1), true) IS NOT NULL AS usuario_de_prueba;

SELECT pg_temp.ok(to_regclass('public.calendario') IS NOT NULL AND to_regclass('public.almanaque') IS NULL,
  'la tabla se llama calendario');
SELECT pg_temp.ok(
  (SELECT string_agg(conname, ',' ORDER BY conname) FROM pg_constraint WHERE conrelid = 'public.calendario'::regclass)
    = 'calendario_pkey,chk_calendario_descripcion,chk_calendario_hecha,chk_calendario_titulo'
  AND to_regclass('public.idx_calendario_fecha') IS NOT NULL
  AND pg_get_serial_sequence('public.calendario', 'id') = 'public.calendario_id_seq',
  'restricciones, índice y secuencia con el nombre nuevo');
SELECT pg_temp.ok(NOT EXISTS(SELECT 1 FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'calendario' AND column_name = 'texto'), 'texto pasó a titulo');

SET LOCAL ROLE authenticated;
DO $$
DECLARE n integer; d integer; instante timestamptz := now();
BEGIN
 INSERT INTO calendario(fecha, titulo) VALUES (CURRENT_DATE - 1, 'Pedir talonario') RETURNING id INTO n;
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM calendario WHERE id=n AND descripcion IS NULL AND NOT hecha AND hecha_en IS NULL),
   'alta con título y sin descripción');
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM calendario WHERE fecha<CURRENT_DATE AND NOT hecha AND id=n), 'atrasado visible');
 INSERT INTO calendario(fecha, titulo, descripcion)
   VALUES (CURRENT_DATE, 'Cliente Duramat', E'Va a venir a retirar 10 bloques de 20 estándar\ny 10 bloque liso de 10.')
   RETURNING id INTO d;
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM calendario WHERE id=d AND descripcion LIKE E'%estándar\ny 10%'),
   'alta con descripción de varias líneas');
 UPDATE calendario SET fecha=CURRENT_DATE, titulo='Título corregido', descripcion='Descripción nueva' WHERE id=n;
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM calendario WHERE id=n AND titulo='Título corregido'
   AND descripcion='Descripción nueva' AND fecha=CURRENT_DATE), 'edición de fecha, título y descripción');
 UPDATE calendario SET descripcion=NULL WHERE id=n;
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM calendario WHERE id=n AND descripcion IS NULL), 'se puede sacar la descripción');
 UPDATE calendario SET hecha=true, hecha_en=instante WHERE id=n;
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM calendario WHERE id=n AND hecha AND hecha_en=instante), 'tildar con fecha de finalización');
 UPDATE calendario SET hecha=false, hecha_en=NULL WHERE id=n;
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM calendario WHERE id=n AND NOT hecha AND hecha_en IS NULL), 'destildar limpia fecha');
 BEGIN
   UPDATE calendario SET hecha=true WHERE id=n;
   RAISE EXCEPTION 'FALLA permite estado incoherente';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
   INSERT INTO calendario(fecha,titulo) VALUES (CURRENT_DATE,'   ');
   RAISE EXCEPTION 'FALLA permite título vacío';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
   INSERT INTO calendario(fecha,titulo) VALUES (CURRENT_DATE,repeat('a',101));
   RAISE EXCEPTION 'FALLA permite título de más de 100 caracteres';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
   INSERT INTO calendario(fecha,titulo,descripcion) VALUES (CURRENT_DATE,'Con descripción vacía','  ');
   RAISE EXCEPTION 'FALLA permite descripción vacía (va NULL)';
 EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN
   INSERT INTO calendario(fecha,titulo,descripcion) VALUES (CURRENT_DATE,'Descripción larga',repeat('a',501));
   RAISE EXCEPTION 'FALLA permite descripción de más de 500 caracteres';
 EXCEPTION WHEN check_violation THEN NULL; END;
 UPDATE calendario SET titulo=repeat('ñ',100), descripcion=repeat('ñ',500) WHERE id=n;
 PERFORM pg_temp.ok(true, 'título de 1 a 100, descripción NULL o de 1 a 500, y coherencia hecha/hecha_en');
 DELETE FROM calendario WHERE id IN (n, d);
 PERFORM pg_temp.ok(NOT EXISTS(SELECT 1 FROM calendario WHERE id IN (n, d)), 'borrado físico');
 PERFORM pg_temp.ok((SELECT count(*)>=7 FROM audit_log WHERE tabla='calendario' AND registro_id=n::text),
   'alta, ediciones, tildado y borrado auditados como calendario');
 PERFORM pg_temp.ok(EXISTS(SELECT 1 FROM audit_log WHERE tabla='calendario' AND registro_id=n::text AND usuario_id=auth.uid() AND accion='DELETE'),
   'auditoría identifica usuario');
END $$;
RESET ROLE;

DO $$
BEGIN
 BEGIN
   SET LOCAL ROLE anon;
   PERFORM count(*) FROM calendario;
   RAISE EXCEPTION 'FALLA anon pudo leer';
 EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; END;
 BEGIN
   SET LOCAL ROLE anon;
   INSERT INTO calendario(fecha,titulo) VALUES (CURRENT_DATE,'No autorizado');
   RAISE EXCEPTION 'FALLA anon pudo escribir';
 EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; END;
 PERFORM pg_temp.ok(true, 'anon no puede leer ni escribir');
END $$;
SELECT pg_temp.ok(relrowsecurity AND NOT relforcerowsecurity, 'RLS habilitado sin FORCE')
FROM pg_class WHERE oid='public.calendario'::regclass;
