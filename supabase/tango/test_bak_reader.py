"""
Tests de bak_reader.py.   Correr:  python3 -m unittest -v test_bak_reader
(desde supabase/tango/). Los de integracion usan el .bak real: TANGO_BAK=/ruta.bak
o, por defecto, MARBLOCK_SA.bak en la raiz del repo; si no esta, se saltean.
"""
import collections
import csv
import datetime
import decimal
import os
import struct
import unittest

from bak_reader import Bak, decode_value, fix_torn_bits, parse_record

AQUI = os.path.dirname(os.path.abspath(__file__))
BAK = os.environ.get("TANGO_BAK", os.path.join(AQUI, "..", "..", "MARBLOCK_SA.bak"))
SNAPSHOT_2026_09_25 = datetime.datetime(2026, 9, 25, 9, 0, 16)


class Decodificacion(unittest.TestCase):
    def test_money_es_int64_little_endian(self):
        self.assertEqual(decode_value(60, struct.pack("<q", -12345678)), decimal.Decimal("-1234.5678"))

    def test_decimal_signo_y_escala(self):
        raw = (123456789).to_bytes(12, "little")
        self.assertEqual(decode_value(106, b"\x01" + raw, 22, 7), decimal.Decimal("12.3456789"))
        self.assertEqual(decode_value(106, b"\x00" + raw, 22, 7), decimal.Decimal("-12.3456789"))

    def test_datetime_dias_y_ticks(self):
        self.assertEqual(decode_value(61, struct.pack("<ii", 300, 1)), datetime.datetime(1900, 1, 2, 0, 0, 1))

    def test_varchar_cp1252(self):
        self.assertEqual(decode_value(167, "Cañuelas".encode("cp1252")), "Cañuelas")

    def test_torn_bits_restaura_el_original_de_cada_sector(self):
        p = bytearray(8192)
        struct.pack_into("<H", p, 4, 0x0100)
        for s in range(1, 16):
            p[512 * (s + 1) - 1] = 0b10                      # patron de escritura en todos
        struct.pack_into("<I", p, 60, 0b10 | (0b01 << 6))   # original del sector 3 = 01
        fixed = fix_torn_bits(bytes(p))
        self.assertEqual(fixed[2047] & 3, 0b01)
        self.assertEqual(fixed[1023] & 3, 0)

    def test_parse_record_fijo_null_y_variable(self):
        rec = bytes([0x30, 0]) + struct.pack("<H", 8) + struct.pack("<i", 42)
        rec += struct.pack("<H", 2) + b"\x00" + struct.pack("<H", 1) + struct.pack("<H", 18) + b"abc"
        fx, ncol, nullbm, var = parse_record(rec, 0)
        self.assertEqual(struct.unpack_from("<i", fx, 4)[0], 42)
        self.assertEqual((ncol, nullbm, var), (2, b"\x00", [(b"abc", False)]))


@unittest.skipUnless(os.path.exists(BAK), "no esta el .bak")
class BackupReal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bak = Bak(BAK)
        with open(os.path.join(AQUI, "tablas.txt")) as f:
            cls.tablas = f.read().split()

    def test_es_sql_server_2005(self):
        self.assertEqual(self.bak.db_version, 611)

    def test_las_57_tablas_coinciden_con_esquema_y_con_rcrows(self):
        esq = collections.defaultdict(list)
        with open(os.path.join(AQUI, "esquema_tango.tsv")) as f:
            for r in csv.DictReader(f, delimiter="\t"):
                esq[r["tabla"]].append((int(r["ordinal"]), r["columna"]))
        for t in self.tablas:
            with self.subTest(tabla=t):
                self.assertEqual([c.name for c in self.bak.columns(t)], [n for _, n in sorted(esq[t])])
                self.assertEqual(sum(1 for _ in self.bak.rows(t)), self.bak.meta_rowcount(t))

    def test_asientos_cuadran_debe_igual_haber(self):
        for m in ("GV", "CP", "SB"):
            cols = [c.name for c in self.bak.columns("ASIENTO_" + m)]
            i_cab, i_dh = cols.index("ID_ASIENTO_COMPROBANTE_" + m), cols.index("D_H")
            i_imp = cols.index("IMPORTE_RENGLON_BASE_" + m)
            saldo = collections.defaultdict(decimal.Decimal)
            for r in self.bak.rows("ASIENTO_" + m):
                saldo[r[i_cab]] += r[i_imp] if r[i_dh] == "D" else -r[i_imp]
            with self.subTest(modulo=m):
                self.assertEqual([k for k, v in saldo.items() if abs(v) > decimal.Decimal("0.01")], [])

    def test_acentos_y_enie_en_razon_social(self):
        cols = [c.name for c in self.bak.columns("GVA14")]
        i = cols.index("RAZON_SOCI")
        self.assertTrue(any("ñ" in (r[i] or "") for r in self.bak.rows("GVA14")))

    def test_snapshot_2026_09_25(self):
        if self.bak.backup_date != SNAPSHOT_2026_09_25:
            self.skipTest("solo para el backup del 2026-09-25")
        self.assertEqual(self.bak.meta_rowcount("GVA12"), 8672)
        self.assertEqual(sum(self.bak.meta_rowcount(t) for t in self.tablas), 250678)


if __name__ == "__main__":
    unittest.main()
