"""Writes the Parquet fixtures and the rows each one must read as, with pyarrow.

A manual script, not run by CI. Pinned: pyarrow==26.0.1 (pip install --only-binary :all: pyarrow==26.0.1), in the venv
~/.cache/agentica-packages/venv-pyarrow, from the package folder:
  ~/.cache/agentica-packages/venv-pyarrow/bin/python specs/fixtures/make_fixtures.py
The outputs (`*.parquet` and `*.json` beside this file) are committed. The damaged files are copies of `plain_one`
whose footer or page header is rewritten by the small Thrift compact codec below, so a lie about a size or an offset
is exact.
"""

import json
import math
import pathlib

import pyarrow as pa
import pyarrow.parquet as pq

HERE = pathlib.Path(__file__).resolve().parent


def plain(value):
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return None
    return value


def write(name, table, **options):
    pq.write_table(table, HERE / f"{name}.parquet", **options)
    rows = [{key: plain(value) for key, value in row.items()} for row in table.to_pylist()]
    (HERE / f"{name}.json").write_text(json.dumps({"rows": rows}, indent=1, sort_keys=True) + "\n")


def required(name, kind, values):
    return pa.field(name, kind, nullable=False), pa.array(values, kind)


def main():
    fields, arrays = zip(
        required("id", pa.int64(), [1, 2, 3, 4, 5]),
        required("small", pa.int32(), [7, -2, 0, 2147483647, -2147483648]),
        required("ratio", pa.float64(), [0.5, -1.25, 0.0, 3.0, 0.001]),
        required("single", pa.float32(), [0.5, 1.5, -2.0, 0.25, 8.0]),
        required("name", pa.string(), ["ann", "bob", "", "café", "ünïcode ✓"]),
        required("flag", pa.bool_(), [True, False, True, True, False]),
        required("raw", pa.binary(), [b"\x00\xff", b"", b"abc", b"\x01", b"\xfe\xfe\xfe"]),
        required("fixed", pa.binary(3), [b"abc", b"\x00\x01\x02", b"xyz", b"\xff\xff\xff", b"123"]),
    )
    kinds = pa.Table.from_arrays(list(arrays), schema=pa.schema(list(fields)))
    write("plain_required", kinds, use_dictionary=False, compression="NONE", data_page_version="1.0")
    write("kinds_dictionary_snappy", kinds, use_dictionary=True, compression="SNAPPY", data_page_version="1.0")
    write("kinds_v2_gzip", kinds, use_dictionary=True, compression="GZIP", data_page_version="2.0")
    for codec in ("ZSTD", "LZ4"):
        pq.write_table(kinds, HERE / f"codec_{codec.lower()}.parquet", compression=codec)

    names = ["ann", None, "ann", "bob", None, "ann", "carol", None]
    nums = [1, 2, None, 4, None, 6, 7, None]
    table = pa.table({"name": pa.array(names, pa.string()), "num": pa.array(nums, pa.int64()),
                      "flag": pa.array([True, None, False, None, True, False, None, True])})
    write("nulls_plain", table, use_dictionary=False, compression="NONE", data_page_version="1.0")
    write("nulls_dictionary", table, use_dictionary=True, compression="NONE", data_page_version="1.0")
    write("nulls_snappy", table, use_dictionary=True, compression="SNAPPY", data_page_version="1.0")
    write("nulls_gzip", table, use_dictionary=False, compression="GZIP", data_page_version="1.0")
    write("nulls_v2_snappy", table, use_dictionary=False, compression="SNAPPY", data_page_version="2.0")
    write("nulls_v2_plain", table, use_dictionary=True, compression="NONE", data_page_version="2.0")

    cycle = [["alpha", "beta", "gamma"][i % 3] for i in range(240)]
    dense = pa.table({"word": pa.array(cycle, pa.string()),
                      "bucket": pa.array([(i * 7) % 5 for i in range(240)], pa.int32()),
                      "sparse": pa.array([None if i % 4 else i for i in range(240)], pa.int64())})
    write("runs_dictionary", dense, use_dictionary=True, compression="NONE", data_page_version="1.0")

    groups = pa.table({"n": pa.array([1, None, 3, 4, None, 6, 7], pa.int64()),
                       "s": pa.array(["a", "b", None, "d", "e", None, "g"], pa.string())})
    write("row_groups", groups, row_group_size=3, use_dictionary=False, compression="NONE",
          data_page_version="1.0")

    big = pa.table({"s": pa.array(["".join(chr(97 + (j + i) % 26) for j in range(400000)) for i in range(3)], pa.string())})
    pq.write_table(big, HERE / "gzip_big.parquet", use_dictionary=False, compression="GZIP", data_page_version="1.0",
                   data_page_size=8 * 1024 * 1024)
    nothing = pa.table({"n": pa.array([None, None, None, None], pa.int64())})
    write("gzip_nulls_v2", nothing, use_dictionary=False, compression="GZIP", data_page_version="2.0")
    write("uint32", pa.table({"u": pa.array([0, 1, 3000000000, 4294967295], pa.uint32())}), use_dictionary=False,
          compression="NONE", data_page_version="1.0")
    pq.write_table(pa.table({"u": pa.array([1, 2], pa.uint64())}), HERE / "uint64.parquet")

    many = pa.table({"n": pa.array([None if i % 7 == 3 else i * 3 for i in range(300)], pa.int64()),
                     "s": pa.array([None if i % 5 == 1 else f"row {i % 17}" for i in range(300)], pa.string())})
    paged = {"data_page_size": 100, "write_batch_size": 20, "row_group_size": 120}
    write("pages_v1", many, use_dictionary=False, compression="NONE", data_page_version="1.0", **paged)
    write("pages_v2_snappy", many, use_dictionary=False, compression="SNAPPY", data_page_version="2.0", **paged)
    write("pages_dictionary", many, use_dictionary=True, compression="GZIP", data_page_version="1.0", **paged)

    empty = pa.table({"n": pa.array([], pa.int64()), "s": pa.array([], pa.string())})
    write("empty", empty, compression="NONE", data_page_version="1.0")

    special = pa.table({"x": pa.array([float("nan"), float("inf"), float("-inf"), -0.0, None], pa.float64())})
    write("special_floats", special, use_dictionary=False, compression="NONE", data_page_version="1.0")

    pq.write_table(pa.table({"tags": pa.array([["a"], [], None], pa.list_(pa.string()))}),
                   HERE / "nested.parquet")
    pq.write_table(pa.table({"when": pa.array([1, 2], pa.timestamp("ns"))}), HERE / "int96.parquet",
                   use_deprecated_int96_timestamps=True)
    pq.write_table(pa.table({"id": pa.array([10, 11, 13, 17], pa.int64())}), HERE / "delta.parquet",
                   use_dictionary=False, compression="NONE", column_encoding={"id": "DELTA_BINARY_PACKED"})
    write_damaged()


