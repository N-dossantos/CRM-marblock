# Migración de Tango → Supabase

Proceso y scripts para llevar los datos de **Tango Gestión (SQL Server 2005)** a Supabase: leer el `.bak`, exportarlo a CSV, verificarlo, transformarlo (ETL) y cargarlo. El plan completo (extracción, decisiones D1–D8, ETL y cutover) está en `PLAN_MIGRACION_TANGO.md`, en la raíz del repo (es un archivo local: no está en git).

El alcance comprende los cuatro módulos del sistema (**Ventas + Compras + Tesorería + Contabilidad**): **57 tablas**. El cutover se hizo el **20/10/2026** con el `.bak` del **16/10/2026 09:00** (251.419 filas); `csv/_manifiesto.txt` registra el archivo, su `sha256` y la fecha del backup.

> [!WARNING]
> **Desde el 20/10/2026 el CRM es el sistema de registro.** `05_cargar.sh` vacía (TRUNCATE) las tablas transaccionales antes de cargar: correrlo contra producción borraría todo lo cargado en el CRM desde el cutover. Sirve para una base de prueba o para repetir la carga en otra base, no para producción.

> [!IMPORTANT]
> **En la máquina vieja no se ejecuta nada.**
> La única entrada es un `.bak` **completo** de la base de Tango, generado con clics desde la interfaz gráfica y copiado en un pendrive. Todo lo demás corre en esta Mac, **sin SQL Server, sin Docker y sin red**: el `.bak` se lee directamente con Python (biblioteca estándar).

---

## Archivos del directorio

| Archivo | Qué hace |
|---|---|
| `bak_reader.py` | Lector del `.bak` de SQL Server 2005: páginas, catálogo y filas. |
| `03_exportar_bak.py` | `.bak` → los 57 CSV en `csv/`, más `_filas_origen.csv` (sale del conteo interno del motor) y `_manifiesto.txt`. |
| `02_verificar_export.py` | **Control de calidad.** Valida la codificación, la cantidad de columnas por registro y los conteos contra el origen antes del ETL. |
| `etl/` | ETL en Python: `python3 -m etl` arma un `.sql` por módulo en `sql/` (`10_maestros`, `20_ventas`, `30_compras`, `31_percepciones_compra`, `40_tesoreria`, `50_contabilidad`) y deja las anomalías en `sql/_anomalias.txt`. Los `test_*.py` son sus tests. |
| `05_cargar.sh` | Carga los `.sql` de `sql/` en una sola transacción (TRUNCATE + COPY) y muestra los conteos. Ver la advertencia de arriba. |
| `sql_conteos.sql` | Conteos esperados por tabla después de la carga (los usa `05_cargar.sh`). |
| `sql_reset_secuencias.sql` | Reubica las secuencias después de la carga (lo usa `05_cargar.sh`). |
| `test_bak_reader.py` · `test_exportar_bak.py` | Tests del lector y del exportador. |
| `tablas.txt` | Lista plana de las 57 tablas a exportar (la leen los scripts). |
| `tablas.tsv` | Manifiesto de mapeo: tabla, módulo, columnas, filas medidas el 21/08, tabla destino y observaciones (documentación). |
| `esquema_tango.tsv` | Definición de las 1.415 columnas, con tipo y longitud. |
| `csv/` · `sql/` | Salidas del export y del ETL. **Datos reales: ignorados por git.** |

No hay `01_` ni `04_`: los `01_*` eran del método por SQL Server que se abandonó (ver `PLAN_MIGRACION_TANGO.md`), y el paso 4 es el ETL (`etl/`).

---

## Extracción: `.bak` leído directo en la Mac

