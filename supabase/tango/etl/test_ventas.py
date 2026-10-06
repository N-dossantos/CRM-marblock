"""Tests de etl/ventas.py (Tarea 6)."""
import unittest
from decimal import Decimal as D

from etl import comun, ventas


class Reglas(unittest.TestCase):
    def setUp(self):
        comun.ANOMALIAS.clear()

    def test_alicuota(self):
        self.assertEqual(ventas.alicuota_id(D("21"), D("0")), 3)
        self.assertEqual(ventas.alicuota_id(D("10.5"), D("0")), 2)
        self.assertEqual(ventas.alicuota_id(D("0"), D("100")), 1)
        self.assertEqual(ventas.alicuota_id(D("21"), D("5")), 1)      # renglon exento manda
        with self.assertRaises(ValueError):
            ventas.alicuota_id(D("13"), D("0"))

    def test_estado_factura(self):
        e = ventas.estado_factura
        self.assertEqual(e("CAN", D("0"), D("100")), "cobrada")
        self.assertEqual(e("PAG", D("0"), D("100")), "cobrada")
        self.assertEqual(e("ANU", D("0"), D("100")), "anulada")
        self.assertEqual(e("PEN", D("0"), D("100")), "pendiente")
        self.assertEqual(e("PEN", D("40"), D("100")), "parcial")
        # '***': se resuelve por el saldo y deja anomalia
        self.assertEqual(e("***", D("100"), D("100"), "FAC X"), "cobrada")
        self.assertEqual(len(comun.ANOMALIAS), 1)

    def test_nota_elige_la_factura_de_mayor_importe(self):
        imp = [("A1", D("10")), ("A2", D("50")), ("A3", D("50"))]
        self.assertEqual(ventas.elegir_factura(imp), "A2")        # empate: la primera
        self.assertIsNone(ventas.elegir_factura([]))

    def test_estado_cheque(self):
        r = {"ESTADO": "A", "TIPO_SAL": "P", "FECHA_SAL": "2017-12-21 00:00:00.000", "FECHA_RECH": "1800-01-01 00:00:00.000"}
        self.assertEqual(ventas.estado_cheque(r), "entregado")
        self.assertEqual(ventas.estado_cheque(dict(r, TIPO_SAL="D")), "depositado")
        self.assertEqual(ventas.estado_cheque(dict(r, ESTADO="C", TIPO_SAL="", FECHA_SAL="")), "en_cartera")
        self.assertIsNone(ventas.estado_cheque(dict(r, ESTADO="X", TIPO_SAL="", FECHA_SAL="")))
        self.assertEqual(ventas.estado_cheque(dict(r, FECHA_RECH="2020-01-01 00:00:00.000")), "rechazado_banco")

    def test_item_subtotal_y_precio(self):
        it = {"ID_GVA53": "5", "N_RENGL_V": "2", "COD_ARTICU": "0001", "CANTIDAD": "675.0000000", "PRECIO_NET": "4.2272727",
              "PRECIO_PAN": "4.7000000", "PORC_DTO": "10.0000000", "PORC_IVA": "21.0000000", "IMPORTE_EXENTO": "0.0000000"}
        f = ventas.item(it, {"0001": "Bloque"})
        self.assertEqual(f, (5, "Bloque", D("675.000"), D("4.70"), D("10.00"), D("2853.41"), 2, 3))

    def test_numero_cheque(self):
        self.assertEqual(ventas.numero_cheque("89079067.0"), "89079067")
        self.assertEqual(ventas.numero_cheque("12.0000000"), "12")

    def test_nota_sin_imputar_conserva_el_cliente(self):
        """H22: cliente_id sale de GVA12.COD_CLIENT, no de la factura; si saliera de la factura las
        30 notas con factura_id NULL se quedarian sin cliente y el saldo CC no cerraria."""
        nota = {"ID_GVA12": "900", "T_COMP": "N/D", "N_COMP": "A000100000051", "ESTADO": "CTA",
                "COD_CLIENT": "000056", "FECHA_EMIS": "2016-05-02 00:00:00.000",
                "IMPORTE_GR": "1532.6000000", "IMPORTE_EX": "0.0000000", "IMPORTE_BO": "0.0000000",
                "IMPORTE_IV": "321.8500000", "IMPORTE": "1854.4500000"}
        filas, items = ventas.notas([nota], [], [], {"000056": 77}, {}, {})
        self.assertEqual(items, [])
        self.assertEqual(len(filas), 1)
        # (id, numero, pv, num, tipo, letra, fecha, factura_id, cliente_id, ...)
        self.assertEqual(filas[0][4:9], ("ND", "A", "2016-05-02", None, 77))
        self.assertTrue(any("sin factura imputada" in a for a in comun.ANOMALIAS))


if __name__ == "__main__":
    unittest.main()
