#!/usr/bin/env python3
"""The independent peer of the dns package: its own encoder and decoder of RFC 1035 messages, written with the standard
library only, so the Agentica codec is checked against code that does not share a line with it.

Modes (the first argument):
  generate SEED COUNT   one line per random message: the message in hex, a tab, and the canonical text of what the
                        encoder put in it. The names are compressed at random, and pointers chain.
  mutate SEED COUNT     the same, but each message is damaged (cut, a byte changed, a pointer put in, bytes added),
                        and the text is `error` when the peer's decoder refuses it.
  decode                reads one hex message per line on standard input and prints its canonical text, or `error:` and
                        why for a message that breaks the format.

The canonical text is the common ground of both sides: the flags and the counts as `key=value`, then each question and
record on its own ` ; ` part. A name is text with `\\.`, `\\\\` and `\\DDD` escapes (RFC 4343), a type and a class are
numbers, an address is the text of `ipaddress`, and the data of any type that is not decoded is `RAW:` and its hex.
"""

import ipaddress
import random
import struct
import sys

TYPE_A, TYPE_NS, TYPE_CNAME, TYPE_PTR, TYPE_AAAA = 1, 2, 5, 12, 28
NAME_TYPES = {TYPE_CNAME: "CNAME", TYPE_NS: "NS", TYPE_PTR: "PTR"}
# Types whose data the decoder keeps as raw bytes: TXT, MX, SRV and one that nobody knows.
RAW_TYPES = [16, 15, 33, 65280]


class Malformed(Exception):
    pass


def escape_label(label):
    out = []
    for byte in label:
        if byte in (0x2E, 0x5C):
            out.append("\\" + chr(byte))
        elif 33 <= byte <= 126:
            out.append(chr(byte))
        else:
            out.append("\\%03d" % byte)
    return "".join(out)


def ipv6_text(data):
    groups = [int.from_bytes(data[i : i + 2], "big") for i in range(0, 16, 2)]
    best, best_size, index = -1, 0, 0
    while index < 8:
        size = 0
        while index + size < 8 and groups[index + size] == 0:
            size += 1
        if size > best_size:
            best, best_size = index, size
        index += size + 1
    shown = lambda items: ":".join("%x" % item for item in items)
    if best_size < 2:
        text = shown(groups)
    else:
        text = shown(groups[:best]) + "::" + shown(groups[best + best_size :])
    reference = str(ipaddress.IPv6Address(bytes(data)))
    assert "." in reference or reference == text, (reference, text)
    return text


def name_text(labels):
    return ".".join(escape_label(label) for label in labels)


# --- the encoder -----------------------------------------------------------------------------------------------


class Encoder:
    def __init__(self, rng):
        self.rng = rng
        self.out = bytearray()
        self.seen = {}

    def name(self, labels, compress=True):
        # A suffix that was written before may be a pointer; the choice is random. Every suffix of the whole name is
        # remembered at the place of its first label, so a pointer can land inside a name that itself ends with a
        # pointer.
        labels = list(labels)
        cut = len(labels)
        target = None
        for index in range(len(labels)):
            suffix = tuple(label.lower() for label in labels[index:])
            if compress and suffix in self.seen and self.rng.random() < 0.8:
                cut = index
                target = self.seen[suffix]
                break
        position = len(self.out)
        for index in range(cut):
            suffix = tuple(item.lower() for item in labels[index:])
            if position < 0x4000 and suffix not in self.seen:
                self.seen[suffix] = position
            self.out += bytes([len(labels[index])]) + labels[index]
            position += 1 + len(labels[index])
        if target is None:
            self.out += b"\x00"
        else:
            self.out += struct.pack(">H", 0xC000 | target)

    def question(self, labels, kind, klass):
        self.name(labels)
        self.out += struct.pack(">HH", kind, klass)

    def record(self, labels, kind, klass, ttl, data):
        self.name(labels)
        self.out += struct.pack(">HHI", kind, klass, ttl)
        length_at = len(self.out)
        self.out += b"\x00\x00"
        if isinstance(data, list):
            self.name(data)
        else:
            self.out += data
        struct.pack_into(">H", self.out, length_at, len(self.out) - length_at - 2)


# --- the decoder -----------------------------------------------------------------------------------------------


