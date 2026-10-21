-- Quién creó, cambió o borró un presupuesto o una retención sufrida (audit_log, igual que
-- compras y tesorería). Los ítems de presupuesto no se auditan: la cabecera alcanza.
CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON presupuestos
  FOR EACH ROW EXECUTE FUNCTION audit_trigger();

CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON recibo_retenciones
  FOR EACH ROW EXECUTE FUNCTION audit_trigger();
