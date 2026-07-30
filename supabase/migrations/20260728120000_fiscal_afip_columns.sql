-- Preserve AFIP fiscal fields on historical Tango facturas/notas (TANGO_Migration.md §5).
-- Nullable/additive: CRM-Ventas does not issue fiscally (no CAE) yet — that's a future
-- AFIP web-service integration. These columns only carry forward history from Tango on import.

ALTER TABLE facturas
  ADD COLUMN IF NOT EXISTS cae varchar(20),
  ADD COLUMN IF NOT EXISTS cae_vencimiento date,
  ADD COLUMN IF NOT EXISTS afip_tipo_comprobante varchar(3),
  ADD COLUMN IF NOT EXISTS afip_doc_tipo varchar(3),
  ADD COLUMN IF NOT EXISTS afip_doc_nro varchar(20);

ALTER TABLE notas
  ADD COLUMN IF NOT EXISTS cae varchar(20),
  ADD COLUMN IF NOT EXISTS cae_vencimiento date,
  ADD COLUMN IF NOT EXISTS afip_tipo_comprobante varchar(3),
  ADD COLUMN IF NOT EXISTS afip_doc_tipo varchar(3),
  ADD COLUMN IF NOT EXISTS afip_doc_nro varchar(20);

COMMENT ON COLUMN facturas.cae IS 'AFIP CAE (Código de Autorización Electrónico) preserved from Tango history. NULL for comprobantes not yet issued fiscally by CRM-Ventas.';
COMMENT ON COLUMN facturas.cae_vencimiento IS 'AFIP CAE expiration date.';
COMMENT ON COLUMN facturas.afip_tipo_comprobante IS 'AFIP numeric comprobante type code (e.g. 01=Factura A, 06=Factura B) at time of fiscal issuance.';
COMMENT ON COLUMN facturas.afip_doc_tipo IS 'AFIP receptor doc type code used at issuance (e.g. 80=CUIT, 96=DNI, 99=Consumidor Final) — may differ from clientes.cuit today.';
COMMENT ON COLUMN facturas.afip_doc_nro IS 'AFIP receptor doc number used at issuance.';

COMMENT ON COLUMN notas.cae IS 'AFIP CAE preserved from Tango history for this nota (NC/ND are issued fiscally in their own right, separate CAE from the linked factura).';
COMMENT ON COLUMN notas.cae_vencimiento IS 'AFIP CAE expiration date.';
COMMENT ON COLUMN notas.afip_tipo_comprobante IS 'AFIP numeric comprobante type code (e.g. 03=NC A, 08=NC B) at time of fiscal issuance.';
COMMENT ON COLUMN notas.afip_doc_tipo IS 'AFIP receptor doc type code used at issuance.';
COMMENT ON COLUMN notas.afip_doc_nro IS 'AFIP receptor doc number used at issuance.';