def read_name(data, position):
    labels = []
    after = None
    jumps = 0
    size = 1
    while True:
        if position >= len(data):
            raise Malformed("name past the end")
        length = data[position]
        if length == 0:
            return labels, (position + 1 if after is None else after)
        if length & 0xC0 == 0xC0:
            if position + 1 >= len(data):
                raise Malformed("pointer past the end")
            target = ((length & 0x3F) << 8) | data[position + 1]
            if after is None:
                after = position + 2
            if target >= position:
                raise Malformed("pointer does not go back")
            jumps += 1
            if jumps > 32:
                raise Malformed("too many pointers")
            position = target
        elif length & 0xC0:
            raise Malformed("reserved label type")
        else:
            if position + 1 + length > len(data):
                raise Malformed("label past the end")
            size += 1 + length
            if size > 255:
                raise Malformed("name over 255 bytes")
            labels.append(bytes(data[position + 1 : position + 1 + length]))
            position += 1 + length


def decode(data):
    if len(data) < 12:
        raise Malformed("short message")
    ident, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", data[:12])
    position = 12
    parts = []
    for _ in range(qd):
        labels, position = read_name(data, position)
        kind, klass = struct.unpack(">HH", data[position : position + 4])
        position += 4
        parts.append("Q %s %d %d" % (name_text(labels), kind, klass))
    for tag, count in (("AN", an), ("NS", ns), ("AR", ar)):
        for _ in range(count):
            labels, position = read_name(data, position)
            kind, klass, ttl, length = struct.unpack(">HHIH", data[position : position + 10])
            position += 10
            end = position + length
            if end > len(data):
                raise Malformed("data past the end")
            if ttl >= 0x80000000:
                ttl = 0
            parts.append("%s %s %d %d %d %s" % (tag, name_text(labels), kind, klass, ttl, rdata_text(data, kind, position, end)))
            position = end
    head = "id=%d qr=%d op=%d aa=%d tc=%d rd=%d ra=%d rcode=%d" % (
        ident,
        flags >> 15,
        (flags >> 11) & 15,
        (flags >> 10) & 1,
        (flags >> 9) & 1,
        (flags >> 8) & 1,
        (flags >> 7) & 1,
        flags & 15,
    )
    return " ; ".join([head] + parts)


def rdata_text(data, kind, start, end):
    if kind == TYPE_A:
        if end - start != 4:
            raise Malformed("A is not 4 bytes")
        return "A:" + str(ipaddress.IPv4Address(bytes(data[start:end])))
    if kind == TYPE_AAAA:
        if end - start != 16:
            raise Malformed("AAAA is not 16 bytes")
        return "AAAA:" + ipv6_text(data[start:end])
    if kind in NAME_TYPES:
        labels, after = read_name(data, start)
        if after != end:
            raise Malformed("name does not fill the data")
        return NAME_TYPES[kind] + ":" + name_text(labels)
    return "RAW:" + bytes(data[start:end]).hex()


# --- random messages -------------------------------------------------------------------------------------------

ALPHABET = list(b"abcdefghijklmnopqrstuvwxyz0123456789-")
ODD = [0x2E, 0x5C, 0x20, 0x00, 0x7F, 0xC8, 0xFF, 0x41]


def random_label(rng, pool):
    if pool and rng.random() < 0.5:
        return rng.choice(pool)
    size = rng.randint(1, 12)
    label = bytes(rng.choice(ALPHABET) for _ in range(size))
    if rng.random() < 0.15:
        label = label + bytes([rng.choice(ODD)])
    if rng.random() < 0.05:
        label = bytes(rng.choice(ALPHABET) for _ in range(63))
    pool.append(label)
    return label


def random_name(rng, pool):
    while True:
        labels = [random_label(rng, pool) for _ in range(rng.randint(0, 4))]
        if 1 + sum(1 + len(label) for label in labels) <= 255:
            return labels


