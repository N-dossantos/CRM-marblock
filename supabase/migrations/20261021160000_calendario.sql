-- PLAN_MAESTRO §3.10: el almanaque pasa a llamarse calendario, y cada anotación pasa a ser un evento
-- con título y descripción opcional. Las filas existentes conservan su texto como título.
ALTER TABLE public.almanaque RENAME TO calendario;
ALTER SEQUENCE public.almanaque_id_seq RENAME TO calendario_id_seq;
ALTER TABLE public.calendario RENAME CONSTRAINT almanaque_pkey TO calendario_pkey;
ALTER TABLE public.calendario RENAME CONSTRAINT chk_almanaque_hecha TO chk_calendario_hecha;
ALTER INDEX public.idx_almanaque_fecha RENAME TO idx_calendario_fecha;

ALTER TABLE public.calendario RENAME COLUMN texto TO titulo;
ALTER TABLE public.calendario DROP CONSTRAINT almanaque_texto_check;
ALTER TABLE public.calendario
  ADD CONSTRAINT chk_calendario_titulo CHECK (length(btrim(titulo)) BETWEEN 1 AND 100);

-- Sin descripción va NULL, nunca texto vacío.
ALTER TABLE public.calendario ADD COLUMN descripcion TEXT
  CONSTRAINT chk_calendario_descripcion CHECK (length(btrim(descripcion)) BETWEEN 1 AND 500);

NOTIFY pgrst, 'reload schema';
