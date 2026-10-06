"""Tests de etl/compras.py (Tarea 7)."""
import unittest
from decimal import Decimal as D

from etl import comun, compras


def fila(**kw):
    base = {"IMPORTE_NE": "0", "IMPORTE_EX": "0", "IMPORTE_IN": "0", "IMPORTE_BO": "0", "IMPORTE_TO": "0",
            "COD_IVA1": "0", "COD_IVA2": "0", "COD_IVA3": "0", "COD_IVA4": "0", "COD_IVA5": "0",
            "IMP_IVA1": "0", "IMP_IVA2": "0", "IMP_IVA3": "0", "IMP_IVA4": "0", "IMP_IVA5": "0",
            "PORC_IVA1": "0", "PORC_IVA2": "0", "PORC_IVA3": "0", "PORC_IVA4": "0", "PORC_IVA5": "0"}
    base.update(kw)
    return base


class Numeracion(unittest.TestCase):
    def setUp(self):
        comun.ANOMALIAS.clear()

    def test_letra_pv_numero(self):
        self.assertEqual(compras.n_comp_compra("A209300801691"), ("A", "02093", 801691))
        self.assertEqual(compras.n_comp_compra("C000300004049"), ("C", "00003", 4049))

    def test_sin_letra_13_digitos(self):
        self.assertEqual(compras.n_comp_compra("0508500064832"), ("A", "05085", 64832))
        self.assertEqual(len(comun.ANOMALIAS), 1)

    def test_numero_con_punto(self):
        self.assertEqual(compras.n_comp_compra("A0001518196.4"), ("A", "00001", 518196))
        self.assertEqual(len(comun.ANOMALIAS), 1)


class Iva(unittest.TestCase):
    def setUp(self):
        comun.ANOMALIAS.clear()

    def test_separa_iva_de_percepciones(self):
        r = fila(IMPORTE_NE="988.90", IMPORTE_EX="38.40", IMPORTE_TO="1307.02", COD_IVA1="1", COD_IVA2="5", COD_IVA3="3",
                 IMP_IVA1="59.30", IMP_IVA2="190.76", IMP_IVA3="29.66", PORC_IVA1="21", PORC_IVA2="27", PORC_IVA3="3")
        iva, perc = compras.desglose(r, "F")
        self.assertEqual([(a, m) for a, m, _ in iva], [(3, D("59.30")), (4, D("190.76")), (1, D("0"))])   # + renglon exento
        self.assertEqual([(p[0], p[3]) for p in perc], [("iva", D("29.66"))])
        self.assertEqual(sum(m for _, m, _ in iva) + sum(p[3] for p in perc), D("279.72"))

    def test_codigo_desconocido_aborta(self):
        with self.assertRaises(ValueError):
            compras.desglose(fila(COD_IVA1="77", IMP_IVA1="1"), "F")

    def test_neto_por_alicuota_cierra_con_el_neto(self):
        r = fila(IMPORTE_NE="750.01", COD_IVA1="1", COD_IVA2="2", IMP_IVA1="105", IMP_IVA2="26.25",
                 PORC_IVA1="21", PORC_IVA2="10.5")
        iva, _ = compras.desglose(r, "F")
        self.assertEqual(sum(n for _, _, n in iva), D("750.01"))      # el centavo de redondeo va al mayor

    def test_exento_y_sin_iva(self):
        iva, _ = compras.desglose(fila(IMPORTE_NE="100", IMPORTE_EX="20", COD_IVA1="1", IMP_IVA1="21", PORC_IVA1="21"), "F")
        self.assertEqual([(a, m, n) for a, m, n in iva], [(3, D("21.00"), D("100.00")), (1, D("0"), D("20.00"))])
        iva, _ = compras.desglose(fila(IMPORTE_NE="50"), "F")           # factura C: sin IVA
        self.assertEqual(iva, [(1, D("0"), D("50.00"))])


class Percepciones(unittest.TestCase):
    def test_cpa18(self):
        self.assertEqual(compras.percepcion_cpa14("51"), ("iibb", "Buenos Aires", D("1.5")))
        self.assertEqual(compras.percepcion_cpa14("54"), ("iibb", "CABA", D("1.5")))
        self.assertEqual(compras.percepcion_cpa14("40")[0], "imp_internos")
        self.assertEqual(compras.percepcion_cpa14("53")[0], "ganancias")


