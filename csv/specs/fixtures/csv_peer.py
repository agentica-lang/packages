"""An independent CSV reader and writer for the specs: Python's standard `csv` module.

  python3 -I csv_peer.py SEED COUNT SEPARATOR

It prints two lines for each of COUNT tables made from the seed: the hex of the text that `csv.writer` writes (CRLF line
ends, fields quoted only when they must be), and the JSON of the rows that `csv.reader` reads back from that text. The
tables mix the separator, quotes, CR, LF, empty fields and non-ASCII text, and have no row without a field.
"""

import csv
import io
import json
import random
import sys

PIECES = ["a", "b", "", " ", "x y", '"', '""', ",", ";", "\t", "\n", "\r\n", "\r", "é", "✓", "12", "-3.5"]


def field(rng):
    return "".join(rng.choice(PIECES) for _ in range(rng.randint(0, 4)))


def table(rng):
    return [[field(rng) for _ in range(rng.randint(1, 4))] for _ in range(rng.randint(0, 5))]


def write(rows, separator):
    out = io.StringIO(newline="")
    csv.writer(out, delimiter=separator, lineterminator="\r\n").writerows(rows)
    return out.getvalue()


def read(text, separator):
    return list(csv.reader(io.StringIO(text, newline=""), delimiter=separator))


def main():
    seed, count, separator = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    rng = random.Random(seed)
    for _ in range(count):
        text = write(table(rng), separator)
        print(text.encode("utf-8").hex())
        print(json.dumps(read(text, separator)))


if __name__ == "__main__":
    main()
