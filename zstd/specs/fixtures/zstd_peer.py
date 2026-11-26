#!/usr/bin/env python3
"""The independent peer of the zstd package: the reference `zstd` command line (libzstd), driven from the standard
library, writes the frames that the decoder reads and says what it makes of damaged ones. The tool must be installed:
a missing `zstd` fails the run.

Modes (the first argument):
  valid SEED COUNT    one line per frame: the frame in hex, a tab, and the SHA-256 of the data it holds in hex. The inputs are empty,
                      tiny, random, repetitive, made of words, with a far repeat, or several blocks long; the
                      options are levels 1, 3 and 19, `--ultra -22`, long distance matching, `--fast`, a small
                      window, a frame with no checksum and a frame with no content size.
  hand-made SEED 0    five frames written by hand: sequences whose tables are one repeated symbol, with raw and RLE
                      literals, a count of 20, 200 and 32600 sequences (the three forms of the count), and one frame
                      of repeated offsets with no literals.
  columnar SEED COUNT  one line per frame of 1 to 3 MB of a column as a Parquet writer lays it out (int64 runs, float64,
                      dictionary indexes, repeated strings) at levels 1, 3 and 9: the frame and the SHA-256 of the data.
  arrow SEED COUNT     one line per frame written as Arrow writes a page (one segment, the content size and no
                      checksum): the frame, the SHA-256 of the data and its size.
  version              the version of the `zstd` command line.
  multi SEED COUNT    the same lines for several frames that follow each other, with skippable frames between some
                      of them: the data is the content of every frame, one after the other.
  damaged SEED COUNT  one line per damaged frame (cut, a bit flipped, a byte changed, bytes added): the frame in hex,
                      a tab, and the SHA-256 of the data in hex, or `error` when `zstd -d` refuses it.
"""

import hashlib
import random
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

LEVELS = (
    ["-1"],
    ["-3"],
    ["-19"],
    ["--ultra", "-22"],
    ["--long=27", "-3"],
    ["--fast=3"],
    ["-3", "--zstd=wlog=10"],
    ["-5", "--no-check"],
    ["-19", "--check"],
    ["-9", "--zstd=strategy=2"],
)
KINDS = ("empty", "tiny", "random", "repeat", "words", "far", "runs", "long", "skewed", "small")
WORDS = [bytes(random.Random(n).choices(b"abcdefghijklmnop", k=random.Random(n + 99).randint(2, 9))) for n in range(300)]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def make_input(rng, kind):
    if kind == "empty":
        return b""
    if kind == "tiny":
        return rng.randbytes(rng.randint(1, 20))
    if kind == "random":
        return rng.randbytes(rng.randint(200, 3000))
    if kind == "repeat":
        return rng.randbytes(rng.randint(1, 7)) * rng.randint(2, 4000)
    if kind == "words":
        return b" ".join(rng.choice(WORDS) for _ in range(rng.randint(40, 2500)))
    if kind == "far":
        block = rng.randbytes(15_000)
        return block + rng.randbytes(30_000) + block
    if kind == "runs":
        out = bytearray()
        while len(out) < 20_000:
            out += bytes([rng.randrange(256)]) * rng.randint(1, 400)
            out += b" ".join(rng.choice(WORDS) for _ in range(rng.randint(0, 20)))
        return bytes(out)
    if kind == "skewed":
        return bytes(rng.choices(b"etaoinshrdlu", weights=[12, 9, 8, 7, 6, 6, 6, 5, 4, 3, 2, 1], k=rng.randint(300, 4000)))
    if kind == "small":
        size = rng.randint(3, 16)
        return bytes(rng.choices(range(size), weights=[1 + i % 3 for i in range(size)], k=rng.randint(300, 3000)))
    words = b" ".join(rng.choice(WORDS) for _ in range(40_000))
    return words[:140_000]


def zstd(args, data):
    return subprocess.run(["zstd", "-q", "-c", *args], input=data, capture_output=True, check=False)


def compress(rng, data, options):
    if rng.random() < 0.5:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "input"
            path.write_bytes(data)
            done = subprocess.run(["zstd", "-q", "-c", *options, str(path)], capture_output=True, check=True)
        return done.stdout
    return subprocess.run(["zstd", "-q", "-c", *options], input=data, capture_output=True, check=True).stdout


