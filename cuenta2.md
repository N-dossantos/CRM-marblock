# Plan de Especificación Técnica e Implementación: Módulo "Cuenta 2" (Ventas y Compras)

## 1. Resumen Ejecutivo y Requerimientos Confirmados

Basado en las respuestas del usuario, la sección **"Cuenta 2"** funcionará como un circuito informal/no fiscal ("en negro", sin impuestos / sin IVA), paralelo pero completamente aislado del circuito fiscal oficial ("Cuenta 1").

### Principios Fundamentales:
1. **Entidades Independientes**: Clientes y Proveedores de Cuenta 2 viven en tablas separadas (`clientes_cuenta2`, `proveedores_cuenta2`) con una estructura simplificada (Nombre, Descuento %, Teléfono/Notas).
2. **Cta. Cte. Aislada**: El saldo de Cta. Cte. Cuenta 2 no afecta ni se mezcla con la Cta. Cte. oficial de Cuenta 1.
3. **Comprobante Único (Remito X)**:
   - Es el único comprobante de venta y compra en esta sección.
   - No tiene autonumeración estricta ni punto de venta fiscal; el número de remito se ingresa manualmente en cada carga (texto libre, ej: `"12345"`).
   - Precios 100% netos sin impuestos / sin IVA.
   - Comparte el mismo catálogo de productos (`productos`) con los mismos precios de lista bases, aplicando el descuento del cliente/proveedor.
4. **Sin Impacto en Stock**: No descuenta ni suma inventario (actualmente el sistema no realiza control de stock).
5. **Cobros y Pagos Simplificados**:
   - No se emiten comprobantes de Recibos u Órdenes de Pago.
   - El cobro/pago impacta de forma directa e inmediata el saldo de Cta. Cte. (Debe / Haber).
   - Formas de pago: **Efectivo**, **Transferencia** o **Cheque**.
6. **Tesorería y Cartera de Cheques**:
   - No afecta las cajas ni cuentas bancarias oficiales de Cuenta 1.
   - Los cheques cobrados/pagados en Cuenta 2 van a una **Cartera de Cheques Cuenta 2**.
   - **Funcionalidad clave**: Los cheques en la Cartera Cuenta 2 se pueden editar y transferir libremente a la **Cartera de Cheques Oficial (Cuenta 1)**.
7. **Accesibilidad e Informes**:
   - Todos los usuarios del sistema tienen acceso a la sección Cuenta 2.
   - Informes básicos: Estado de Cta. Cte. (Historial de movimientos Debe / Haber / Saldo por Cliente o Proveedor).

---

## 2. Arquitectura de Base de Datos (Supabase Postgres)

Se creará una nueva migración SQL: `supabase/migrations/20260815120000_cuenta2_schema.sql`.

### 2.1 Tablas Principales

