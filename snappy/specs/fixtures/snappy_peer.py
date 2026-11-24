#!/usr/bin/env python3
"""The independent peer of the snappy package: an encoder and a decoder of the raw Snappy format, written from the
format description with the standard library only, so the Agentica codec is checked against code that shares no line
with it.

Modes (the first argument):
  valid SEED COUNT     one line per block: the block in hex, a tab, and the data it decodes to in hex. The blocks
                       mix every element (literals of any length, copies with one, two or four byte offsets,
                       overlapping copies); some of them start with a literal of 65536 bytes or more, so that a copy
                       can reach back past 65535 bytes.
  damaged SEED COUNT   one line per damaged block (cut, a byte changed, bytes added, the length changed): the block in
                       hex, a tab, and the data in hex, or `error` when the decoder refuses the block.
  decode               reads the blocks in hex on standard input, one per line, and prints the data of each in hex (or
                       `error`), one per line.
  noise SEED SIZE      SIZE random bytes from SEED, in hex: the inputs that the codec compresses in the specs.
"""

import random
import sys

MAX_LENGTH = 0xFFFFFFFF
BIG_LITERAL = (65_536, 70_000)
LITERAL_LENGTHS = (1, 2, 5, 59, 60, 61, 255, 256, 257, 300)


class Malformed(Exception):
    pass


def varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def literal(text):
    n = len(text) - 1
    if n < 60:
        head = bytes([n << 2])
    else:
        extra = (n.bit_length() + 7) // 8
        head = bytes([(59 + extra) << 2]) + n.to_bytes(extra, "little")
    return head + text


def copy(offset, length, rng):
    forms = []
    if 4 <= length <= 11 and offset < 2048:
        forms.append("copy1")
    if offset < 65536:
        forms.append("copy2")
    forms.append("copy4")
    form = rng.choice(forms)
    if form == "copy1":
        tag = 1 | ((length - 4) << 2) | ((offset >> 8) << 5)
        return bytes([tag, offset & 0xFF])
    if form == "copy2":
        return bytes([2 | ((length - 1) << 2)]) + offset.to_bytes(2, "little")
    return bytes([3 | ((length - 1) << 2)]) + offset.to_bytes(4, "little")


def random_offset(rng, produced, big):
    if big and produced > 65_536 and rng.random() < 0.5:
        return rng.randint(65_536, produced)
    if rng.random() < 0.5:
        return rng.randint(1, min(produced, 300))
    return rng.randint(1, produced)


def random_block(rng, big, alphabet):
    data = bytearray()
    elements = bytearray()

    def add_literal(length, pool=alphabet):
        text = bytes(rng.choice(pool) for _ in range(length))
        elements.extend(literal(text))
        data.extend(text)

    if big:
        add_literal(rng.randint(*BIG_LITERAL), pool=bytes(range(256)))
    add_literal(rng.choice(LITERAL_LENGTHS))
    for _ in range(rng.randint(2, 14)):
        if not data or rng.random() < 0.35:
            add_literal(rng.choice(LITERAL_LENGTHS))
            continue
        offset = random_offset(rng, len(data), big)
        length = rng.randint(1, 64)
        elements.extend(copy(offset, length, rng))
        for _ in range(length):
            data.append(data[-offset])
    return varint(len(data)) + bytes(elements), bytes(data)


def decode(block):
    pos = 0
    expected = 0
    shift = 0
    while True:
        if pos >= len(block) or pos >= 5:
            raise Malformed("preamble")
        byte = block[pos]
        pos += 1
        expected |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            break
    if expected > MAX_LENGTH:
        raise Malformed("length")

    out = bytearray()
    while pos < len(block):
        tag = block[pos]
        pos += 1
        kind = tag & 3
        if kind == 0:
            length = (tag >> 2) + 1
            if length > 60:
                extra = length - 60
                if pos + extra > len(block):
                    raise Malformed("literal length")
                length = int.from_bytes(block[pos:pos + extra], "little") + 1
                pos += extra
            if pos + length > len(block) or len(out) + length > expected:
                raise Malformed("literal")
            out.extend(block[pos:pos + length])
            pos += length
            continue
        if kind == 1:
            width = 1
        elif kind == 2:
            width = 2
        else:
            width = 4
        if pos + width > len(block):
            raise Malformed("copy")
        if kind == 1:
            length = 4 + ((tag >> 2) & 7)
            offset = ((tag >> 5) << 8) | block[pos]
        else:
            length = (tag >> 2) + 1
            offset = int.from_bytes(block[pos:pos + width], "little")
        pos += width
        if offset == 0 or offset > len(out) or len(out) + length > expected:
            raise Malformed("copy")
        for _ in range(length):
            out.append(out[-offset])

    if len(out) != expected:
        raise Malformed("length")
    return bytes(out)


def outcome(block):
    try:
        return decode(block).hex()
    except Malformed:
        return "error"


def damage(rng, block, data):
    choice = rng.randrange(4)
    if choice == 0:
        return block[:rng.randrange(len(block) + 1)]
    if choice == 1:
        i = rng.randrange(len(block))
        return block[:i] + bytes([block[i] ^ rng.randint(1, 255)]) + block[i + 1:]
    if choice == 2:
        return block + bytes(rng.randint(0, 255) for _ in range(rng.randint(1, 4)))
    body = block[len(varint(len(data))):]
    return varint(max(len(data) + rng.choice([-1, 1, 3, 200]), 0)) + body


def run_valid(seed, count):
    rng = random.Random(seed)
    for i in range(count):
        alphabet = bytes(range(256)) if i % 2 == 0 else b"abc\x00"
        block, data = random_block(rng, big=i % 3 == 0, alphabet=alphabet)
        print(f"{block.hex()}\t{data.hex()}")


def run_damaged(seed, count):
    rng = random.Random(seed)
    for _ in range(count):
        block, data = random_block(rng, big=False, alphabet=b"abcdefgh")
        damaged = damage(rng, block, data)
        print(f"{damaged.hex()}\t{outcome(damaged)}")


def run_decode():
    blocks = sys.stdin.read().split()
    print("\n".join(outcome(bytes.fromhex(block)) for block in blocks), end="")


def main(argv):
    mode = argv[1]
    if mode == "valid":
        run_valid(int(argv[2]), int(argv[3]))
    elif mode == "damaged":
        run_damaged(int(argv[2]), int(argv[3]))
    elif mode == "decode":
        run_decode()
    elif mode == "noise":
        print(random.Random(int(argv[2])).randbytes(int(argv[3])).hex(), end="")
    else:
        raise SystemExit(f"unknown mode {mode}")


if __name__ == "__main__":
    main(sys.argv)
