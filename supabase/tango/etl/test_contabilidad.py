"""Tests de etl/contabilidad.py (Tarea 9)."""
import unittest
from decimal import Decimal as D

from etl import comun, contabilidad


class Reglas(unittest.TestCase):
    def setUp(self):
        comun.ANOMALIAS.clear()

    def test_renglon_debe_o_haber(self):
        self.assertEqual(contabilidad.renglon({"D_H": "D", "IMPORTE": D("10.005")}), (D("10.01"), D("0.00")))
        self.assertEqual(contabilidad.renglon({"D_H": "H", "IMPORTE": D("10")}), (D("0.00"), D("10.00")))
        with self.assertRaises(ValueError):
            contabilidad.renglon({"D_H": "X", "IMPORTE": D("1")})

    def test_balancear_ajusta_el_renglon_mayor_y_deja_anomalia(self):
        lineas = [[1, D("100.01"), D("0.00")], [2, D("0.00"), D("33.33")], [3, D("0.00"), D("66.67")]]
        contabilidad.balancear(lineas, "asiento X")
        self.assertEqual(sum(l[1] for l in lineas), sum(l[2] for l in lineas))
        self.assertEqual(len(comun.ANOMALIAS), 1)

    def test_balanceado_no_toca_nada(self):
        lineas = [[1, D("100.00"), D("0.00")], [2, D("0.00"), D("100.00")]]
        contabilidad.balancear(lineas, "x")
        self.assertEqual(comun.ANOMALIAS, [])

    def test_referencia_venta(self):
        self.assertEqual(contabilidad.ref_venta("FAC"), "facturas")
        self.assertEqual(contabilidad.ref_venta("N/C"), "notas")
        self.assertEqual(contabilidad.ref_venta("N/D"), "notas")
        self.assertEqual(contabilidad.ref_venta("REC"), "recibos")

    def test_referencia_compra(self):
        self.assertEqual(contabilidad.ref_compra("FAC"), "facturas_compra")
        self.assertEqual(contabilidad.ref_compra("N/C"), "notas_compra")


if __name__ == "__main__":
    unittest.main()