def plain_one():
    table = pa.table({"v": pa.array([5, 6, 7, 8, 9, 10], pa.int64())})
    write("plain_one", table, use_dictionary=False, compression="NONE", data_page_version="1.0")
    return (HERE / "plain_one.parquet").read_bytes()


def write_damaged():
    data = plain_one()
    out = {
        "damaged_magic": b"X" + data[1:],
        "damaged_footer_past_start": data[:-8] + len(data).to_bytes(4, "little") + data[-4:],
        "damaged_page_offset": patch_footer(data, lambda column: set_field(column, [3], 9, len(data) + 100)),
        "damaged_chunk_size": patch_footer(data, lambda column: set_field(column, [3], 7, 10 ** 9)),
        "damaged_value_count": patch_footer(data, lambda column: set_field(column, [3], 5, 10 ** 6)),
        "damaged_page_compressed": patch_page(data, 3, 10 ** 6),
        "damaged_page_size": patch_page(data, 2, 3),
        "damaged_page_count": patch_page(data, 1, 10 ** 9, inner=5),
    }
    for name, content in out.items():
        (HERE / f"{name}.parquet").write_bytes(content)


# A Thrift compact struct as a list of [id, type, value]; types are those of the wire (1 and 2 are the booleans, 3 a
# byte, 4 to 6 integers, 7 a double, 8 binary, 9 a list, 12 a struct).
def uvarint(n):
    out = bytearray()
    while True:
        byte = n & 0x7F
        n >>= 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def read_uvarint(b, i):
    n = shift = 0
    while True:
        n |= (b[i] & 0x7F) << shift
        shift += 7
        i += 1
        if b[i - 1] < 0x80:
            return n, i


