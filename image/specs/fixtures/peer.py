#!/usr/bin/env python3
"""An independent PNG codec and image transforms on the standard library, the peer of image's specs.

  peer.py generate DIR        writes the fixtures: each PNG with the raw pixels it holds (NAME.raw), and more raw ones
  peer.py decode IN.png OUT   decodes a PNG into raw pixels (little endian) and prints "WIDTH HEIGHT BANDS"
  peer.py apply OP IN OUT WIDTH HEIGHT BANDS [ARG...]
                              the expected pixels of a transform of raw pixels, and prints "WIDTH HEIGHT BANDS"
                              of the result. For u8 samples: crop LEFT TOP W H, flip h|v, rotate DEGREES
                              clockwise, resize W H [KERNEL], grey. For grey (and alpha) of u8 or u16: srgb [BYTES PER
                              SAMPLE]. For any raw samples: cast FROM TO (u8, u16, i16 or f32)

The scanlines of the PNGs use every filter type, so the decoder of libvips is checked on each.
"""
import math
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
    with open(f"{folder}/grey.raw", "wb") as f:
        f.write(gradient(10, 6, 1, 8))
    with open(f"{folder}/photo.raw", "wb") as f:
        f.write(gradient(64, 48, 3, 8))
    with open(f"{folder}/ramp_f32.raw", "wb") as f:
        f.write(struct.pack("<24f", *[(i - 8) / 4 + 0.0625 * i for i in range(24)]))


def crop(px, width, bands, left, top, w, h):
    return [px[((top + y) * width + left + x) * bands + b] for y in range(h) for x in range(w) for b in range(bands)]


def flip(px, width, height, bands, axis):
    cols = range(width - 1, -1, -1) if axis == "h" else range(width)
    rows = range(height - 1, -1, -1) if axis == "v" else range(height)
    return [px[(y * width + x) * bands + b] for y in rows for x in cols for b in range(bands)]


