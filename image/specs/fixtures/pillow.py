#!/usr/bin/env python3
"""Writes pillow_resize.json: what Pillow resizes, the golden of the resize scenarios of image's specs.

  pip install --target DIR --only-binary :all: --require-hashes -r specs/fixtures/pillow-requirements.txt
  python3 -I specs/fixtures/pillow.py DIR specs/fixtures/pillow_resize.json

DIR holds the Pillow of pillow-requirements.txt (pip checks the sha256 of the wheel, and this program the version).
CI does not run it: it reads the committed file. The inputs are a step edge (the minimal case of issue 266) and
a small image of blocks, enlarged and shrunk by a different factor on each axis, with Pillow's BILINEAR and BICUBIC,
which are the Linear and Cubic kernels.
"""
import json
import sys

PINNED = "11.3.0"
KERNELS = {"linear": "BILINEAR", "cubic": "BICUBIC"}
STEP = (8, 4, 1, bytes([0, 0, 0, 0, 100, 200, 200, 200] * 4))


def blocks(width, height, bands):
    """Flat blocks with hard edges, so that a shifted sample shows, between 30 and 210 so that the overshoot of the cubic
    never reaches 0 or 255 (Pillow clips between its two passes, libvips does not)."""
    return bytes(
        30 + (((x // 3) * 97 + (y // 2) * 61 + b * 53) % 7) * 30
        for y in range(height) for x in range(width) for b in range(bands)
    )


def discs(width, height, bands):
    """A smooth shading with two drawn discs, like a picture: the edges of the discs are the only hard ones."""
    def sample(x, y, b):
        value = 60 + x * 3 + y * 2 + b * 20
        for cx, cy, radius, shade in ((7, 6, 5, 200), (17, 10, 4, 40)):
            if (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2:
                value = shade + b * 10
        return value
    return bytes(sample(x, y, b) for y in range(height) for x in range(width) for b in range(bands))


INPUTS = {"step": STEP, "blocks": (12, 10, 3, blocks(12, 10, 3)), "discs": (24, 16, 3, discs(24, 16, 3))}
SIZES = {
    "step": [(16, 8)],
    "blocks": [(w, h) for h in (5, 10, 15, 25) for w in (6, 12, 18, 30)],
    "discs": [(12, 16), (24, 8), (36, 16), (24, 24), (48, 40), (36, 8), (12, 24), (16, 12)],
}


def kind(width, height, w, h):
    """The name of what a size does to the input: enlarge (no axis shrinks), shrink (no axis grows) or mixed."""
    if w >= width and h >= height:
        return "enlarge"
    return "shrink" if w <= width and h <= height else "mixed"


def main():
    folder, target = sys.argv[1:3]
    sys.path.insert(0, folder)
    from PIL import Image

    assert Image.__version__ == PINNED, f"Pillow {Image.__version__}, not {PINNED}"
    inputs, cases = {}, []
    for name, (width, height, bands, data) in INPUTS.items():
        inputs[name] = {"width": width, "height": height, "bands": bands, "hex": data.hex()}
        mode = {1: "L", 3: "RGB"}[bands]
        for kernel, filter_name in KERNELS.items():
            for w, h in SIZES[name]:
                source = Image.frombytes(mode, (width, height), data)
                out = source.resize((w, h), getattr(Image, filter_name))
                cases.append({"input": name, "kernel": kernel, "kind": kind(width, height, w, h), "width": w, "height": h,
                              "hex": out.tobytes().hex()})
    with open(target, "w") as f:
        json.dump({"pillow": PINNED, "inputs": inputs, "cases": cases}, f, separators=(",", ":"))
        f.write("\n")


main()
