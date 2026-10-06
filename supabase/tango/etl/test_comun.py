"""Tests de etl/comun.py.   Correr (desde supabase/tango/):  python3 -m unittest discover -s etl -t . -v"""
import os
import tempfile
import unittest
from decimal import Decimal

from etl import comun


class Fecha(unittest.TestCase):
    def setUp(self):
        comun.ANOMALIAS.clear()

    def test_vacio_y_centinela_son_none(self):
        self.assertIsNone(comun.fecha(""))
        self.assertIsNone(comun.fecha("1800-01-01 00:00:00.000"))
        self.assertEqual(comun.ANOMALIAS, [])

    def test_fecha_valida_devuelve_iso(self):
        self.assertEqual(comun.fecha("2026-09-24 13:05:07.123"), "2026-09-24")

    def test_fecha_posterior_a_2027_es_none_y_anomalia(self):
        self.assertIsNone(comun.fecha("2031-05-18 00:00:00.000", "SBA14 id=7 FECHA_CHEQ"))
        self.assertEqual(len(comun.ANOMALIAS), 1)
        self.assertIn("SBA14 id=7", comun.ANOMALIAS[0])
        self.assertIn("2031-05-18", comun.ANOMALIAS[0])

    def test_escribir_anomalias(self):
        comun.anomalia("algo raro")
        with tempfile.TemporaryDirectory() as d:
            comun.escribir_anomalias(d)
            self.assertIn("algo raro", open(os.path.join(d, "_anomalias.txt")).read())


class Texto(unittest.TestCase):
    def test_strip_y_vacio_a_none(self):
        self.assertEqual(comun.texto("  hola "), "hola")
        self.assertIsNone(comun.texto("   "))
        self.assertIsNone(comun.texto(""))


class NComp(unittest.TestCase):
    def test_factura(self):
        self.assertEqual(comun.n_comp("A000200002321"), ("A", 2, 2321, "00002-00002321"))

    def test_recibo_sin_letra(self):
        self.assertEqual(comun.n_comp(" 000100004288"), (None, 1, 4288, "00001-00004288"))

    def test_remito(self):
        self.assertEqual(comun.n_comp("R000100010366"), ("R", 1, 10366, "00001-00010366"))

    def test_formato_invalido_aborta(self):
        with self.assertRaises(ValueError):
            comun.n_comp("A00020")


class Copy(unittest.TestCase):
    def test_copy_escapa_y_null(self):
        out = comun.escribir_copy("t", ["a", "b", "c"], [(1, None, "x\ty\nz\\")])
        self.assertEqual(out, "COPY t (a, b, c) FROM stdin;\n1\t\\N\tx\\ty\\nz\\\\\n\\.\n")

    def test_copy_decimal_y_bool(self):
        out = comun.escribir_copy("t", ["a", "b"], [(Decimal("1.50"), True)])
        self.assertIn("1.50\tt\n", out)


class Lectura(unittest.TestCase):
    def test_leer_csv_con_nombres_de_columna(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "GVA18.csv"), "w", encoding="utf-8", newline="") as f:
                f.write("1|~|x|~|BUENOS AIRES@#@\n")
            esquema = {"GVA18": ["ID_GVA18", "FILLER", "NOMBRE_PRO"]}
            filas = comun.leer("GVA18", d, esquema)
            self.assertEqual(filas, [{"ID_GVA18": "1", "FILLER": "x", "NOMBRE_PRO": "BUENOS AIRES"}])

    def test_registro_con_columnas_de_mas_aborta(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "T.csv"), "w", encoding="utf-8", newline="") as f:
                f.write("1|~|2|~|3@#@\n")
            with self.assertRaises(ValueError):
                comun.leer("T", d, {"T": ["A", "B"]})


class Numeros(unittest.TestCase):
    def test_dec(self):
        self.assertEqual(comun.dec("12.3400000"), Decimal("12.34"))
        self.assertEqual(comun.dec(""), Decimal("0"))


if __name__ == "__main__":
    unittest.main()