def rotate(px, width, height, bands, degrees):
    """Clockwise; a quarter turn takes the bottom row to the left column."""
    for _ in range(degrees // 90 % 4):
        px = [px[((height - 1 - y) * width + x) * bands + b] for x in range(width) for y in range(height)
              for b in range(bands)]
        width, height = height, width
    return px, width, height


def lanczos(a, x):
    if x == 0:
        return 1.0
    if abs(x) >= a:
        return 0.0
    return a * math.sin(math.pi * x) * math.sin(math.pi * x / a) / (math.pi * x) ** 2


def linear(x):
    return max(0.0, 1 - abs(x))


def cubic(x):
    """Catmull-Rom, the cubic of libvips."""
    x = abs(x)
    if x < 1:
        return 1.5 * x ** 3 - 2.5 * x ** 2 + 1
    return -0.5 * x ** 3 + 2.5 * x ** 2 - 4 * x + 2 if x < 2 else 0.0


# The interpolating kernels of resize: the half width of each, and its function.
KERNELS = {
    "linear": (1, linear),
    "cubic": (2, cubic),
    "lanczos2": (2, lambda x: lanczos(2, x)),
    "lanczos3": (3, lambda x: lanczos(3, x)),
}


def weights(size_in, size_out, kernel):
    """For each output index, the input indices and the normalised weights of the kernel; it widens by the shrink
    factor, as libvips does when it reduces."""
    support, function = KERNELS[kernel]
    scale = size_in / size_out
    stretch = max(scale, 1.0)
    rows = []
    for o in range(size_out):
        center = (o + 0.5) * scale - 0.5
        first = math.floor(center - support * stretch) + 1
        last = math.ceil(center + support * stretch) - 1
        taps = [(max(0, min(size_in - 1, i)), function((i - center) / stretch)) for i in range(first, last + 1)]
        total = sum(w for _, w in taps)
        rows.append([(i, w / total) for i, w in taps])
    return rows


def box(px, width, height, bands, across, down):
    """The mean of each `across` by `down` block, rounded, as the integer shrink of libvips."""
    assert width % across == 0 and height % down == 0, "the shrink must divide the size"
    out = []
    for y in range(height // down):
        for x in range(width // across):
            for b in range(bands):
                total = sum(px[((y * down + j) * width + x * across + i) * bands + b]
                            for j in range(down) for i in range(across))
                out.append((total + across * down // 2) // (across * down))
    return out, width // across, height // down


def nearest(px, width, height, bands, w, h):
    """The source pixel at the centre of each output pixel. libvips rounds the positions to a fixed-point mask, so
    this holds only for sizes that divide the source or that it divides."""
    return [px[(math.floor((y + 0.5) * height / h) * width + math.floor((x + 0.5) * width / w)) * bands + b]
            for y in range(h) for x in range(w) for b in range(bands)]


def resize(px, width, height, bands, w, h, kernel="lanczos3"):
    """The resize of libvips, the way it does it: an integer shrink by a box mean while the shrink is at
    least twice the gap of 2 (a block per output pixel on each side), then the reduce with the kernel, the rows
    before the columns, each pass rounded and clamped to u8."""
    if kernel == "nearest":
        return nearest(px, width, height, bands, w, h)
    px, width, height = box(px, width, height, bands, max(1, width // w // 2), max(1, height // h // 2))
    down = weights(height, h, kernel)
    across = weights(width, w, kernel)

    def quantise(v):
        return max(0, min(255, int(v + 0.5)))

    tall = [[quantise(sum(px[(i * width + x) * bands + b] * k for i, k in down[y])) for b in range(bands)]
            for y in range(h) for x in range(width)]
    return [quantise(sum(tall[y * width + i][b] * k for i, k in across[x]))
            for y in range(h) for x in range(w) for b in range(bands)]


def grey(px, bands):
    """sRGB to grey as libvips does it: the luminance of the linear light, encoded again; alpha is kept."""
    def linear(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4

    out = []
    for i in range(0, len(px), bands):
        y = 0.2126 * linear(px[i]) + 0.7152 * linear(px[i + 1]) + 0.0722 * linear(px[i + 2])
        v = 12.92 * y if y <= 0.0031308 else 1.055 * y ** (1 / 2.4) - 0.055
        out += [int(v * 255 + 0.5)] + px[i + 3:i + bands]
    return out


CODES = {"u8": "B", "u16": "H", "i16": "h", "f32": "f"}
RANGES = {"u8": (0, 255), "u16": (0, 65535), "i16": (-32768, 32767)}


def cast(data, source, target):
    values = struct.unpack("<%d%s" % (len(data) // struct.calcsize(CODES[source]), CODES[source]), data)
    if target == "f32":
        converted = [float(v) for v in values]
    else:
        low, top = RANGES[target]
        converted = [max(low, min(top, int(v))) for v in values]
    return struct.pack("<%d%s" % (len(converted), CODES[target]), *converted)


def apply(op, args):
    source, target, width, height, bands = args[0], args[1], int(args[2]), int(args[3]), int(args[4])
    rest = args[5:]
    with open(source, "rb") as f:
        data = f.read()
    shape = (width, height, bands)
    if op == "cast":
        out = cast(data, rest[0], rest[1])
    else:
        px = list(data)
        if op == "crop":
            left, top, w, h = map(int, rest)
            out, shape = crop(px, width, bands, left, top, w, h), (w, h, bands)
        elif op == "flip":
            out = flip(px, width, height, bands, rest[0])
        elif op == "rotate":
            out, w, h = rotate(px, width, height, bands, int(rest[0]))
            shape = (w, h, bands)
        elif op == "resize":
            w, h = int(rest[0]), int(rest[1])
            out, shape = resize(px, width, height, bands, w, h, *rest[2:]), (w, h, bands)
        elif op == "grey":
            out, shape = grey(px, bands), (width, height, bands - 2 if bands > 2 else 1)
        elif op == "srgb":
            size = int(rest[0]) if rest else 1
            step = bands * size
            out = b"".join(bytes(px[i:i + size]) * 3 + bytes(px[i + size:i + step]) for i in range(0, len(px), step))
            shape = (width, height, 2 + bands)
        else:
            sys.exit(__doc__)
        out = bytes(out)
    with open(target, "wb") as f:
        f.write(out)
    print(*shape)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "generate":
        generate(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "decode":
        with open(sys.argv[2], "rb") as f:
            width, height, bands, depth, raw = decode(f.read())
        with open(sys.argv[3], "wb") as f:
            f.write(little_endian(raw, depth))
        print(width, height, bands)
    elif len(sys.argv) >= 7 and sys.argv[1] == "apply":
        apply(sys.argv[2], sys.argv[3:])
    else:
        sys.exit(__doc__)


main()
