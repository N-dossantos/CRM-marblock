"""Tests de etl/maestros.py.   Correr (desde supabase/tango/):  python3 -m unittest discover -s etl -t . -v"""
import unittest
from decimal import Decimal

from etl import comun, maestros


class Clientes(unittest.TestCase):
    def setUp(self):
        comun.ANOMALIAS.clear()

    def test_descuento_redondea_al_permitido_mas_cercano(self):
        d = maestros.descuento_permitido
        self.assertEqual([d(Decimal(x)) for x in (0, 7, 10, 15, 18, 20)], [0, 10, 10, 15, 20, 20])
        self.assertEqual(d(Decimal(5)), 10)   # empate: hacia arriba

    def test_condicion_iva(self):
        self.assertEqual(maestros.condicion_iva("RI"), "Resp. Inscripto")
        self.assertEqual(maestros.condicion_iva("CF"), "Consumidor Final")
        self.assertEqual(maestros.condicion_iva("EX"), "Exento")
        with self.assertRaises(ValueError):
            maestros.condicion_iva("ZZ")

    def test_cuit_formato(self):
        self.assertEqual(maestros.formatear_cuit("30712524517"), "30-71252451-7")
        self.assertEqual(maestros.formatear_cuit("30-59579340-4"), "30-59579340-4")
        self.assertTrue(maestros.cuit_valido("30-59579340-4"))
        self.assertFalse(maestros.cuit_valido(""))

    def _cli(self, id_, cod, cuit, dto="0.0000000", razon="X"):
        return {"ID_GVA14": id_, "COD_CLIENT": cod, "CUIT": cuit, "RAZON_SOCI": razon, "DOMICILIO": "d",
                "LOCALIDAD": "l", "COD_PROVIN": "01", "TELEFONO_1": "t", "E_MAIL": "e", "PORC_DESC": dto,
                "FECHA_INHA": "1800-01-01 00:00:00.000"}

    def test_cuit_duplicado_y_vacio_duplicado_recibe_marcador_y_vacio_consumidor_final(self):
        cli = [self._cli("1", "000001", "30-71083483-7"), self._cli("2", "000002", "30-71083483-7"),
               self._cli("3", "000003", "")]
        filas = maestros.clientes(cli, {"000001": "RI", "000002": "RI"}, {"01": "Buenos Aires"})
        cuits = [f[2] for f in filas]
        self.assertEqual(cuits[0], "30-71083483-7")
        self.assertEqual(cuits[1], "99-00000002-0")
        self.assertEqual(cuits[2], "00-00000000-0")
        self.assertEqual(len(set(cuits)), 3)
        self.assertEqual(len(comun.ANOMALIAS), 1)   # solo el duplicado; sin CUIT = Consumidor Final (plan)

    def test_condicion_sin_comprobantes(self):
        filas = maestros.clientes([self._cli("1", "000001", "30-59579340-4"), self._cli("2", "000002", "")],
                                  {}, {"01": "Buenos Aires"})
        self.assertEqual(filas[0][3], "Resp. Inscripto")
        self.assertEqual(filas[1][3], "Consumidor Final")

    def test_descuento_ajustado_deja_anomalia(self):
        maestros.clientes([self._cli("1", "000001", "30-59579340-4", dto="18.0000000")], {}, {"01": "x"})
        self.assertEqual(len(comun.ANOMALIAS), 1)


class UltimaCondicion(unittest.TestCase):
    def test_toma_el_ultimo_comprobante_por_fecha(self):
        gva12 = [
            {"COD_CLIENT": "1", "CAT_IVA": "RI", "FECHA_EMIS": "2020-01-01 00:00:00.000", "ID_GVA12": "1"},
            {"COD_CLIENT": "1", "CAT_IVA": "CF", "FECHA_EMIS": "2024-01-01 00:00:00.000", "ID_GVA12": "2"},
            {"COD_CLIENT": "1", "CAT_IVA": "", "FECHA_EMIS": "2025-01-01 00:00:00.000", "ID_GVA12": "3"},
        ]
        self.assertEqual(maestros.ultima_cat_iva(gva12), {"1": "CF"})


class PlanDeCuentas(unittest.TestCase):
    def test_tipo_por_clase(self):
        self.assertEqual([maestros.tipo_cuenta(c) for c in "1234567"],
                         ["Activo", "Pasivo", "Patrimonio", "Ingreso", "Egreso", "Patrimonio", "Patrimonio"])


class CuentasBancarias(unittest.TestCase):
    def test_clase_y_agrupacion(self):
        self.assertEqual(maestros.clase_cuenta({"COD_CTA": "3.0", "TIPO": "B"}), ("banco", 1))
        self.assertEqual(maestros.clase_cuenta({"COD_CTA": "1.0", "TIPO": "O"}), ("caja", 2))
        self.assertEqual(maestros.clase_cuenta({"COD_CTA": "4.0", "TIPO": "C"}), ("valores", 3))
        self.assertEqual(maestros.clase_cuenta({"COD_CTA": "7.0", "TIPO": "O"}), ("caja", 2))


if __name__ == "__main__":
    unittest.main()