1. **Generar el backup en la máquina vieja, con clics:**
   - En SQL Server Management Studio (SSMS), en el *Object Explorer*: **clic derecho sobre la base de Tango** → **Tasks** (*Tareas*) → **Back Up...** (*Copia de seguridad...*).
   - En **Backup type**, dejar **Full** (*Completa*).
   - En **Destination** (*Destino*), elegir la ruta del archivo (por ejemplo `C:\tango.bak` o el pendrive). Si hay una ruta anterior, pulsar *Remove* y después *Add* para elegir la nueva.
   - **No marcar "Compress backup"**: SQL Server Express 2005 no comprime, y un backup comprimido no se podría leer.
   - Pulsar **OK**.

   *(Alternativa desde Tango Gestión: Administrador General → Empresas → clic derecho en la empresa → Copias de Seguridad.)*

2. **Copiar el `.bak` a esta Mac** con un pendrive. Los `*.bak` están ignorados por git.

3. **Leer el `.bak` directamente en la Mac (sin SQL Server ni Docker):**
   ```bash
   python3 supabase/tango/03_exportar_bak.py RUTA/AL/ARCHIVO.bak
   python3 supabase/tango/02_verificar_export.py
   ```
   Tango corre sobre SQL Server 2005, y ningún SQL Server moderno (2016+, Azure SQL Edge) restaura backups de 2005; por eso el `.bak` se decodifica con `bak_reader.py`. El lector sólo acepta la versión de base 611 (SQL Server 2005): con cualquier otra corta con `BakError`, nunca lee a medias.

---

## Verificación de integridad

Una vez que los archivos estén en `supabase/tango/csv/`, correr en esta Mac:

```bash
python3 supabase/tango/02_verificar_export.py
```

El script valida:
1. Que cada una de las 57 tablas tenga su archivo.
2. Que cada registro tenga exactamente la cantidad de columnas de [`esquema_tango.tsv`](esquema_tango.tsv).
3. Que el total de registros exportados coincida exactamente con el origen (`_filas_origen.csv`).

> [!CAUTION]
> **Si el verificador reporta discrepancias o errores de estructura, NO seguir con la carga a Supabase.**

---

## Decisiones de formato

- **Separador `|~|`:** evita choques con las comas de razones sociales y domicilios.
- **Terminador `@#@\n`:** protege los saltos de línea dentro de campos de texto multilínea (observaciones en `SBA04`, `SBA15`, `CUENTA`).
- **Valores canónicos:** `NULL` se exporta como campo vacío, los booleanos como `0`/`1`, las fechas en ISO `YYYY-MM-DD HH:MM:SS.mmm` y los decimales con punto (`.`).

---

## ETL y carga

Desde `supabase/tango/`, con los CSV ya verificados:

```bash
python3 -m unittest discover -s etl -t .        # tests del ETL
python3 -m etl                                  # genera sql/*.sql y sql/_anomalias.txt
export SUPABASE_DB_URL="$(cat ../../.db_url)"   # connection string DIRECTO (usuario postgres), gitignoreado
./05_cargar.sh --conteos                        # sólo muestra los conteos actuales
./05_cargar.sh                                  # vacía y carga (¡no contra producción!, ver arriba)
```

Después de una carga, controlar con `supabase/POST_LOAD_VERIFY.sql` (psql) o `POST_LOAD_VERIFY_MCP.sql` (MCP / SQL Editor).

---

## Decisiones clave para la carga a Supabase (ETL)

1. **Ítems de facturas de compra:** salen de `CPA47` (conceptos), enganchados con `materiales` sembrados desde `CPA45`.
2. **Catálogo de productos:** se conservan los 25 productos sembrados. `STA11`/`STA36`/`GVA17` no sobrescriben `productos`: sólo aportan la descripción y el precio histórico de los renglones de venta.
3. **Imputación contable:** los ~51.100 renglones de asientos históricos de `ASIENTO_GV` / `ASIENTO_CP` / `ASIENTO_SB` dan la matriz de imputación real para la migración.
4. **Remitos ↔ facturas (26/10/2026):** `remito_item_facturas` sale de `GVA54`, que reparte cada renglón de remito entre una o varias facturas (14.850 asignaciones). Antes se copiaba `remitos.factura_id` 1 a 1 y quedaban como pendientes de remitir facturas ya entregadas. En producción se corrigió con una recarga puntual el 26/10; el ETL ya lo genera así.