```sql
-- 1. Clientes Cuenta 2
CREATE TABLE public.clientes_cuenta2 (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre TEXT NOT NULL,
    descuento NUMERIC(5,2) NOT NULL DEFAULT 0.00,
    telefono TEXT,
    observaciones TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Proveedores Cuenta 2
CREATE TABLE public.proveedores_cuenta2 (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre TEXT NOT NULL,
    descuento NUMERIC(5,2) NOT NULL DEFAULT 0.00,
    telefono TEXT,
    observaciones TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3. Remitos X (Ventas y Compras)
CREATE TABLE public.cuenta2_remitos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tipo_sector TEXT NOT NULL CHECK (tipo_sector IN ('venta', 'compra')),
    cliente_id UUID REFERENCES public.clientes_cuenta2(id) ON DELETE SET NULL,
    proveedor_id UUID REFERENCES public.proveedores_cuenta2(id) ON DELETE SET NULL,
    numero_remito TEXT NOT NULL, -- Carga manual (ej. "12345")
    fecha DATE NOT NULL DEFAULT CURRENT_DATE,
    descuento_aplicado NUMERIC(5,2) NOT NULL DEFAULT 0.00,
    total NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    observaciones TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. Ítems del Remito X
CREATE TABLE public.cuenta2_remito_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    remito_id UUID NOT NULL REFERENCES public.cuenta2_remitos(id) ON DELETE CASCADE,
    producto_id UUID REFERENCES public.productos(id) ON DELETE SET NULL,
    codigo TEXT,
    descripcion TEXT NOT NULL,
    cantidad NUMERIC(12,3) NOT NULL DEFAULT 1.000,
    precio_unitario NUMERIC(15,2) NOT NULL DEFAULT 0.00, -- Sin IVA
    subtotal NUMERIC(15,2) NOT NULL DEFAULT 0.00
);

-- 5. Cuenta Corriente (Ventas y Compras Cuenta 2)
CREATE TABLE public.cuenta2_ctacte (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tipo_sector TEXT NOT NULL CHECK (tipo_sector IN ('venta', 'compra')),
    cliente_id UUID REFERENCES public.clientes_cuenta2(id) ON DELETE CASCADE,
    proveedor_id UUID REFERENCES public.proveedores_cuenta2(id) ON DELETE CASCADE,
    fecha DATE NOT NULL DEFAULT CURRENT_DATE,
    tipo_movimiento TEXT NOT NULL CHECK (tipo_movimiento IN ('REMITO_X', 'COBRO', 'PAGO', 'AJUSTE')),
    remito_id UUID REFERENCES public.cuenta2_remitos(id) ON DELETE SET NULL,
    concepto TEXT NOT NULL,
    debe NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    haber NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    saldo_resultante NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 6. Cartera de Cheques Cuenta 2
CREATE TABLE public.cuenta2_cheques (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    banco TEXT NOT NULL,
    numero TEXT NOT NULL,
    monto NUMERIC(15,2) NOT NULL DEFAULT 0.00,
    fecha_emision DATE,
    fecha_cobro DATE NOT NULL,
    cuit_emisor TEXT,
    librador TEXT,
    origen_tipo TEXT CHECK (origen_tipo IN ('cliente', 'proveedor')),
    cliente_id UUID REFERENCES public.clientes_cuenta2(id) ON DELETE SET NULL,
    proveedor_id UUID REFERENCES public.proveedores_cuenta2(id) ON DELETE SET NULL,
    estado TEXT NOT NULL DEFAULT 'en_cartera' CHECK (estado IN ('en_cartera', 'depositado', 'entregado', 'transferido_cuenta1', 'anulado')),
    cheque_cuenta1_id UUID REFERENCES public.cheques(id) ON DELETE SET NULL, -- Enlace al cheque creado en Cuenta 1 al transferirse
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

### 2.2 Seguridad (RLS) y RPCs `SECURITY DEFINER`

- **Políticas RLS**: Mismo patrón del sistema (`authenticated` con acceso total, `anon` sin acceso).
- **RPC 1: `crear_remito_cuenta2`**:
  - Parámetros: `p_tipo_sector`, `p_entidad_id`, `p_numero_remito`, `p_fecha`, `p_descuento`, `p_observaciones`, `p_items` (jsonb).
  - Acción: Inserta cabecera y N ítems en `cuenta2_remitos` y `cuenta2_remito_items`.
  - Actualización Cta. Cte.: Inserta en `cuenta2_ctacte` actualizando el saldo acumulado.
- **RPC 2: `registrar_movimiento_ctacte_cuenta2`**:
  - Parámetros: `p_tipo_sector`, `p_entidad_id`, `p_fecha`, `p_concepto`, `p_debe`, `p_haber`, `p_medio_pago`, `p_cheque_data` (jsonb opcional).
  - Acción:
    - Inserta movimiento en `cuenta2_ctacte` recalculando el saldo.
    - Si el medio de pago es cheque, inserta el registro correspondiente en `cuenta2_cheques`.
- **RPC 3: `transferir_cheque_c2_a_c1`**:
  - Parámetros: `p_cuenta2_cheque_id`, `p_datos_cheque` (jsonb con posibles ediciones de banco, número, monto, etc.).
  - Acción:
    - Inserta un nuevo registro en la tabla general `cheques` (Cartera de terceros de Cuenta 1).
    - Marca el registro en `cuenta2_cheques` como `estado = 'transferido_cuenta1'` y guarda la relación `cheque_cuenta1_id`.

---

## 3. Especificación del Frontend (React + Vite)

### 3.1 Estructura de Navegación y Rutas

Se agregarán dos nuevos módulos navegables en el Sidebar principal:

1. **Ventas -> Cuenta 2** (`/ventas/cuenta2`)
2. **Compras -> Cuenta 2** (`/compras/cuenta2`)
3. **Tesorería / Cheques -> Cheques Cuenta 2** (Solapa dentro de Cheques o subsección)

```
src/
├── api/
│   └── cuenta2.js              # Capa de llamadas Supabase RPC / PostgREST
├── views/
│   ├── VentasCuenta2/
│   │   ├── index.jsx           # Vista principal con Tabs (Remitos X, Clientes, Cta Cte)
│   │   ├── RemitoXForm.jsx     # Formulario de emisión de Remito X (número manual, catálogo productos)
│   │   ├── ClientesC2Modal.jsx # ABM rápido de clientes C2
│   │   └── CobroC2Modal.jsx    # Modal de cobro directo (Efectivo / Transferencia / Cheque)
│   ├── ComprasCuenta2/
│   │   ├── index.jsx           # Vista principal con Tabs (Remitos X, Proveedores, Cta Cte)
│   │   ├── RemitoXCompraForm.jsx # Formulario de ingreso de Remito X de proveedor
│   │   ├── ProveedoresC2Modal.jsx # ABM rápido de proveedores C2
│   │   └── PagoC2Modal.jsx     # Modal de pago directo
│   └── Cheques/
│       └── ChequesCuenta2Tab.jsx # Cartera de Cheques C2 con botón "Transferir a Cuenta 1"
```

---

## 4. Plan de Implementación Paso a Paso

### Fase 1: Base de Datos y API (`supabase/`)
- [ ] Crear el script de migración `supabase/migrations/20260815120000_cuenta2_schema.sql`.
- [ ] Implementar RLS `staff_all` para las 6 nuevas tablas.
- [ ] Escribir las RPCs `SECURITY DEFINER`:
  - `crear_remito_cuenta2`
  - `registrar_movimiento_ctacte_cuenta2`
  - `transferir_cheque_c2_a_c1`
  - `get_resumen_ctacte_cuenta2`
- [ ] Aplicar migraciones en Supabase.

### Fase 2: Capa API Frontend (`frontend/src/api/cuenta2.js`)
- [ ] Crear el módulo de llamadas en JS para interactuar con las RPCs y tablas de `cuenta2`.

### Fase 3: Módulo Ventas -> Cuenta 2
- [ ] Desarrollar la vista `/ventas/cuenta2`.
- [ ] Componente `ClientesC2`: Alta, baja, modificación de clientes de Cuenta 2 (con % de descuento por defecto).
- [ ] Componente `RemitoXForm`: Formulario para emitir Remito X con número de 5 dígitos ingresado a mano, buscador de productos, precio neto y descuento.
- [ ] Componente `CtaCteClientesC2`: Visualización de saldo, historial de movimientos Debe/Haber y modal de registro de cobros (Efectivo/Transferencia/Cheque).

### Fase 4: Módulo Compras -> Cuenta 2
- [ ] Desarrollar la vista `/compras/cuenta2`.
- [ ] Componente `ProveedoresC2`: ABM de proveedores C2.
- [ ] Componente `RemitoXCompraForm`: Carga de Remitos X recibidos de proveedores.
- [ ] Componente `CtaCteProveedoresC2`: Visualización de saldo e historial de pagos.

### Fase 5: Cartera de Cheques Cuenta 2 y Migración a Cuenta 1
- [ ] Crear la solapa "Cheques Cuenta 2" en el módulo de Cartera de Cheques.
- [ ] Implementar el modal de **Edición y Transferencia a Cartera Cuenta 1**, ejecutando la RPC que vincula y traslada el cheque a la cartera oficial.

### Fase 6: Pruebas y Verificación
- [ ] Probar flujo completo de Venta Cuenta 2 (Cliente C2 -> Remito X -> Cta Cte -> Cobro con Cheque).
- [ ] Probar transferencia del cheque de Cartera C2 a Cartera C1.
- [ ] Probar flujo completo de Compra Cuenta 2.
- [ ] Verificar que no exista contaminación de saldos o datos con la Cuenta 1 (Oficial).

---

## 5. Verificación y Criterios de Aceptación

1. **Aislamiento**: Ninguna operación de Cuenta 2 modifica las tablas `clientes`, `proveedores`, `facturas`, `remitos` o `movimientos_ctacte` de Cuenta 1.
2. **Numeración**: El número de Remito X se puede ingresar como texto libre en cada emisión sin bloquearse por secuencias automáticas.
3. **Cta Cte**: El registro de Remitos X incrementa el Debe/Haber y los cobros/pagos lo acreditan/debitan de inmediato.
4. **Cheques**: Un cheque ingresado en Cuenta 2 se visualiza en la cartera C2 y puede ser migrado exitosamente a la cartera general de Cuenta 1 mediante el botón de transferencia.