def parse_struct(b, i):
    fields, last = [], 0
    while True:
        head = b[i]
        i += 1
        if head == 0:
            return fields, i
        kind, delta = head & 15, head >> 4
        if delta:
            fid = last + delta
        else:
            code, i = read_uvarint(b, i)
            fid = (code >> 1) ^ -(code & 1)
        value, i = parse_value(b, i, kind)
        fields.append([fid, kind, value])
        last = fid


def parse_value(b, i, kind):
    if kind in (1, 2):
        return None, i
    if kind == 3:
        return b[i], i + 1
    if kind in (4, 5, 6):
        code, i = read_uvarint(b, i)
        return (code >> 1) ^ -(code & 1), i
    if kind == 7:
        return b[i:i + 8], i + 8
    if kind == 8:
        size, i = read_uvarint(b, i)
        return b[i:i + size], i + size
    if kind == 9:
        head = b[i]
        i += 1
        size, element = head >> 4, head & 15
        if size == 15:
            size, i = read_uvarint(b, i)
        items = []
        for _ in range(size):
            value, i = parse_value(b, i, element)
            items.append(value)
        return [element, items], i
    if kind == 12:
        return parse_struct(b, i)
    raise ValueError(f"thrift type {kind}")


def dump_struct(fields):
    out, last = bytearray(), 0
    for fid, kind, value in fields:
        if 0 < fid - last < 16:
            out.append(((fid - last) << 4) | kind)
        else:
            out.append(kind)
            out += uvarint(((fid << 1) ^ (fid >> 63)) & (2 ** 64 - 1))
        out += dump_value(kind, value)
        last = fid
    out.append(0)
    return bytes(out)


def dump_value(kind, value):
    if kind in (1, 2):
        return b""
    if kind == 3:
        return bytes([value])
    if kind in (4, 5, 6):
        return uvarint(((value << 1) ^ (value >> 63)) & (2 ** 64 - 1))
    if kind in (7,):
        return value
    if kind == 8:
        return uvarint(len(value)) + value
    if kind == 9:
        element, items = value
        head = bytes([(len(items) << 4) | element]) if len(items) < 15 else bytes([0xF0 | element]) + uvarint(len(items))
        return head + b"".join(dump_value(element, item) for item in items)
    return dump_struct(value)


def field(fields, fid):
    return next(f for f in fields if f[0] == fid)


def set_field(column, path, fid, number):
    """Sets the integer field `fid` of the struct at `path` (field ids of nested structs) in a column chunk struct."""
    fields = column
    for step in path:
        fields = field(fields, step)[2]
    field(fields, fid)[2] = number


def patch_footer(data, change):
    size = int.from_bytes(data[-8:-4], "little")
    footer, _ = parse_struct(data[-8 - size:-8], 0)
    groups = field(footer, 4)[2][1]
    change(field(groups[0], 1)[2][1][0])
    new = dump_struct(footer)
    return data[:-8 - size] + new + len(new).to_bytes(4, "little") + data[-4:]


def patch_page(data, fid, number, inner=None):
    """Rewrites the integer field `fid` of the page header at offset 4, or of its inner struct `inner`."""
    header, end = parse_struct(data, 4)
    target = header if inner is None else field(header, inner)[2]
    field(target, fid)[2] = number
    return data[:4] + dump_struct(header) + data[end:]


if __name__ == "__main__":
    main()