def random_address(rng, size):
    if size == 4:
        return bytes(rng.randint(0, 255) for _ in range(4))
    # Mostly zero groups, so that the longest run of zeros has to be found.
    groups = [rng.choice([0, 0, 0, 1, 0xFFFF, rng.randint(0, 0xFFFF)]) for _ in range(size // 2)]
    return b"".join(struct.pack(">H", group) for group in groups)


def random_message(rng):
    encoder = Encoder(rng)
    pool = []
    flags = rng.randint(0, 0xFFFF)
    ident = rng.randint(0, 0xFFFF)
    counts = [rng.randint(0, 2), rng.randint(0, 5), rng.randint(0, 3), rng.randint(0, 3)]
    encoder.out += struct.pack(">HHHHHH", ident, flags, *counts)
    parts = []
    for _ in range(counts[0]):
        labels = random_name(rng, pool)
        kind, klass = rng.choice([1, 28, 5, 255, 65280]), rng.choice([1, 3, 255])
        encoder.question(labels, kind, klass)
        parts.append("Q %s %d %d" % (name_text(labels), kind, klass))
    for tag, count in zip(("AN", "NS", "AR"), counts[1:]):
        for _ in range(count):
            labels = random_name(rng, pool)
            kind = rng.choice([TYPE_A, TYPE_AAAA, TYPE_CNAME, TYPE_NS, TYPE_PTR] + RAW_TYPES)
            klass = rng.choice([1, 1, 1, 3, 254])
            ttl = rng.choice([0, 1, 300, 86400, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, rng.randint(0, 0xFFFFFFFF)])
            if kind == TYPE_A:
                data = random_address(rng, 4)
                text = "A:" + str(ipaddress.IPv4Address(data))
            elif kind == TYPE_AAAA:
                data = random_address(rng, 16)
                text = "AAAA:" + ipv6_text(data)
            elif kind in NAME_TYPES:
                data = random_name(rng, pool)
                text = NAME_TYPES[kind] + ":" + name_text(data)
            else:
                data = bytes(rng.randint(0, 255) for _ in range(rng.randint(0, 20)))
                text = "RAW:" + data.hex()
            encoder.record(labels, kind, klass, ttl, data)
            shown = 0 if ttl >= 0x80000000 else ttl
            parts.append("%s %s %d %d %d %s" % (tag, name_text(labels), kind, klass, shown, text))
    head = "id=%d qr=%d op=%d aa=%d tc=%d rd=%d ra=%d rcode=%d" % (
        ident,
        flags >> 15,
        (flags >> 11) & 15,
        (flags >> 10) & 1,
        (flags >> 9) & 1,
        (flags >> 8) & 1,
        (flags >> 7) & 1,
        flags & 15,
    )
    return bytes(encoder.out), " ; ".join([head] + parts)


def generate(seed, count):
    rng = random.Random(seed)
    for _ in range(count):
        data, expected = random_message(rng)
        # The peer's decoder must agree with its encoder before the Agentica codec is asked.
        assert decode(data) == expected, (data.hex(), decode(data), expected)
        print(data.hex() + "\t" + expected)


def damage(rng, data):
    data = bytearray(data)
    for _ in range(rng.randint(1, 2)):
        if not data:
            break
        kind = rng.randint(0, 4)
        if kind == 0 and len(data) > 1:
            del data[rng.randint(0, len(data) - 1) :]
        elif kind == 1:
            data[rng.randint(0, len(data) - 1)] = rng.randint(0, 255)
        elif kind == 2:
            at = rng.randint(12, max(12, len(data) - 2)) if len(data) > 13 else 0
            data[at : at + 2] = struct.pack(">H", 0xC000 | rng.randint(0, len(data) + 5))
        elif kind == 3:
            data[rng.randint(4, 11) if len(data) > 11 else 0] = rng.randint(0, 255)
        else:
            data += bytes(rng.randint(0, 255) for _ in range(rng.randint(1, 4)))
    return bytes(data)


def mutate(seed, count):
    rng = random.Random(seed)
    for _ in range(count):
        data = damage(rng, random_message(rng)[0])
        try:
            outcome = decode(data)
        except (Malformed, struct.error):
            outcome = "error"
        print(data.hex() + "\t" + outcome)


def decode_lines():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            print(decode(bytes.fromhex(line)))
        except (Malformed, struct.error) as problem:
            print("error: %s" % problem)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "generate":
        generate(int(sys.argv[2]), int(sys.argv[3]))
    elif mode == "mutate":
        mutate(int(sys.argv[2]), int(sys.argv[3]))
    elif mode == "decode":
        decode_lines()
    else:
        sys.exit("usage: dns_peer.py generate|mutate SEED COUNT | decode")


if __name__ == "__main__":
    main()
