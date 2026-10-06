# Export de Tango → CSV (Fase 7, paso 4)

Proceso y scripts para extraer los datos de **Tango Gestión (SQL Server)** y verificar su integridad antes de cargar a Supabase. El plan completo (extracción, decisiones D1–D8, ETL y cutover) está en [`PLAN_MIGRACION_TANGO.md`](../../PLAN_MIGRACION_TANGO.md), en la raíz del repo.

El alcance comprende los cuatro módulos del sistema (**Ventas + Compras + Tesorería + Contabilidad**): **57 tablas, 250.678 filas** en el `.bak` del 25/09/2026.

> [!IMPORTANT]
> **En la máquina vieja no se ejecuta nada.**
> La única entrada es un `.bak` **completo** de la base de Tango, generado con clics desde la interfaz gráfica y copiado en un pendrive. Todo lo demás corre en esta Mac, **sin SQL Server, sin Docker y sin red**: el `.bak` se lee directamente con Python (biblioteca estándar).

---

## Archivos del directorio

| Archivo | Qué hace |
|---|---|
| `bak_reader.py` | Lector del `.bak` de SQL Server 2005: páginas, catálogo y filas. *(Se crea en la Tarea 1 del plan.)* |
| `03_exportar_bak.py` | `.bak` → los 57 CSV en `csv/`, más `_filas_origen.csv` (sale del conteo interno del motor) y `_manifiesto.txt`. *(Se crea en la Tarea 2 del plan.)* |
| `02_verificar_export.py` | **Control de calidad.** Valida la codificación, la cantidad de columnas por registro y los conteos contra el origen antes del ETL. |
| `tablas.txt` | Lista plana de las 57 tablas a exportar. |
| `tablas.tsv` | Manifiesto de mapeo: tabla, módulo, columnas, filas estimadas, tabla destino y observaciones. |
| `esquema_tango.tsv` | Definición de las 1.415 columnas, con tipo y longitud. |

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

## Decisiones clave para la carga a Supabase (ETL)

1. **Ítems de facturas de compra:** salen de `CPA47` (conceptos), enganchados con `materiales` sembrados desde `CPA45`.
2. **Catálogo de productos:** se conservan los 25 productos sembrados. `STA11`/`STA36`/`GVA17` no sobrescriben `productos`: sólo aportan la descripción y el precio histórico de los renglones de venta.
3. **Imputación contable:** los ~51.100 renglones de asientos históricos de `ASIENTO_GV` / `ASIENTO_CP` / `ASIENTO_SB` dan la matriz de imputación real para la migración.
