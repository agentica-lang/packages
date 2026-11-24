#!/usr/bin/env python3
"""An independent PNG codec on the standard library (zlib, struct), the peer of image's specs.

  peer.py generate DIR        writes the fixtures: each PNG with the raw pixels it holds (NAME.raw), and a float ramp
  peer.py decode IN.png OUT   decodes a PNG into raw pixels (interleaved, little endian) and prints "WIDTH HEIGHT BANDS"

The scanlines of the PNGs use every filter type, so the decoder of libvips is checked on each.
"""
import struct
import sys
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"
# colour type -> bands
BANDS = {0: 1, 2: 3, 6: 4}


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def predictor(filter_type, left, up, upleft):
    return (0, left, up, (left + up) // 2, paeth(left, up, upleft))[filter_type]


def encode(width, height, color, depth, raw):
    """raw: interleaved samples, big endian for 16 bits, as the PNG holds them."""
    step = BANDS[color] * depth // 8
    stride = width * step
    out = bytearray()
    for y in range(height):
        row = raw[y * stride:(y + 1) * stride]
        above = raw[(y - 1) * stride:y * stride] if y else bytes(stride)
        filter_type = y % 5
        out.append(filter_type)
        for x in range(stride):
            left = row[x - step] if x >= step else 0
            upleft = above[x - step] if x >= step else 0
            out.append((row[x] - predictor(filter_type, left, above[x], upleft)) & 255)
    header = struct.pack(">IIBBBBB", width, height, depth, color, 0, 0, 0)
    return SIGNATURE + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(out))) + chunk(b"IEND", b"")


def decode(png):
    assert png[:8] == SIGNATURE
    pos, data = 8, b""
    while pos < len(png):
        (length,) = struct.unpack(">I", png[pos:pos + 4])
        kind, body = png[pos + 4:pos + 8], png[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert interlace == 0 and color in BANDS and depth in (8, 16)
        elif kind == b"IDAT":
            data += body
        pos += 12 + length
    step = BANDS[color] * depth // 8
    stride = width * step
    data = zlib.decompress(data)
    raw = bytearray()
    for y in range(height):
        filter_type = data[y * (stride + 1)]
        row = bytearray(data[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        above = raw[(y - 1) * stride:y * stride] if y else bytes(stride)
        for x in range(stride):
            left = row[x - step] if x >= step else 0
            upleft = above[x - step] if x >= step else 0
            row[x] = (row[x] + predictor(filter_type, left, above[x], upleft)) & 255
        raw += row
    return width, height, BANDS[color], depth, bytes(raw)


def little_endian(raw, depth):
    if depth == 8:
        return raw
    return b"".join(raw[i + 1:i + 2] + raw[i:i + 1] for i in range(0, len(raw), 2))


def gradient(width, height, bands, depth):
    top = (1 << depth) - 1
    samples = [
        (x * 37 + y * 11 + band * 71 + (x * y) % 13) * top // 600 % (top + 1)
        for y in range(height) for x in range(width) for band in range(bands)
    ]
    if depth == 8:
        return bytes(samples)
    return b"".join(struct.pack(">H", s) for s in samples)


def generate(folder):
    for name, width, height, color, depth in (
        ("rgb", 16, 12, 2, 8),
        ("rgba", 9, 7, 6, 8),
        ("gray16", 8, 6, 0, 16),
    ):
        raw = gradient(width, height, BANDS[color], depth)
        png = encode(width, height, color, depth, raw)
        assert decode(png) == (width, height, BANDS[color], depth, raw)
        with open(f"{folder}/{name}.png", "wb") as f:
            f.write(png)
        with open(f"{folder}/{name}.raw", "wb") as f:
            f.write(little_endian(raw, depth))
    with open(f"{folder}/ramp_f32.raw", "wb") as f:
        f.write(struct.pack("<24f", *[(i - 8) / 4 + 0.0625 * i for i in range(24)]))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "generate":
        generate(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "decode":
        with open(sys.argv[2], "rb") as f:
            width, height, bands, depth, raw = decode(f.read())
        with open(sys.argv[3], "wb") as f:
            f.write(little_endian(raw, depth))
        print(width, height, bands)
    else:
        sys.exit(__doc__)


main()
