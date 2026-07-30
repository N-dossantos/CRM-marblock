# CRM Pro — Módulo de Ventas

Sistema moderno de gestión comercial y control de ventas para pequeñas y medianas empresas.

## 🚀 Tecnologías (Stack)

- **Frontend:** React + Vite
- **Backend / Database:** Supabase (PostgreSQL + Auth + RLS + Edge Functions)
- **Generación de PDFs:** Supabase Edge Functions (`pdfkit`)
- **Estilos & UI:** Vanilla CSS con diseño adaptativo, interfaz limpia y componentes reactivos.

---

## ⚡ Características y Funcionalidades

| Módulo | Funcionalidades Principales |
|--------|-----------------------------|
| **Dashboard** | Visión general con KPIs principales, últimas facturas, ranking de deudores y accesos rápidos. |
| **Clientes** | Gestión de clientes (ABM), asignación de descuentos predefinidos y control de saldo acumulado. |
| **Productos** | Catálogo de productos (ABM) con función de actualización masiva de precios por porcentaje. |
| **Presupuestos** | Emisión de presupuestos con validez configurable (7 días), alertas de vencimiento y conversión a remito o factura. |
| **Remitos** | Creación de remitos independientes o vinculados a presupuestos, con opción de conversión a factura. |
| **Facturas (A/B)** | Numeración y puntos de venta automáticos, aplicación de IVA 21% y vinculación directa con remitos y presupuestos. |
| **Notas de Crédito y Débito** | Emisión de notas vinculadas a facturas con recalculo automático de estado y saldos. |
| **Recibos y Cobranzas** | Gestión de cobros multi-medio (Efectivo, Transferencia, Cheque físico, E-Cheq) e imputación a facturas. |
| **Cuenta Corriente** | Historial detallado de movimientos por cliente, saldo acumulado y filtros por fechas. |
| **Cartera de Cheques** | Control de cheques físicos y e-cheqs, estados (en cartera, depositado, entregado) y vencimientos. |
| **Informes y Reportes** | Reportes de ventas por período, ranking de clientes, ranking de deudores y pendientes de cobro/facturación. |
| **Documentos PDF** | Generación y descarga en tiempo real de comprobantes y reportes en formato PDF. |

---

## 🔒 Arquitectura y Seguridad

- **Supabase Direct Client:** El frontend interactúa directamente con Supabase mediante `@supabase/supabase-js`, utilizando PostgREST para consultas simples y RPCs (funciones almacenadas) para operaciones atómicas.
- **Row Level Security (RLS):** La seguridad está garantizada a nivel de base de datos. Solo los usuarios autenticados del equipo (*staff*) tienen acceso a la lectura y creación de datos.
- **Transacciones Atómicas (RPCs):** El cálculo de totales, numeración atómica e impuestos se efectúan en el servidor PostgreSQL para evitar manipulación del lado del cliente.

---

## 🛠️ Instalación y Desarrollo Local

### Pre-requisitos
- Node.js (versión 18 o superior)
- Un proyecto en [Supabase](https://supabase.com) con el esquema y funciones aplicados.

### Pasos para iniciar el frontend:

1. **Clonar e instalar dependencias:**
   ```bash
   cd frontend
   npm install
   ```

2. **Configurar variables de entorno:**
   Copia el archivo `.env.example` a `.env`:
   ```bash
   cp .env.example .env
   ```
   Configura tus credenciales de Supabase en `.env`:
   ```env
   VITE_SUPABASE_URL=https://<TU-PROYECTO>.supabase.co
   VITE_SUPABASE_ANON_KEY=<TU_CLAVE_ANON_PUBLICA>
   ```

3. **Ejecutar el servidor de desarrollo:**
   ```bash
   npm run dev
   ```
   Abre [http://localhost:5173](http://localhost:5173) en tu navegador.

4. **Compilar para producción:**
   ```bash
   npm run build
   ```
   Los archivos estáticos generados en `dist/` se pueden desplegar en cualquier plataforma de hosting (Vercel, Netlify, Cloudflare Pages, etc.).

---

## 📁 Estructura del Proyecto

```
crm-ventas/
├── frontend/                   # Aplicación Frontend React
│   ├── src/
│   │   ├── api/                # Conexiones PostgREST y RPCs con Supabase
│   │   ├── lib/                # Configuración de Supabase y Auth Context
│   │   ├── components/         # Componentes UI, tablas, modales y formularios
│   │   ├── views/              # Vistas principales (Dashboard, Ventas, Clientes, etc.)
│   │   └── utils/              # Helpers y utilidades de formateo
│   ├── index.html
│   └── vite.config.js
└── supabase/                   # Migraciones y Edge Functions
    ├── migrations/             # Scripts SQL de esquema, RLS y RPCs
    └── functions/              # Edge Function para la generación de PDFs
```

---

## 📄 Licencia

Privado / Propiedad de la empresa.
