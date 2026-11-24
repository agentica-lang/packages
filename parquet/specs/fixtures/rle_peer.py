"""An independent encoder of the Parquet RLE / bit-packed hybrid, for the specs. Standard library only.

  python3 -I rle_peer.py SEED WIDTH COUNT

It prints two lines: the hex of the encoded bytes, then the values, comma-separated. Runs of equal values become RLE
runs; the rest is packed in groups of eight, least significant bit first.
"""

import random
import sys


def varint(number):
    out = bytearray()
    while True:
        byte = number & 0x7F
        number >>= 7
        if number:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def encode(values, width):
    size = (width + 7) // 8
    out = bytearray()
    i = 0
    while i < len(values):
        j = i
        while j < len(values) and values[j] == values[i]:
            j += 1
        if j - i >= 8:
            out += varint((j - i) << 1)
            out += values[i].to_bytes(size, "little")
            i = j
            continue
        group = values[i:i + 8] + [0] * (8 - len(values[i:i + 8]))
        bits = 0
        for k, value in enumerate(group):
            bits |= value << (k * width)
        out += varint((1 << 1) | 1)
        out += bits.to_bytes(width, "little")
        i += 8
    return bytes(out)


def main():
    seed, width, count = (int(a) for a in sys.argv[1:4])
    rng = random.Random(seed)
    top = (1 << width) - 1
    values = []
    while len(values) < count:
        value = rng.randint(0, top)
        values += [value] * rng.choice([1, 2, 9, 20]) if rng.random() < 0.5 else [value]
    values = values[:count]
    print(encode(values, width).hex())
    print(",".join(str(v) for v in values))


if __name__ == "__main__":
    main()
