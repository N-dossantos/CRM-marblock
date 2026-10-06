"""
bak_reader.py - Lee un backup completo (.bak) de SQL Server 2005 sin SQL Server.

Tango (MARBLOCK_SA) corre sobre SQL Server 2005 Express (version de base 611). Un
SQL Server moderno (2016+) no restaura backups de 2005 y la regla del repo prohibe
Docker, asi que el .bak se lee directo: el stream MQDA del formato MTF es una imagen
completa del .mdf (pagina N en base + N*8192) y de ahi se decodifican el catalogo y
las filas. Solo stdlib de Python 3.9.

Particularidades del formato verificadas contra MARBLOCK_SA.bak (2026-09-25):
  - torn page detection: cada sector de 512 B tiene pisados los 2 bits bajos de su
    ultimo byte; los originales estan en m_tornBits (header, offset 60).
  - PFS: la pagina p tiene su byte en la PFS (p // 8088) * 8088 (la 1ra es la 1),
    en el offset 100 + (p - base). Bit 0x40 = asignada.
  - Catalogo 2005: sysschobjs (34), syscolpars (41), sysrowsets (5),
    sysallocunits (7), syshobtcolumns (13), sysrowsetcolumns (4). colid se mapea
    a la columna fisica por sysrowsetcolumns (difiere cuando Tango hizo ALTER).
  - money es int64 little-endian / 10^4 (no dos mitades).
"""
import collections
import datetime
import decimal
import mmap
import struct
import uuid

PAGE = 8192
PFS_INTERVAL = 8088
D1900 = datetime.datetime(1900, 1, 1)
LOB_TYPES = (34, 35, 99)            # image, text, ntext
FIXED_SIZE = {48: 1, 52: 2, 56: 4, 127: 8, 58: 4, 61: 8, 59: 4, 62: 8, 60: 8, 122: 4, 36: 16}


class BakError(Exception):
    pass


Column = collections.namedtuple(
    "Column", "name colid xtype maxlen prec scale offset bitpos nullbit")


def fix_torn_bits(raw):
    """Restaura los 2 bits originales del ultimo byte de los sectores 1..15."""
    if not struct.unpack_from("<H", raw, 4)[0] & 0x0100:
        return bytes(raw)
    p = bytearray(raw)
    torn = struct.unpack_from("<I", p, 60)[0]
    for s in range(1, 16):
        i = 512 * (s + 1) - 1
        p[i] = (p[i] & 0xFC) | ((torn >> (2 * s)) & 3)
    return bytes(p)


def decode_value(xtype, b, prec=0, scale=0):
    if xtype == 56: return struct.unpack("<i", b)[0]
    if xtype == 52: return struct.unpack("<h", b)[0]
    if xtype == 48: return b[0]
    if xtype == 127: return struct.unpack("<q", b)[0]
    if xtype == 61:
        ticks, days = struct.unpack("<ii", b)
        return D1900 + datetime.timedelta(days=days, milliseconds=round(ticks * 10 / 3))
    if xtype == 58:
        minutes, days = struct.unpack("<HH", b)
        return D1900 + datetime.timedelta(days=days, minutes=minutes)
    if xtype in (106, 108):
        v = int.from_bytes(b[1:], "little")
        return decimal.Decimal(v if b[0] == 1 else -v).scaleb(-scale)
    if xtype == 60: return decimal.Decimal(struct.unpack("<q", b)[0]).scaleb(-4)
    if xtype == 122: return decimal.Decimal(struct.unpack("<i", b)[0]).scaleb(-4)
    if xtype == 62: return struct.unpack("<d", b)[0]
    if xtype == 59: return struct.unpack("<f", b)[0]
    if xtype in (175, 167, 35): return bytes(b).decode("cp1252")
    if xtype in (239, 231, 99): return bytes(b).decode("utf-16le")
    if xtype == 36: return str(uuid.UUID(bytes_le=bytes(b)))
    return bytes(b).hex()                                    # binary/varbinary/image/timestamp


def mtf_date(b):
    v = int.from_bytes(b, "big")
    sec, v = v & 63, v >> 6
    mi, v = v & 63, v >> 6
    h, v = v & 31, v >> 5
    d, v = v & 31, v >> 5
    mo, y = v & 15, v >> 4
    return datetime.datetime(y, mo, d, h, mi, sec)


