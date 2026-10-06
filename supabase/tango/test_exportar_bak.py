"""
Tests de 03_exportar_bak.py.   Correr:  python3 -m unittest -v test_exportar_bak
"""
import datetime
import decimal
import importlib.util
import os
import unittest

AQUI = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("exportar", os.path.join(AQUI, "03_exportar_bak.py"))
exportar = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(exportar)


class Canonico(unittest.TestCase):
    def test_null_vacio_fecha_iso_y_decimal_sin_exponente(self):
        self.assertEqual(exportar.canon(None), "")
        self.assertEqual(exportar.canon(datetime.datetime(2026, 9, 24, 13, 5, 7, 123000)), "2026-09-24 13:05:07.123")
        self.assertEqual(exportar.canon(decimal.Decimal("0E-7")), "0.0000000")
        self.assertEqual(exportar.canon(1), "1")

    def test_aborta_si_un_campo_trae_separador_o_terminador(self):
        with self.assertRaises(ValueError):
            exportar.canon("RAZON |~| SOCIAL")
        with self.assertRaises(ValueError):
            exportar.canon("linea@#@")


if __name__ == "__main__":
    unittest.main()
