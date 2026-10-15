-- =============================================================
-- ARCA — revisión de clientes antes de aplicar la Fase 2 en producción (PLAN_ARCA.md §3.2)
--
-- Cuándo: el día del cutover, DESPUÉS de cargar Tango (05_cargar.sh) y ANTES de aplicar
-- 20261015120001_clientes_documento_condicion_iva.sql. Lee clientes.cuit y clientes.condicion_iva,
-- que esa migración borra.
--
-- Sólo lee. Cada fila es un cliente a decidir. Las correcciones se cargan a mano, en el formato
-- viejo, antes de la migración (que después las convierte):
--   UPDATE clientes SET cuit = '20-12345678-9' WHERE id = …;            -- CUIT real
--   UPDATE clientes SET cuit = '12345678', condicion_iva = 'Consumidor Final' WHERE id = …;  -- DNI
--   UPDATE clientes SET condicion_iva = 'Monotributista' WHERE id = …;  -- monotributo (Id 6)
--   UPDATE clientes SET condicion_iva = 'Consumidor Final' WHERE id = …;  -- deja de ser RI
--
-- Uso: psql "$(cat .db_url)" -X -f supabase/arca/revision_clientes.sql
--      (o cada consulta por separado con execute_sql del MCP: no hay comandos de psql)
-- =============================================================

-- ── 1) Lo que aborta la migración ────────────────────────────────
-- Tiene que dar 0 filas. Si no, corregir antes de aplicar: la migración no adivina.
WITH c AS (
  SELECT id, razon_social, cuit, condicion_iva, regexp_replace(cuit, '\D', '', 'g') AS nro
  FROM clientes
)
SELECT 'condición IVA sin equivalente en el catálogo' AS problema, id, razon_social, cuit, condicion_iva
FROM c
WHERE condicion_iva IS NULL
   OR condicion_iva NOT IN ('Resp. Inscripto', 'Monotributista', 'Exento', 'Consumidor Final')
UNION ALL
SELECT 'documento que no es CUIT (11 dígitos) ni DNI (7–8)', id, razon_social, cuit, condicion_iva
FROM c
WHERE NOT (length(nro) = 11 OR length(nro) BETWEEN 7 AND 8)
UNION ALL
-- UNIQUE (doc_tipo, doc_nro): dos CUIT que sólo difieren en los guiones chocan.
SELECT 'documento repetido sin los guiones', id, razon_social, cuit, condicion_iva
FROM c
WHERE nro IN (SELECT nro FROM c GROUP BY nro HAVING count(*) > 1)
ORDER BY 1, 3;

-- ── 2) Clientes a decidir ────────────────────────────────────────
-- No abortan la migración, pero sin corregirlos no se les puede facturar, o el sistema les
-- exigiría una letra que ARCA rechaza. Tango no tiene categoría de monotributo, y el ETL toma la
-- condición del último comprobante que la informa; por eso se compara con su letra.
WITH comp AS (
  SELECT f.cliente_id, f.tipo AS letra, f.fecha, f.id, 'Factura' AS comprobante, f.numero
  FROM facturas f
  UNION ALL
  SELECT f.cliente_id, n.tipo_letra, n.fecha, n.id, CASE n.tipo WHEN 'NC' THEN 'NC' ELSE 'ND' END, n.numero
  FROM notas n JOIN facturas f ON f.id = n.factura_id
),
ult AS (
  SELECT DISTINCT ON (cliente_id) cliente_id, letra, fecha,
         comprobante || ' ' || letra || ' ' || numero AS comprobante
  FROM comp
  ORDER BY cliente_id, fecha DESC, id DESC
),
v AS (
  SELECT cl.id, cl.razon_social, cl.cuit, cl.condicion_iva, d.nro,
         CASE WHEN length(d.nro) BETWEEN 7 AND 8 THEN 'DNI' ELSE 'CUIT' END AS doc,
         -- Mismo cálculo que crm_cuit_valido (20261015120002_rpc_arca), que todavía no existe.
         CASE WHEN d.nro ~ '^[0-9]{11}$' AND d.nro <> '00000000000' THEN (
           SELECT CASE 11 - s % 11 WHEN 11 THEN 0 WHEN 10 THEN -1 ELSE 11 - s % 11 END
           FROM (SELECT SUM(substr(d.nro, i, 1)::int * (ARRAY[5,4,3,2,7,6,5,4,3,2])[i]) AS s
                 FROM generate_series(1, 10) AS i) x
         ) = substr(d.nro, 11, 1)::int ELSE false END AS cuit_ok,
         CASE WHEN cl.condicion_iva IN ('Resp. Inscripto', 'Monotributista') THEN 'A' ELSE 'B' END AS clase,
         u.letra AS ult_letra, u.fecha AS ult_fecha, u.comprobante AS ult_comprobante
  FROM clientes cl
  CROSS JOIN LATERAL (SELECT regexp_replace(cl.cuit, '\D', '', 'g') AS nro) d
  LEFT JOIN ult u ON u.cliente_id = cl.id
)
SELECT problema, id, razon_social, cuit, condicion_iva, ult_comprobante, ult_fecha, sugerencia
FROM (
  SELECT 1 AS orden, 'CUIT inválido o de relleno' AS problema,
         'Cargar el CUIT real (o el DNI si es consumidor final). Hasta entonces no se le puede facturar.' AS sugerencia, v.*
  FROM v WHERE doc = 'CUIT' AND NOT cuit_ok
  UNION ALL
  SELECT 2, 'Resp. Inscripto con último comprobante B',
         'Confirmar en el padrón de ARCA. Si es RI queda así (Factura A); si no, Consumidor Final o Exento (Factura B).', v.*
  FROM v WHERE condicion_iva = 'Resp. Inscripto' AND ult_letra = 'B'
  UNION ALL
  SELECT 3, condicion_iva || ' con CUIT y último comprobante A',
         'Confirmar en el padrón de ARCA. Si es monotributista o RI, cambiar la condición (Factura A); si no, queda (Factura B).', v.*
  FROM v WHERE condicion_iva IN ('Consumidor Final', 'Exento') AND doc = 'CUIT' AND cuit_ok AND ult_letra = 'A'
  UNION ALL
  SELECT 4, condicion_iva || ' con DNI',
         'La Factura A exige CUIT: cargar el CUIT o cambiar la condición.', v.*
  FROM v WHERE clase = 'A' AND doc = 'DNI'
) x
ORDER BY orden, razon_social;

-- ── 3) Cómo queda la conversión ──────────────────────────────────
-- Para comparar con la cantidad de clientes cargados y ver la distribución por letra.
SELECT condicion_iva,
       CASE condicion_iva WHEN 'Resp. Inscripto' THEN 1 WHEN 'Monotributista' THEN 6
                          WHEN 'Exento' THEN 4 WHEN 'Consumidor Final' THEN 5 END AS id_arca,
       CASE WHEN condicion_iva IN ('Resp. Inscripto', 'Monotributista') THEN 'A' ELSE 'B' END AS factura,
       count(*) FILTER (WHERE length(regexp_replace(cuit, '\D', '', 'g')) = 11)          AS con_cuit,
       count(*) FILTER (WHERE length(regexp_replace(cuit, '\D', '', 'g')) BETWEEN 7 AND 8) AS con_dni,
       count(*) AS total
FROM clientes
GROUP BY 1, 2, 3
ORDER BY 2;
