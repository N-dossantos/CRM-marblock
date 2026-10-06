"""Tests de etl/tesoreria.py (Tarea 8)."""
import unittest
from decimal import Decimal as D

from etl import comun, tesoreria


class Reglas(unittest.TestCase):
    def test_tipo_y_origen(self):
        self.assertEqual(tesoreria.tipo_origen("REC"), (6, "recibo"))
        self.assertEqual(tesoreria.tipo_origen("O/P"), (7, "pago_proveedor"))
        self.assertEqual(tesoreria.tipo_origen("DEP"), (1, "manual"))
        self.assertEqual(tesoreria.tipo_origen("EGR"), (2, "manual"))
        self.assertEqual(tesoreria.tipo_origen("REV"), (10, "manual"))
        with self.assertRaises(ValueError):
            tesoreria.tipo_origen("XXX")

    def test_movimiento_salta_contrapartidas_y_firma_por_dh(self):
        cab = {("REC", " 000100000001"): {"CONCEPTO": "COBRO A CLIENTES"}}
        cuentas = {"1.0": {"ID_SBA01": "1"}, "2.0": {"ID_SBA01": "2"}}
        lineas = [
            {"ID_SBA05": "10", "COD_COMP": "REC", "N_COMP": " 000100000001", "COD_CTA": "2.0", "D_H": "H",
             "FECHA": "2021-10-12 00:00:00.000", "MONTO": "100.0000000", "CONCILIADO": "0"},
            {"ID_SBA05": "11", "COD_COMP": "REC", "N_COMP": " 000100000001", "COD_CTA": "1.0", "D_H": "D",
             "FECHA": "2021-10-12 00:00:00.000", "MONTO": "100.0000000", "CONCILIADO": "0"},
        ]
        mov = tesoreria.movimientos(lineas, cab, cuentas, {" 000100000001": 77}, {})
        self.assertEqual(len(mov), 1)
        self.assertEqual(mov[0][0], 11)                 # id = ID_SBA05
        self.assertEqual(mov[0][3:6], (1, 6, 1))        # cuenta, tipo comprobante, signo +1
        self.assertEqual(mov[0][8:10], ("recibo", 77))

    def test_cheque_propio(self):
        r = {"ID_SBA15": "4", "CTA_BANCO": "3.0", "N_CHEQUE": "22040499.0", "ORDEN": "Telecom", "COD_CPA01": "0010",
             "FECHA_EMI": "2011-02-15 00:00:00.000", "FECHA_CHEQ": "2011-02-20 00:00:00.000", "IMPORTE_CH": "1285.52",
             "N_COMP_EMI": " 000000000037", "TIPO_CHEQU": "C", "ESTADO": "E"}
        f = tesoreria.cheque_propio(r, {"3.0": {"ID_SBA01": "3"}}, {"0010": 10}, {" 000000000037": 99})
        self.assertEqual(f, (4, "22040499", 3, "fisico", "Telecom", 10, "2011-02-15", "2011-02-20", D("1285.52"), "entregado", 99))


if __name__ == "__main__":
    unittest.main()
