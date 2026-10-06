"""Tests de etl/contadores.py (D5: el ultimo numero de cada serie, el dia del cutover)."""
import unittest

from etl import contadores


def gva12(t_comp, n_comp, fecha):
    return {"T_COMP": t_comp, "N_COMP": n_comp, "FECHA_EMIS": fecha}


class Series(unittest.TestCase):

    def test_ultimo_por_fecha_no_por_maximo(self):
        """H4: el recibo 00041189 es un error de carga de Tango; la serie real va por 4288."""
        filas = contadores.series_ventas([
            gva12("REC", " 000100041189", "2026-03-03 00:00:00"),
            gva12("REC", " 000100004288", "2026-09-24 00:00:00"),
            gva12("REC", " 000100004287", "2026-09-20 00:00:00"),
        ])
        self.assertEqual(filas[("REC", None, 1)], (4288, "2026-09-24"))

    def test_una_serie_por_letra(self):
        """H16: la N/C B es fiscalmente independiente de la N/C A y no hereda su numero."""
        filas = contadores.series_ventas([
            gva12("N/C", "A000200000165", "2026-05-04 00:00:00"),
            gva12("N/C", "B000200000001", "2025-12-16 00:00:00"),
        ])
        self.assertEqual(filas[("N/C", "A", 2)], (165, "2026-05-04"))
        self.assertEqual(filas[("N/C", "B", 2)], (1, "2025-12-16"))

    def test_fecha_centinela_no_gana(self):
        """Una fila con 1800-01-01 no puede quedar como 'la ultima' ni romper la comparacion."""
        filas = contadores.series_ventas([
            gva12("FAC", "A000200002321", "2026-09-23 00:00:00"),
            gva12("FAC", "A000200000900", "1800-01-01 00:00:00"),
        ])
        self.assertEqual(filas[("FAC", "A", 2)], (2321, "2026-09-23"))


class Contadores(unittest.TestCase):

    def setUp(self):
        self.ventas = [
            gva12("FAC", "A000200002321", "2026-09-23 00:00:00"),
            gva12("FAC", "B000200000063", "2026-05-19 00:00:00"),
            gva12("FAC", "A000300000004", "2023-05-24 00:00:00"),   # MiPyME (H21)
            gva12("FAC", "A000100000007", "2016-04-01 00:00:00"),   # serie historica
            gva12("N/C", "A000200000165", "2026-05-04 00:00:00"),
            gva12("REC", " 000100004288", "2026-09-24 00:00:00"),
        ]
        self.remitos = [{"T_COMP": "REM", "N_COMP": "R000100010366", "FECHA_MOV": "2026-09-23 00:00:00"}]
        self.pagos = [{"T_COMP": "O/P", "N_COMP": " 000000003358", "FECHA_EMIS": "2026-09-22 00:00:00",
                       "ESTADO": "PEN"}]

    def filas(self):
        return {f.tipo: f for f in contadores.contadores(self.ventas, self.remitos, self.pagos)[0]}

    def test_los_diez_tipos_siempre_estan(self):
        """Los que no tienen fuente en Tango igual se emiten en 0: sin fila, la app falla con
        'Contador no encontrado' (PLAN_MAESTRO.md §3.2.8)."""
        self.assertEqual(sorted(self.filas()), sorted(contadores.TIPOS))
        self.assertEqual(self.filas()["presupuesto"].ultimo_numero, 0)
        self.assertEqual(self.filas()["nota_debito_b"].ultimo_numero, 0)

    def test_toma_la_serie_activa_y_no_la_inactiva(self):
        """H21: FAC A tiene tres puntos de venta; el contador va con el de actividad mas reciente."""
        f = self.filas()["factura_a"]
        self.assertEqual((f.punto_venta, f.ultimo_numero), ("00002", 2321))

    def test_las_series_sin_contador_se_reportan(self):
        """H21: las otras series de FAC A no se pierden en silencio."""
        _, huerfanas = contadores.contadores(self.ventas, self.remitos, self.pagos)
        self.assertEqual(sorted((h[0], h[1], h[2], h[3]) for h in huerfanas),
                         [("FAC", "A", 1, 7), ("FAC", "A", 3, 4)])

    def test_pago_proveedor_en_punto_de_venta_0(self):
        """H20: las O/P no tienen punto de venta fiscal; el seed las tenia en 00002."""
        f = self.filas()["pago_proveedor"]
        self.assertEqual((f.punto_venta, f.ultimo_numero), ("00000", 3358))

    def test_remito_sale_del_talonario_preimpreso(self):
        """H3: Supabase quedo en 10324 y Tango ya emitio 10366."""
        f = self.filas()["remito"]
        self.assertEqual((f.punto_venta, f.ultimo_numero), ("00001", 10366))

    def test_op_anulada_no_cuenta(self):
        self.pagos.append({"T_COMP": "O/P", "N_COMP": " 000000009999", "FECHA_EMIS": "2026-09-30 00:00:00",
                           "ESTADO": "ANU"})
        self.assertEqual(self.filas()["pago_proveedor"].ultimo_numero, 3358)

    def test_sql_es_el_upsert_que_usa_05_cargar(self):
        sql = contadores.sql(contadores.contadores(self.ventas, self.remitos, self.pagos)[0])
        self.assertIn("INSERT INTO contadores (tipo, punto_venta, ultimo_numero, descripcion)", sql)
        self.assertIn("ON CONFLICT (tipo) DO UPDATE", sql)
        self.assertIn("('factura_a',      '00002',  2321,", sql)


if __name__ == "__main__":
    unittest.main()