def skippable(rng):
    payload = rng.randbytes(rng.randint(0, 40))
    return (0x184D2A50 + rng.randrange(16)).to_bytes(4, "little") + len(payload).to_bytes(4, "little") + payload


def literals_header(size, rle):
    kind = 1 if rle else 0
    if size < 32:
        return bytes([size << 3 | kind])
    if size < 4096:
        return (size << 4 | 1 << 2 | kind).to_bytes(2, "little")
    return (size << 4 | 3 << 2 | kind).to_bytes(3, "little")


def sequence_count(count):
    if count < 128:
        return bytes([count])
    if count < 0x7F00:
        return bytes([(count >> 8) + 128, count & 255])
    return bytes([255]) + (count - 0x7F00).to_bytes(2, "little")


def hand_made(rng, count, rle_literals):
    """A frame of `count` sequences that each write one literal and then three bytes copied from 1 to 4 bytes back.
    The three tables are one repeated symbol (mode 1), so the bits of the stream are the 2 extra bits of the offset
    of each sequence, the first one decoded just under the end mark."""
    literals = bytes([rng.randrange(256)]) * count if rle_literals else rng.randbytes(count)
    out = bytearray()
    bits = ""
    for i in range(count):
        out.append(literals[i])
        back = rng.randint(0, min(3, len(out) - 1))
        bits += format(back, "02b")
        for _ in range(3):
            out.append(out[-(back + 1)])
    stream = int("1" + bits, 2)
    stream = stream.to_bytes((stream.bit_length() + 7) // 8, "little")
    block = literals_header(count, rle_literals) + (literals[:1] if rle_literals else literals)
    block += sequence_count(count) + bytes([0b01010100, 1, 2, 0]) + stream
    header = (len(block) << 3 | 2 << 1 | 1).to_bytes(3, "little")
    frame = bytes.fromhex("28b52ffd") + bytes([0xA0]) + len(out).to_bytes(4, "little") + header + block
    return frame, bytes(out)


def hand_made_repeat(rng, count):
    """A raw block of 8 bytes, then a block of `count` sequences with no literals, each with the offset code 1 and one
    extra bit: the repeated offsets of RFC 8878 section 3.1.1.5 for a literals length of 0, which are the third
    repeated offset and the first one less one. The model of those rules is written here again, from the RFC."""
    out = bytearray(rng.randbytes(8))
    reps = [1, 4, 8]
    bits = ""
    for _ in range(count):
        bit = rng.randrange(2)
        if bit == 1 and reps[0] == 1:
            bit = 0
        bits += str(bit)
        offset = reps[0] - 1 if bit == 1 else reps[2]
        reps = [offset, reps[0], reps[1]]
        for _ in range(3):
            out.append(out[-offset])
    stream = int("1" + bits, 2)
    stream = stream.to_bytes((stream.bit_length() + 7) // 8, "little")
    block = bytes([0]) + sequence_count(count) + bytes([0b01010100, 0, 1, 0]) + stream
    raw = (8 << 3).to_bytes(3, "little") + out[:8]
    header = (len(block) << 3 | 2 << 1 | 1).to_bytes(3, "little")
    frame = bytes.fromhex("28b52ffd") + bytes([0xA0]) + len(out).to_bytes(4, "little") + raw + header + block
    return frame, bytes(out)


COLUMNS = ("int64 runs", "float64", "dictionary indexes", "repeated strings")


def columnar(rng, kind):
    """A column as a Parquet writer lays it out, between 1 and 3 MB."""
    if kind == "int64 runs":
        value, out = rng.randrange(1 << 40), bytearray()
        while len(out) < rng.randint(1_000_000, 3_000_000):
            value += rng.choice((0, 0, 1, 1, 2, 7))
            out += struct.pack("<q", value) * rng.randint(1, 200)
        return bytes(out)
    if kind == "float64":
        prices = [round(rng.uniform(0, 500), 2) for _ in range(rng.randint(20, 120))]
        out = bytearray()
        while len(out) < rng.randint(1_000_000, 3_000_000):
            out += struct.pack("<d", rng.choice(prices)) * rng.randint(1, 12)
        return bytes(out)
    if kind == "dictionary indexes":
        out, index = bytearray(), 0
        while len(out) < rng.randint(1_000_000, 3_000_000):
            index = rng.randrange(40) if rng.random() < 0.04 else index
            out.append(index)
        return bytes(out)
    words = [bytes(rng.choices(b"abcdefghijklmnopqrstuvwxyz", k=rng.randint(3, 14))) for _ in range(30)]
    rows = [b"".join(struct.pack("<I", len(w)) + w for w in rng.choices(words, k=rng.randint(1, 4))) for _ in range(40)]
    out = bytearray()
    while len(out) < rng.randint(1_000_000, 3_000_000):
        out += rng.choice(rows)
    return bytes(out)


def run_columnar(seed, count):
    rng = random.Random(seed)
    for i in range(count):
        data = columnar(rng, COLUMNS[(seed + i) % len(COLUMNS)])
        level = ("-1", "-3", "-9")[(seed * 7 + i) % 3]
        print(f"{compress(rng, data, [level]).hex()}\t{digest(data)}")


def run_arrow(seed, count):
    """What Arrow writes for a page: one segment, the content size in the header and no checksum."""
    rng = random.Random(seed)
    for i in range(count):
        data = columnar(rng, COLUMNS[i % len(COLUMNS)])[: rng.randint(2_000, 60_000)]
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "page"
            path.write_bytes(data)
            frame = subprocess.run(["zstd", "-q", "-c", "-3", "--no-check", str(path)], capture_output=True, check=True).stdout
        assert frame[4] & 0x24 == 0x20, "not a single segment frame with no checksum"
        print(f"{frame.hex()}\t{digest(data)}\t{len(data)}")


def run_hand_made(seed, count):
    rng = random.Random(seed)
    for sequences, rle in ((20, False), (200, False), (200, True), (32600, True)):
        frame, data = hand_made(rng, sequences, rle)
        print(f"{frame.hex()}\t{digest(data)}")
    frame, data = hand_made_repeat(rng, 40)
    print(f"{frame.hex()}\t{digest(data)}")


def run_valid(seed, count):
    rng = random.Random(seed)
    for i in range(count):
        kind = KINDS[i % len(KINDS)]
        options = LEVELS[(i * 3 + seed) % len(LEVELS)]
        data = make_input(rng, kind)
        print(f"{compress(rng, data, options).hex()}\t{digest(data)}")


def run_multi(seed, count):
    rng = random.Random(seed)
    for _ in range(count):
        frames = bytearray()
        content = bytearray()
        for _ in range(rng.randint(2, 4)):
            data = make_input(rng, rng.choice(KINDS[:5]))
            frames += compress(rng, data, rng.choice(LEVELS))
            content += data
            if rng.random() < 0.4:
                frames += skippable(rng)
        print(f"{bytes(frames).hex()}\t{digest(bytes(content))}")


def damage(rng, frame):
    choice = rng.randrange(5)
    if choice == 0:
        return frame[:rng.randrange(len(frame))]
    if choice == 1 or choice == 2:
        i = rng.randrange(len(frame))
        return frame[:i] + bytes([frame[i] ^ (1 << rng.randrange(8))]) + frame[i + 1:]
    if choice == 3:
        i = rng.randrange(len(frame))
        return frame[:i] + bytes([rng.randrange(256)]) + frame[i + 1:]
    return frame + rng.randbytes(rng.randint(1, 4))


def outcome(frame):
    done = zstd(["-d", "--long=31"], frame)
    return digest(done.stdout) if done.returncode == 0 else "error"


def run_damaged(seed, count):
    rng = random.Random(seed)
    for i in range(count):
        data = make_input(rng, ("words", "runs", "random", "repeat")[i % 4])[:2500]
        frame = compress(rng, data, rng.choice(LEVELS))
        damaged = damage(rng, frame)
        print(f"{damaged.hex()}\t{outcome(damaged)}")


def main(argv):
    mode = argv[1]
    if mode == "valid":
        run_valid(int(argv[2]), int(argv[3]))
    elif mode == "hand-made":
        run_hand_made(int(argv[2]), int(argv[3]))
    elif mode == "columnar":
        run_columnar(int(argv[2]), int(argv[3]))
    elif mode == "arrow":
        run_arrow(int(argv[2]), int(argv[3]))
    elif mode == "version":
        print(subprocess.run(["zstd", "--version"], capture_output=True, check=True).stdout.decode().strip())
    elif mode == "multi":
        run_multi(int(argv[2]), int(argv[3]))
    elif mode == "damaged":
        run_damaged(int(argv[2]), int(argv[3]))
    else:
        raise SystemExit(f"unknown mode {mode}")


if __name__ == "__main__":
    main(sys.argv)
