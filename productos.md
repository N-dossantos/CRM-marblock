# Especificación y Configuración de Productos: Bloques, Adoquines, Pallets y Flete

Este documento contiene la especificación funcional, técnica, la planilla para completar los 23 productos de Marblock y el prompt para la posterior implementación en el sistema ERP/CRM (`crm-tango`).

---

## 1. Resumen de Requerimientos Confirmados

1. **Catálogo de Productos**:
   - **23 Productos principales**: Bloques y Adoquines.
   - **IDs Cortos y Únicos**: Acceso rápido mediante números enteros simples (`1`, `2`, `3`, ..., `23`).
   - **Búsqueda Agilizada**: Permite seleccionar el producto escribiendo únicamente su ID numérico (ej: `1`) o escribiendo parte de su nombre/descripción (autocompletado).
   - **Venta por Pallets**: Cada producto tiene definida una cantidad fija de **unidades por pallet** (`unidades_por_pallet`).
   - **Sin Decimales**: Todas las cantidades de pallets y unidades deben ser **números enteros** (`INTEGER`).
   - **Precios Base**: El precio de lista se mantiene guardado **por unidad** (sin IVA). Al ingresar `X` pallets en un comprobante, el sistema calcula:
     $$\text{Unidades Totales} = \text{Pallets} \times \text{Unidades por Pallet}$$
     $$\text{Subtotal} = \text{Unidades Totales} \times \text{Precio Unitario}$$

2. **Ítem Especial: Pallets Vacíos de Madera (ID: 24)**:
   - **Producto especial**: `"Pallet de Madera Vacío"`.
   - **Precio Unitario**: `$4.000` (sin IVA).
   - **Vínculo Automático**: Al agregar productos (Bloques/Adoquines) a un presupuesto o factura, el sistema calcula la suma total de pallets requeridos:
     $$\text{Total Pallets Madera} = \sum \text{Pallets de Productos (1 a 23)}$$
   - **Edición Libre**: Se agrega automáticamente como una línea de ítem independiente, pero **es editable** (el usuario puede modificar la cantidad de pallets de madera o quitar la línea antes de confirmar el comprobante).

3. **Ítem Especial: Servicio de Transporte / Flete (ID: 25)**:
   - **Producto especial**: `"Servicio de Transporte"`.
   - **Precio Base de Lista**: `$300.000` por viaje.
   - **Cantidad**: Número entero (ej: `1` viaje, `2` viajes).
   - **Precio Variable**: El valor unitario de la tarifa es editable manualmente en cada presupuesto/factura según la distancia del viaje.

---

## 2. Planilla de Configuración de Productos (23 Productos + 2 Especiales)

A continuación se presenta la tabla para completar con los datos reales de los 23 productos.

> **Instrucciones**: Completar las columnas `Descripción`, `Unidades por Pallet` y `Precio Unitario sin IVA ($)`.

| ID | Código | Descripción del Producto | Unidades por Pallet | Precio Unitario s/IVA ($) | Categoría |
|---|---|---|:---:|:---:|---|
| **1** | `1` | Bloque Liso de 19x19x39 Portante | 105 | **$1572.08** | Bloque |
| **2** | `2` | Bloque Medio de 19x19x19 Liso | 180 | **$1169.76** | Bloque |
| **3** | `3` | Bloque Dintel de 19x19x39 Liso | 105 | **$2025.32** | Bloque |
| **4** | `4` | Bloque Liso de 19x19x39 Estandar | 105 | **$1405.41** | Bloque |
| **5** | `5` | Bloque Media Altura de 19x9,5x39 Liso | 150 | **$837.13** | Bloque |
| **6** | `6` | Bloque Liso de 14x19x39 Portante | 150 | **$1237.13** | Bloque |
| **7** | `7` | Bloque Medio de 14x19x19 Liso | 252 | **$919.45** | Bloque |
| **8** | `8` | Bloque Dintel de 14x19x39 Liso | 150 | **$1524.90** | Bloque |
| **9** | `9` | Bloque Liso de 14x19x39 Estandar | 150 | **$1112.96** | Bloque |
| **10** | `10` | Bloque Liso de 9x19x39  | 210 | **$1146.91** | Bloque |
| **11** | `11` | Bloque de 19x19x39 Split | 105 | **$2697.25** | Bloque |
| **12** | `12` | Bloque de 19x19x39 Split Esquinero | 105 | **$3096.75** | Bloque |
| **13** | `13` | Bloque Dintel de 19x19x39 Split | 105 | **$3096.75** | Bloque |
| **14** | `14` | Bloque Medio de 19x19x39 Split | 180 | **$1622.72** | Bloque |
| **15** | `15` | Bloque Medio de 19x19x39 Split Esquinero | 180 | **$1840.96** | Bloque |
| **16** | `16` | Bloque de 14x19x39 Split | 150 | **$2472.48** | Bloque |
| **17** | `17` | Plaqueta de 7x19x39 Split | 216 | **$2065.97** | Plaqueta |
| **18** | `18` | Adoquin Inter-trabado de 11x21x8 | 528 | **$537.82** | Adoquín |
| **19** | `19` | Adoquin Inter-trabado de 11x21x6 | 624 | **$413.70** | Adoquín |
| **20** | `20` | Adoquin Holanda de 10x20x8 | 600 | **$439.71** | Adoquín |
| **21** | `21` | Adoquin Holanda de 10x20x6 | 720 | **$353.05** | Adoquín |
| **22** | `22` | Cubremuros 26x19x4,5 | 256 | **$1154.50** | Cubremuros |
| **23** | `23` | Cordon 28x13x50 | 56 | **$11020.73** | Cordon |
| **24** | `24` | **Pallet** | 1 | **$4000** | Pallets |
| **25** | `25` | **Servicio de Transporte** | 1 | **$300000** | Transporte |

