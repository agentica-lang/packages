---
title: image
description: "Images on libvips: decode, encode, and the pixels as one Bytes buffer, with no value per pixel."
---

`image` loads and saves images (JPEG, PNG, WebP, TIFF and the rest that your libvips has) and hands their pixels to other code as one `Bytes` buffer, interleaved and in the byte order of the machine. It is a [libvips](https://www.libvips.org/) binding made with [native-gen](https://www.agentica-lang.com/packages/native-gen/): the C module is built on the first run.

## Install

Needs Agentica 0.35.0, a C compiler, and libvips 8.15 or later to link against: `libvips-dev` on Debian and Ubuntu, `brew install vips` on macOS (then `LIBRARY_PATH` must name the folder of `libvips.dylib`). Linux and macOS only. Once the first release is tagged, add it with its prefixed tag, in a project with an `agentica.toml`:

```sh
agentica add image https://github.com/agentica-lang/packages --tag image-0.1.0 --subdir image
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
image = { git = "https://github.com/agentica-lang/packages", tag = "image-0.1.0", subdir = "image" }
```

## Example

```agentica
import Image from "pkg/image/image"

def main() -> Void
  pixels = Bytes.from_list([255, 0, 0, 0, 0, 255]).unwrap!
  image = Image.from_pixels(pixels, 2, 1, 3, Image.Format.U8).unwrap!
  png = Image.to_bytes(image, "png").unwrap!
  decoded = Image.from_bytes(png).unwrap!
  puts("#{Image.width(decoded)}x#{Image.height(decoded)}, #{Image.bands(decoded)} bands, #{Image.pixel_format(decoded)}")
  puts(Image.to_pixels(decoded).unwrap!.to_a)
end
```

```output
2x1, 3 bands, Format.U8
[255, 0, 0, 0, 0, 255]
```

## API

- `Image.Image` is an image. It is a resource of the native module: it belongs to the task that made it, and its memory is freed when you call `Native.close(image)`, when the task ends, or when the run ends. A loop that decodes many images closes each one, or runs in a task of its own.
- `Image.load(path) -> Result[Image]` decodes a file; libvips finds the format from the contents. `Image.from_bytes(data) -> Result[Image]` decodes an encoded image in memory. Both decode at once, so a bad file fails there, and the image does not read the file or the buffer again.
- `Image.from_pixels(pixels, width, height, bands, format) -> Result[Image]` makes an image from interleaved samples: `width * height * bands` of them, in `format`, in the byte order of the machine. A buffer of another size is an error. A `U8` image of 1 or 2 bands is grey and of 3 or 4 bands is sRGB, and `U16` the same in 16 bits, so that a PNG of a `U16` image is a 16-bit PNG.
- `Image.to_pixels(image) -> Result[Bytes]` is the reverse: the samples, interleaved, in the format of the image. `from_pixels` then `to_pixels` gives the same bytes, for every format.
- `Image.width(image)`, `Image.height(image)` and `Image.bands(image)` are the size. `Image.pixel_format(image)` is a `Image.Format`: `U8`, `I8`, `U16`, `I16`, `U32`, `I32`, `F32`, `F64` or `Complex` (a complex image can be read and saved, but `from_pixels` does not make one).
- `Image.save(image, path) -> Result[Void]` writes a file; its extension picks the encoder, and options go in brackets as libvips takes them (`photo.jpg[Q=90]`).
- `Image.to_bytes(image, format) -> Result[Bytes]` encodes in memory. `format` is the suffix without the dot, with the same options: `"png"`, `"jpg[Q=90]"`, `"webp"`, `"tif"`.

An error from libvips is the text that libvips gives. The decoders that exist depend on your libvips build: ask for a format it lacks and the call fails.

## Tests

The fixtures of `specs/fixtures/` are written by `peer.py`, an independent PNG codec in Python's standard library. A scenario checks that libvips decodes each PNG to the pixels of the peer, and that the peer decodes the PNGs that `image` writes to the pixels that went in.
