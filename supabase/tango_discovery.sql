-- Tango schema discovery — run read-only in SSMS against the Tango Gestión SQL Server database.
-- Output feeds the source->target column mapping in TANGO_Migration.md §4.
-- Send back both result sets (CSV export or paste) once you have them.

-- (a) All tables + columns — so we can map source -> target
SELECT c.TABLE_NAME, c.ORDINAL_POSITION, c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH
FROM INFORMATION_SCHEMA.COLUMNS c
JOIN INFORMATION_SCHEMA.TABLES t
  ON t.TABLE_NAME = c.TABLE_NAME AND t.TABLE_TYPE = 'BASE TABLE'
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;

-- (b) Row counts per table — so we spot the tables that actually hold data
SELECT s.name AS schema_name, t.name AS table_name, SUM(p.rows) AS filas
FROM sys.tables t
JOIN sys.schemas s     ON s.schema_id = t.schema_id
JOIN sys.partitions p  ON p.object_id = t.object_id AND p.index_id IN (0,1)
GROUP BY s.name, t.name
HAVING SUM(p.rows) > 0
ORDER BY filas DESC;