---

## 3. Especificación Técnica de Base de Datos y UI

### 3.1 Base de Datos (Supabase Postgres)

1. **Modificación en la tabla `productos`**:
   ```sql
   ALTER TABLE public.productos 
   ADD COLUMN IF NOT EXISTS unidades_por_pallet INTEGER NOT NULL DEFAULT 1,
   ADD COLUMN IF NOT EXISTS es_pallet_vacio BOOLEAN NOT NULL DEFAULT FALSE,
   ADD COLUMN IF NOT EXISTS es_transporte BOOLEAN NOT NULL DEFAULT FALSE;
   ```

2. **Columnas del comprobante (`presupuestos_items`, `facturas_items`, `remitos_items`, `cuenta2_remitos_items`)**:
   - `cantidad`: Se guarda la **cantidad total de unidades** (`INTEGER`).
   - `pallets`: Se guarda la cantidad de **pallets ingresados** (`INTEGER`).
   - `unidades_por_pallet`: Se copia de la ficha del producto al momento de guardar.

### 3.2 Interfaz de Usuario (Carga de Comprobantes)

1. **Buscador de Productos (Dropdown / Autocompletado)**:
   - Muestra primero el ID en negrita y la descripción: `[1] Bloque Hueco 8x18x33 (198 un/pallet)`.
   - Permite escribir `1` para seleccionar inmediatamente el Producto 1.
   - Permite escribir `"Holandés"` para filtrar los adoquines.

2. **Entrada de Cantidad en la Grilla de Ítems**:
   - Campo principal: **Pallets** (ej: `5`).
   - Campo informativo/calculado: **Unidades totales** (ej: `990 un`).
   - Todos los inputs fuerzan valor entero (`step="1"`).

3. **Cálculo Automático de Pallets Vacíos**:
   - Al agregar o modificar ítems de productos que tengan `unidades_por_pallet > 1`, el sistema suma los pallets totales de la orden.
   - Si no existe la línea del ítem `ID: 24` ("Pallet de Madera Vacío"), la crea automáticamente con `cantidad = total_pallets` y `precio_unitario = 4000`.
   - Si el usuario modifica manualmente la cantidad del ítem 24 o lo elimina, el sistema respeta el valor editado antes de guardar.

4. **Ítem Servicio de Transporte**:
   - Al seleccionar el producto `ID: 25`, el campo de precio inicializa en `$300.000`, pero se mantiene 100% editable.

---

## 4. Prompt para Implementación Futura

Para aplicar estos cambios en el código del sistema, copiar y ejecutar el siguiente prompt:

```text
PROMPT DE IMPLEMENTACIÓN: Configuración de Productos por Pallets, Búsqueda Rápida y Pallets Vacíos

Por favor implementa los cambios del catálogo de productos y carga por pallets según las especificaciones del archivo productos.md:

1. BASE DE DATOS (Supabase SQL):
   - Crea una migración en supabase/migrations/ para agregar los campos a la tabla public.productos:
     - unidades_por_pallet (INTEGER, default 1)
     - es_pallet_vacio (BOOLEAN, default false)
     - es_transporte (BOOLEAN, default false)
   - Agrega los campos `pallets` (INTEGER) a las tablas de ítems de comprobantes (presupuestos_items, facturas_items, remitos_items, cuenta2_remitos_items).
   - Genera una migración de Seed/Update para registrar o actualizar los 23 productos con sus IDs numéricos simples ('1', '2', ..., '23'), más el ID '24' (Pallet de Madera Vacío, $4000, es_pallet_vacio = true) y el ID '25' (Servicio de Transporte, $300000, es_transporte = true).

2. COMPONENTES FRONTEND (React):
   - Modifica el componente de búsqueda de productos (Selector / Select / Autocomplete en ComprobanteForm y RemitoXForm):
     - Permite buscar instantáneamente tipeando el ID corto ('1', '2', etc.) o texto libre de la descripción.
     - Muestra en las opciones del desplegable: "[ID] Descripción (X un/pallet)".
   - Modifica la grilla de ItemsTable / ComprobanteForm:
     - Permite ingresar la cantidad en número de PALLETS (entero).
     - Calcula y muestra las unidades totales (Pallets * Unidades por Pallet) y el Subtotal.
     - Fuerza que todas las cantidades sean números enteros (no floats).
   - Lógica automática de Pallets de Madera:
     - Implementa un hook / useEffect que sume la cantidad total de pallets de la grilla.
     - Agrega o actualiza automáticamente el ítem "Pallet de Madera Vacío" (ID 24) a $4000 con la cantidad correspondiente de pallets sumados.
     - Permite que el usuario pueda editar manualmente la cantidad o precio de los pallets vacíos o eliminar la línea antes de guardar el comprobante.
   - Ítem de Transporte (ID 25):
     - Al seleccionarlo, carga $300.000 como precio sugerido pero permite editar libremente el importe según la distancia del viaje.

3. VISTAS DE PRODUCTOS:
   - Actualiza la vista src/views/Productos/index.jsx para incluir la columna "Unidades por Pallet" y permitir su edición en el modal de producto.
```
