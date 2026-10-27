# CRM Marblock

Sistema de gestión de Marblock: ventas, compras, tesorería, contabilidad y facturación electrónica
contra ARCA. Desde el 20/10/2026 es el sistema de registro de la empresa: reemplazó a Tango Gestión,
cuyos datos históricos se migraron desde un backup (`supabase/tango/`).

## 🚀 Tecnologías (Stack)

- **Frontend:** React 18 + Vite, desplegado en Vercel.
- **Backend / Base de datos:** Supabase (PostgreSQL + Auth + RLS + Edge Functions). No hay servidor
  propio: el frontend habla directo con Supabase.
- **PDF:** Edge Function `pdf` (`pdfkit`), con comprobantes, PDF fiscal con CAE y QR, remito sobre
  talonario preimpreso y reportes.
- **Facturación electrónica:** Edge Function `arca`, contra los web services WSAA + WSFEv1 de ARCA.
- **Estilos:** CSS propio, con tema claro/oscuro, tamaño de letra configurable y diseño adaptable a
  celulares.

---

## ⚡ Módulos

| Módulo | Qué incluye |
|--------|-------------|
| **Dashboard** | KPIs, últimas facturas, ranking de deudores y el Calendario (eventos por fecha, con título y descripción). |
| **Ventas** | Clientes y productos (catálogo por pallets), presupuestos (a nombre de cualquier destinatario), remitos (sobre talonario preimpreso, contra las facturas pendientes de remitir), facturas A/B con IVA multi-alícuota y percepciones, notas de crédito y débito, recibos multi-medio (efectivo, transferencia, cheque, e-cheq) con retenciones sufridas, cuenta corriente y cartera de cheques. |
| **Facturación electrónica (ARCA)** | Facturas y notas A/B emitidas con CAE desde el sistema (PV `00003`), bandeja fiscal, recuperación ante errores o respuestas inciertas, y PDF fiscal. |
| **Compras** | Proveedores, materiales, facturas, remitos y notas de compra (con percepciones), pagos a proveedores y cuenta corriente. |
| **Tesorería** | Cuentas y cajas, movimientos y transferencias, cheques propios, depósitos y rechazos de cheques de terceros, y conciliación bancaria. |
| **Contabilidad** | Plan de cuentas, asientos manuales, libro diario, mayor, sumas y saldos. |
| **Consultas 360°** | Vista completa por cliente, proveedor o cuenta. |
| **Cuenta 2** | Circuito paralelo de ventas y compras, con su propia cartera de cheques y transferencia de cheques a Cuenta 1. |
| **Informes** | Ventas, rankings, pendientes de cobro, de facturar y de remitir, libros de IVA, subdiario, retenciones, informes de tesorería; exportación a Excel y PDF. |

---

## 🔒 Arquitectura y seguridad

- **Cliente directo a Supabase:** el frontend usa `@supabase/supabase-js`; las consultas simples van
  por PostgREST y las operaciones de comprobantes por RPC (funciones de PostgreSQL).
- **Row Level Security (RLS):** la seguridad está en la base. Sólo los usuarios autenticados del
  equipo (*staff*) leen y escriben; el alta pública de usuarios está desactivada.
- **Operaciones atómicas:** numeración, ítems, totales, impuestos y estados se calculan en
  PostgreSQL, dentro de una sola transacción. El navegador nunca fija un total.

---

## 🛠️ Instalación y desarrollo local

### Requisitos
- Node.js 18 o superior.
- Acceso a los proyectos de Supabase: **producción** y **homologación** (pruebas).

### Pasos

1. **Instalar dependencias:**
   ```bash
   cd frontend
   npm install
   ```

2. **Variables de entorno.** No hay `.env.example`: crear los archivos a mano (están ignorados por
   git).
   - `frontend/.env` → producción. Lo usa `npm run build`.
   - `frontend/.env.development.local` → homologación. Pisa a `.env` en `npm run dev`.

   Los dos llevan las mismas dos variables:
   ```env
   VITE_SUPABASE_URL=https://<PROYECTO>.supabase.co
   VITE_SUPABASE_ANON_KEY=<CLAVE_ANON_PUBLICA>
   ```

3. **Servidor de desarrollo** (contra homologación):
   ```bash
   npm run dev                       # http://localhost:5173
   npm run dev -- --mode production  # sólo si hace falta abrirlo contra producción
   ```

4. **Tests:**
   ```bash
   cd frontend && node --test src/utils/*.test.*                  # funciones puras del frontend
   cd supabase/tango && python3 -m unittest discover -s etl -t .  # ETL de Tango
   ```

5. **Publicar:** se publica con **push a `main`**; Vercel compila desde git (Root Directory
   `frontend`, salida `dist`). No se publica con la CLI de Vercel.

---

## 📁 Estructura del proyecto

```
crm-tango/
├── frontend/                   # Aplicación React (Vite)
│   ├── src/
│   │   ├── api/                # Capa de datos: base.js, index.js, cuenta2.js (PostgREST + RPC)
│   │   ├── lib/                # Cliente de Supabase y contextos (auth, tema, calendario)
│   │   ├── components/         # UI compartida, formularios, PDF, ARCA, Calendario, Consultas
│   │   ├── hooks/              # Hooks compartidos
│   │   ├── views/              # Una carpeta por pantalla
│   │   └── utils/              # Formato, fechas, cálculos (+ tests con node --test)
│   ├── index.html
│   ├── vercel.json             # Fallback de la SPA
│   └── vite.config.js
└── supabase/
    ├── migrations/             # Esquema, RLS y RPCs (en orden de aplicación)
    ├── functions/
    │   ├── pdf/                # Edge Function de PDFs
    │   └── arca/               # Edge Function de facturación electrónica
    ├── tango/                  # Migración desde Tango: lector del .bak, export, ETL y carga
    ├── carga_cuenta2/          # Carga de las planillas de Cuenta 2
    ├── arca/ · remitos/ · calendario/ · presupuestos/   # Verificaciones SQL (psql, con ROLLBACK)
    ├── POST_LOAD_VERIFY*.sql   # Controles posteriores a una carga de datos
    └── seed.sql                # Configuración inicial, sólo para bases nuevas o de desarrollo
```

---

## 📄 Licencia

Privado / Propiedad de la empresa.