class Renglones(unittest.TestCase):
    """items() reparte CPA47 + CPA46 entre facturas (FP) y notas (CP / DP), por (TCOMP_IN_C, NCOMP_IN_C)."""

    CPA04 = [{"ID_CPA04": "10", "T_COMP": "FAC", "TCOMP_IN_C": "FP", "NCOMP_IN_C": "4.0"},
             {"ID_CPA04": "20", "T_COMP": "N/C", "TCOMP_IN_C": "CP", "NCOMP_IN_C": "4.0"},
             {"ID_CPA04": "30", "T_COMP": "N/D", "TCOMP_IN_C": "DP", "NCOMP_IN_C": "7.0"}]
    CPA45 = [{"COD_CONCEP": "002", "ID_CPA45": "2", "DESC_CONCE": "CEMENTO", "COD_IVA": "1"}]

    def setUp(self):
        comun.ANOMALIAS.clear()

    def cpa47(self, tcomp, ncomp, rid="1"):
        return {"ID_CPA47": rid, "COD_CONCEP": "002", "IMPORTE_NE": "9640.7700000",
                "N_RENGL_C": "1", "TCOMP_IN_C": tcomp, "NCOMP_IN_C": ncomp}

    def cpa46(self, tcomp, ncomp, rid="1"):
        return {"ID_CPA46": rid, "COD_ARTICU": "0002", "CANTIDAD": "2.0000000", "PRECIO_NET": "100.0000000",
                "PRECIO_PAN": "125.0000000", "PORCE_DCTO": "20.0000000", "N_RENGL_C": "1",
                "TCOMP_IN_C": tcomp, "NCOMP_IN_C": ncomp}

    def test_fp_a_factura_y_cp_dp_a_nota(self):
        fac, nts = compras.items(
            [self.cpa47("FP", "4.0", "1"), self.cpa47("CP", "4.0", "2")],
            self.CPA45, self.CPA04, [self.cpa46("DP", "7.0")], {"0002": "Bloque Liso Medio 20"})
        # NCOMP_IN_C '4.0' esta en la factura Y en la NC: el tipo es lo que desempata.
        self.assertEqual([f[1] for f in fac], [10])
        self.assertEqual([n[1] for n in nts], [30, 20])          # CPA46 ordena antes que CPA47
        # concepto -> material_id; articulo -> material_id NULL con la descripcion de STA11
        self.assertEqual(fac[0][2:], (2, "CEMENTO", D("1.000"), D("9640.77"), D("0.00"), 3, D("9640.77"), 1))
        self.assertEqual(nts[0][2:], (None, "Bloque Liso Medio 20", D("2.000"), D("125.00"), D("20.00"), D("200.00"), 1))
        self.assertEqual(nts[1][2:], (2, "CEMENTO", D("1.000"), D("9640.77"), D("0.00"), D("9640.77"), 1))

    def test_ids_renumerados_sin_colision_entre_cpa47_y_cpa46(self):
        _, nts = compras.items([self.cpa47("CP", "4.0", "1")], self.CPA45, self.CPA04,
                               [self.cpa46("DP", "7.0", "1")], {"0002": "x"})
        self.assertEqual(sorted(n[0] for n in nts), [1, 2])

    def test_renglon_sin_comprobante_queda_en_anomalias(self):
        fac, nts = compras.items([self.cpa47("FP", "999.0")], self.CPA45, self.CPA04, [], {})
        self.assertEqual((fac, nts), ([], []))
        self.assertTrue(any("sin comprobante en CPA04" in a for a in comun.ANOMALIAS))

    def test_tcomp_desconocido_aborta(self):
        with self.assertRaises(ValueError):
            compras.items([self.cpa47("ZZ", "4.0")], self.CPA45, self.CPA04, [], {})


class Estados(unittest.TestCase):
    def test_estado(self):
        self.assertEqual(compras.estado_factura("CAN", D(0)), "pagada")
        self.assertEqual(compras.estado_factura("PAG", D(0)), "pagada")
        self.assertEqual(compras.estado_factura("PEN", D(0)), "pendiente")
        self.assertEqual(compras.estado_factura("PEN", D(5)), "parcial")


if __name__ == "__main__":
    unittest.main()
