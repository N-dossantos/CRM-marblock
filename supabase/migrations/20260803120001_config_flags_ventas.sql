-- =============================================================
-- CRM — Fase F / migración 0401: flags de configuración de Ventas
-- system_plan_fase_f_integracion_ventas.md §2.3 / §3.4.
--
--   * contabilidad_auto_asientos     — interruptor del disparo automático de asientos (0400).
--     Arranca en 'off': la matriz de imputación todavía no está validada con el contador, así
--     que asentar solo daría asientos mal imputados. Se prende recién tras Fase E §8 pasos 2-4.
--   * ventas_caja_cobranza_default_id — cuenta de caja preseleccionada en el recibo para medios
--     efectivo (conveniencia de UI, WS1). Vacío ⇒ sin preselección, el usuario elige siempre.
--
-- ON CONFLICT DO NOTHING: si alguien ya cambió el valor a mano, esta migración no lo pisa.
-- =============================================================

INSERT INTO config_empresa (clave, valor) VALUES
  ('contabilidad_auto_asientos',     'off'),
  ('ventas_caja_cobranza_default_id', '')
ON CONFLICT (clave) DO NOTHING;