def parse_record(p, o):
    """-> (fixed_bytes, ncols, null_bitmap, [(var_bytes, is_complex)])"""
    sa = p[o]
    fixed_end = struct.unpack_from("<H", p, o + 2)[0]
    pos = o + fixed_end
    ncol = struct.unpack_from("<H", p, pos)[0]
    pos += 2
    nb = (ncol + 7) // 8 if sa & 0x10 else 0
    nullbm = p[pos:pos + nb]
    pos += nb
    var = []
    if sa & 0x20:
        nv = struct.unpack_from("<H", p, pos)[0]
        pos += 2
        start = pos + 2 * nv
        for i in range(nv):
            end = struct.unpack_from("<H", p, pos + 2 * i)[0]
            var.append((p[start:o + (end & 0x7FFF)], bool(end & 0x8000)))
            start = o + (end & 0x7FFF)
    return p[o:o + fixed_end], ncol, nullbm, var


class Bak:
    def __init__(self, path):
        self._f = open(path, "rb")
        self.m = mmap.mmap(self._f.fileno(), 0, access=mmap.ACCESS_READ)
        if self.m[:4] != b"TAPE":
            raise BakError("no es un backup MTF de SQL Server")
        sset = self.m.find(b"SSET")
        self.backup_date = mtf_date(self.m[sset + 88:sset + 93])
        self.base, self.npages = self._locate_data()
        self._cache = {}
        boot = self._record(9, 0)                               # pagina de arranque (1:9)
        self.db_version, self.db_create_version = struct.unpack_from("<HH", boot, 4)
        if self.db_version != 611:
            raise BakError("version de base %d: este lector es solo para SQL Server 2005 (611)"
                           % self.db_version)
        self._index_pages()
        self._load_catalog()

    # ---- paginas -------------------------------------------------------
    def _locate_data(self):
        h = self.m.find(b"MQDA")
        if h < 0:
            raise BakError("no hay stream MQDA")
        length = struct.unpack_from("<Q", self.m, h + 8)[0]
        start = h + 22
        for base in range(start, start + 512):              # pagina 0 = file header (tipo 15)
            pg = self.m[base:base + 96]
            if pg[0] == 1 and pg[1] == 15 and struct.unpack_from("<IH", pg, 32) == (0, 1):
                return base, (length - (base - start)) // PAGE
        raise BakError("no se encontro la pagina 0 del .mdf dentro de MQDA")

    def page(self, pid):
        if pid in self._cache:
            return self._cache[pid]
        if not 0 <= pid < self.npages:
            return None
        off = self.base + pid * PAGE
        raw = self.m[off:off + PAGE]
        if raw[0] != 1 or struct.unpack_from("<IH", raw, 32) != (pid, 1):
            return None                                     # slot no formateado / basura vieja
        p = fix_torn_bits(raw)
        self._cache[pid] = p
        return p

    def allocated(self, pid):
        base = (pid // PFS_INTERVAL) * PFS_INTERVAL
        pfs = self.page(base or 1)
        return pfs is not None and bool(pfs[100 + pid - base] & 0x40)

    def _record(self, pid, slot):
        p = self.page(pid)
        o = struct.unpack_from("<H", p, PAGE - 2 - 2 * slot)[0]
        return p[o:]

    def _index_pages(self):
        self._by_owner = collections.defaultdict(list)       # (objid, indexid, tipo) -> [pid]
        for pid in range(self.npages):
            p = self.page(pid)
            if p is not None:
                key = (struct.unpack_from("<I", p, 24)[0], struct.unpack_from("<H", p, 6)[0], p[1])
                self._by_owner[key].append(pid)

    def _records(self, obj, idx):
        """Registros vivos (primarios y forwarded) de las paginas de datos asignadas."""
        for pid in self._by_owner.get((obj, idx, 1), []):
            if not self.allocated(pid):
                continue
            p = self.page(pid)
            for s in range(struct.unpack_from("<H", p, 22)[0]):
                o = struct.unpack_from("<H", p, PAGE - 2 - 2 * s)[0]
                if o and (p[o] >> 1) & 7 in (0, 1):            # 0 primario, 1 forwarded
                    yield p, o

    # ---- catalogo -------------------------------------------------------
    def _load_catalog(self):
        self.objects = {}
        for p, o in self._records(34, 1):                       # sysschobjs
            fx, _, _, var = parse_record(p, o)
            oid = struct.unpack_from("<i", fx, 4)[0]
            self.objects[oid] = (bytes(var[0][0]).decode("utf-16le"), fx[17:19].decode("latin1").strip())
        self.tables = {n: i for i, (n, t) in self.objects.items() if t == "U"}
        self._cols = collections.defaultdict(list)
        for p, o in self._records(41, 1):                       # syscolpars
            fx, _, _, var = parse_record(p, o)
            oid, number, colid = struct.unpack_from("<ihi", fx, 4)
            if number == 0:
                self._cols[oid].append((colid, bytes(var[0][0]).decode("utf-16le"), fx[14]))
        self._rowsets = {}
        for p, o in self._records(5, 0):                        # sysrowsets
            fx = parse_record(p, o)[0]
            rsid = struct.unpack_from("<q", fx, 4)[0]
            self._rowsets[rsid] = struct.unpack_from("<iiq", fx, 13)[0:2] + (struct.unpack_from("<q", fx, 31)[0],)
        self._allocunits = {}
        for p, o in self._records(7, 0):                        # sysallocunits
            fx = parse_record(p, o)[0]
            self._allocunits[struct.unpack_from("<q", fx, 4)[0]] = (fx[12], struct.unpack_from("<q", fx, 13)[0])
        self._hobtcols = collections.defaultdict(dict)
        for p, o in self._records(13, 0):                       # syshobtcolumns
            fx = parse_record(p, o)[0]
            hobt, hcid = struct.unpack_from("<qi", fx, 4)
            self._hobtcols[hobt][hcid] = (fx[22], struct.unpack_from("<H", fx, 23)[0], fx[25], fx[26],
                                          struct.unpack_from("<h", fx, 31)[0], fx[35],
                                          struct.unpack_from("<i", fx, 37)[0])
        self._rscols = collections.defaultdict(dict)
        for p, o in self._records(4, 0):                        # sysrowsetcolumns
            fx = parse_record(p, o)[0]
            rsid, rscolid, hcid = struct.unpack_from("<qii", fx, 4)
            self._rscols[rsid][rscolid] = hcid

    def _rowset(self, table):
        tid = self.tables[table]
        rs = [k for k, v in self._rowsets.items() if v[0] == tid and v[1] in (0, 1)]
        if len(rs) != 1:
            raise BakError("%s: se esperaba 1 heap/clustered, hay %d" % (table, len(rs)))
        return rs[0]

    def columns(self, table):
        rs = self._rowset(table)
        out = []
        for colid, name, xtype in sorted(self._cols[self.tables[table]]):
            h = self._hobtcols[rs].get(self._rscols[rs].get(colid, colid))
            if h is None or h[0] != xtype:
                raise BakError("%s.%s: columna fisica no encontrada o de otro tipo" % (table, name))
            out.append(Column(name, colid, *h))
        return out

    def meta_rowcount(self, table):
        """sysrowsets.rcrows: el conteo que mantiene el motor (= sys.partitions.rows)."""
        return self._rowsets[self._rowset(table)][2]

    # ---- filas ------------------------------------------------------------
    def _lob(self, ptr):
        pid, _fid, slot = struct.unpack_from("<IHH", ptr, 8)    # 8 B timestamp + RID
        return self._lob_fetch(pid, slot)

    def _lob_fetch(self, pid, slot):
        rec = self._record(pid, slot)
        length, = struct.unpack_from("<H", rec, 2)
        kind, = struct.unpack_from("<H", rec, 12)
        if kind == 0:                                           # SMALL_ROOT
            size, = struct.unpack_from("<H", rec, 14)
            return rec[20:20 + size]
        if kind == 3:                                           # DATA
            return rec[14:length]
        if kind in (2, 5):                                      # INTERNAL / LARGE_ROOT_YUKON
            _maxl, cur, _lvl = struct.unpack_from("<HHH", rec, 14)
            q, out = (20 if kind == 2 else 24), b""
            for _ in range(cur):
                cpid, _f, cslot = struct.unpack_from("<IHH", rec, q + 4)
                out += self._lob_fetch(cpid, cslot)
                q += 12
            return out
        raise BakError("LOB de tipo %d no soportado (pagina %d slot %d)" % (kind, pid, slot))

    def rows(self, table):
        cols = self.columns(table)
        rs = self._rowset(table)
        au = [k for k, (typ, owner) in self._allocunits.items() if owner == rs and typ == 1][0]
        obj, idx = (au >> 16) & 0xFFFFFFFF, au >> 48
        for p, o in self._records(obj, idx):
            fx, ncol, nullbm, var = parse_record(p, o)
            row = []
            for c in cols:
                nb = c.nullbit - 1
                if nb >= ncol or (nullbm and nullbm[nb // 8] >> (nb % 8) & 1):
                    row.append(None)
                elif c.offset > 0:
                    if c.xtype == 104:
                        row.append(fx[c.offset] >> c.bitpos & 1)
                    else:
                        size = FIXED_SIZE.get(c.xtype) or (
                            (5 if c.prec <= 9 else 9 if c.prec <= 19 else 13 if c.prec <= 28 else 17)
                            if c.xtype in (106, 108) else c.maxlen)
                        row.append(decode_value(c.xtype, fx[c.offset:c.offset + size], c.prec, c.scale))
                else:
                    i = -c.offset - 1
                    b = var[i][0] if i < len(var) else b""
                    if c.xtype in LOB_TYPES:
                        row.append(decode_value(c.xtype, self._lob(b)) if len(b) == 16 else None)
                    else:
                        row.append(decode_value(c.xtype, b, c.prec, c.scale))
            yield row
