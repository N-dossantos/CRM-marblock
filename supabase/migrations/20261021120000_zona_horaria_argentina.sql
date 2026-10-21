-- La base corría en UTC y las RPCs toman CURRENT_DATE: entre las 21 h y la medianoche de
-- Argentina, recibos, presupuestos, remitos y movimientos salían con la fecha del día siguiente (a
-- fin de mes, en el período siguiente del Libro IVA). Con la zona horaria de Argentina en la base,
-- CURRENT_DATE y los DEFAULT CURRENT_DATE dan la fecha local. Facturas, notas y ARCA ya la
-- calculaban con AT TIME ZONE 'America/Argentina/Buenos_Aires', que da lo mismo con cualquier zona.
--
-- Rige para las conexiones nuevas: las que PostgREST ya tiene abiertas siguen en UTC hasta que el
-- pool las renueva. Los created_at / updated_at de tipo `timestamp` (sin zona) pasan a guardar la
-- hora de Argentina y las filas anteriores quedan en UTC; ni el frontend ni las funciones los leen.
ALTER DATABASE postgres SET timezone TO 'America/Argentina/Buenos_Aires';
