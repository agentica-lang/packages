---
title: image
description: "Images on libvips: decode, encode, and the pixels as one Bytes buffer, with no value per pixel."
category: Data formats
keywords: [native, libvips, png, jpeg, webp]
---

`image` loads and saves images (JPEG, PNG, WebP, TIFF and the rest that your libvips has) and hands their pixels to other code as one `Bytes` buffer, interleaved and in the byte order of the machine. It is a [libvips](https://www.libvips.org/) binding made with [native-gen](https://www.agentica-lang.com/packages/native-gen/): the C module is built on the first run.

## Install

Needs Agentica 0.35.0, a C compiler and libvips (see [Requirements](#requirements)). Add it with its prefixed tag, in a project with an `agentica.toml`:

```sh
agentica add image https://github.com/agentica-lang/packages --tag image-0.3.0 --subdir image
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
image = { git = "https://github.com/agentica-lang/packages", tag = "image-0.3.0", subdir = "image" }
```

A function that takes an image takes it first, so a chain reads well with `|>`. Each entry says what the function does and when it fails; the rules that hold for all of them are in [Memory and lifetime](#memory-and-lifetime), [Untrusted input](#untrusted-input) and [Requirements](#requirements). The examples below make their image with `from_pixels`: a grey image of 3 by 2 pixels, `1 2 3` on the first row and `4 5 6` on the second.

## Types

### `Image.Image`

An image. It is a resource of the native module, so it follows the rules of [Memory and lifetime](#memory-and-lifetime).

```agentica
import Image from "pkg/image/image"

def size(image: Image.Image) -> String = "#{Image.width(image)}x#{Image.height(image)}"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4]).unwrap!, 2, 2, 1, Image.Format.U8).unwrap!
  puts(size(image))
end
```

```output
2x2
```

### `Image.Format`

The type of one sample: `U8`, `I8`, `U16`, `I16`, `U32`, `I32`, `F32`, `F64` or `Complex`. Both complex formats of libvips are `Complex`: an image of it can be read and saved, but `from_pixels` and `cast` do not make one.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2]).unwrap!, 2, 1, 1, Image.Format.U8).unwrap!
  case Image.pixel_format(image)
    Image.Format.U8 -> puts("one byte a sample")
    _ -> puts("another format")
  end
end
```

```output
one byte a sample
```

### `Image.Direction`

`Horizontal` or `Vertical`: the axis that `flip` mirrors across.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  puts(Image.Direction.Vertical)
end
```

```output
Direction.Vertical
```

### `Image.Space`

`Srgb` or `Grey`: the colour model that `colourspace` converts to.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  puts(Image.Space.Grey)
end
```

```output
Space.Grey
```

### `Image.Kernel`

`Nearest`, `Linear`, `Cubic` (Catmull-Rom), `Lanczos2` or `Lanczos3`: the kernel that `resize` interpolates with.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  puts(Image.Kernel.Cubic)
end
```

```output
Kernel.Cubic
```

## Reading and writing

### `Image.load(path) -> Result[Image]`

Decodes the file at `path`; libvips finds the format from the contents. The file is read at once, so a bad file fails here. A missing file, a format libvips cannot read, or a path with a NUL byte is an error. To see a load that works, read the example of `save`.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  case Image.load("/nonexistent.png")
    ok(_) -> puts("loaded")
    error(_) -> puts("cannot load")
  end
end
```

```output
cannot load
```

### `Image.from_bytes(data) -> Result[Image]`

Decodes an encoded image that is in memory. Like `load`, it decodes at once and fails on bytes that are not an image.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  original = Image.from_pixels(Bytes.from_list([7]).unwrap!, 1, 1, 1, Image.Format.U8).unwrap!
  png = Image.to_bytes(original, "png").unwrap!
  image = Image.from_bytes(png).unwrap!
  puts(Image.to_pixels(image).unwrap!.to_a)
end
```

```output
[7]
```

### `Image.save(image, path) -> Result[Void]`

Writes the image to `path`. The extension picks the encoder, and options go in brackets as libvips takes them: `photo.jpg[Q=90]`. An unknown extension, a folder that is missing, or a path with a NUL byte is an error.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([10, 20, 30, 40]).unwrap!, 2, 2, 1, Image.Format.U8).unwrap!
  Image.save(image, "/tmp/image-docs-save.png").unwrap!
  loaded = Image.load("/tmp/image-docs-save.png").unwrap!
  puts(Image.to_pixels(loaded).unwrap!.to_a)
  Path.remove("/tmp/image-docs-save.png").unwrap!
end
```

```output
[10, 20, 30, 40]
```

### `Image.to_bytes(image, suffix) -> Result[Bytes]`

Encodes the image in memory. `suffix` is a file extension without the dot, with the same options as `save`: `"png"`, `"jpg[Q=90]"`, `"webp"`, `"tif"`. An unknown suffix, or a suffix with a NUL byte, is an error.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([10, 20, 30, 40]).unwrap!, 2, 2, 1, Image.Format.U8).unwrap!
  puts(Image.to_bytes(image, "png").unwrap!.take(4).to_a)
end
```

```output
[137, 80, 78, 71]
```

## Pixels

### `Image.from_pixels(pixels, width, height, bands, format) -> Result[Image]`

Makes an image from interleaved samples: `width * height * bands` of them, in `format`, in the byte order of the machine. A buffer of another size, a size that is not positive (at most 10000000 for the width and the height, 65535 for the bands), or the format `Complex` is an error. A `U8` image of 1 or 2 bands is grey and of 3 or 4 bands is sRGB; `U16` is the same in 16 bits, so a PNG of a `U16` image is a 16-bit PNG.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  pixels = Bytes.from_list([1, 2, 3, 4, 5, 6]).unwrap!
  image = Image.from_pixels(pixels, 3, 2, 1, Image.Format.U8).unwrap!
  puts("#{Image.width(image)}x#{Image.height(image)}")
  puts(Image.from_pixels(pixels, 4, 2, 1, Image.Format.U8).ok?)
end
```

```output
3x2
false
```

### `Image.to_pixels(image) -> Result[Bytes]`

Gives the samples, interleaved, in the format of the image and the byte order of the machine. It is the reverse of `from_pixels`: the same bytes come back, for every format but `Complex`.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4, 5, 6]).unwrap!, 3, 2, 1, Image.Format.U8).unwrap!
  puts(Image.to_pixels(image).unwrap!.to_a)
end
```

```output
[1, 2, 3, 4, 5, 6]
```

### `Image.width(image) -> Int`

The width in pixels.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4, 5, 6]).unwrap!, 3, 2, 1, Image.Format.U8).unwrap!
  puts(Image.width(image))
end
```

```output
3
```

### `Image.height(image) -> Int`

The height in pixels.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4, 5, 6]).unwrap!, 3, 2, 1, Image.Format.U8).unwrap!
  puts(Image.height(image))
end
```

```output
2
```

### `Image.bands(image) -> Int`

The number of bands: 1 for grey, 3 for colour, one more for alpha.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4, 5, 6]).unwrap!, 3, 2, 1, Image.Format.U8).unwrap!
  puts(Image.bands(image))
end
```

```output
1
```

### `Image.pixel_format(image) -> Image.Format`

The format of each sample. (It is not called `format`, which is a builtin of Agentica.)

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4, 5, 6]).unwrap!, 3, 2, 1, Image.Format.U8).unwrap!
  puts(Image.pixel_format(image))
end
```

```output
Format.U8
```

## Transforms

A transform returns a new image and leaves its source as it was. It is lazy: see [Memory and lifetime](#memory-and-lifetime).

### `Image.resize(image, width, height, kernel = Image.Kernel.Lanczos3) -> Result[Image]`

Scales the image to `width` by `height` with `kernel`, down or up; keep the ratio yourself. The default is Lanczos 3, the kernel of libvips, so a call with no kernel gives what it gave before `kernel` existed. A size that is not positive, a side of more than 10000000 pixels, or more than 268435456 pixels in all (pixels, not bytes) is an error. A shrink does not premultiply the alpha band, so the edge next to a transparent pixel may get a colour fringe; an enlarge does, and keeps the colour (with one axis of each, the shrunk axis is not premultiplied).

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4, 5, 6, 7, 8]).unwrap!, 4, 2, 1, Image.Format.U8).unwrap!
  small = Image.resize(image, 2, 1).unwrap!
  puts("#{Image.width(small)}x#{Image.height(small)}")
end
```

```output
2x1
```

Pick the kernel of the model that your pixels are compared with: `Image.Kernel.Linear` and `Image.Kernel.Cubic` are the kernels of the bilinear and bicubic filters of Pillow. An enlarge puts the centre of each output pixel at `(x + 0.5) / scale - 0.5` of the input, as Pillow, OpenCV and Hugging Face do, on each axis with its own factor, so the pixels are within 1 level of Pillow's for `Linear` and 4 for `Cubic` on the test images (a step edge is the same). `Lanczos2` and `Lanczos3` enlarge as `Cubic`, which is libvips' choice and not Pillow's `LANCZOS`. libvips shrinks by whole factors before it reduces, and repeats the edge pixel where Pillow drops the taps outside the image, so a shrink and the border of an enlarge are close to Pillow's, not equal.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([0, 100, 200, 100]).unwrap!, 4, 1, 1, Image.Format.U8).unwrap!
  nearest = Image.resize(image, 2, 1, Image.Kernel.Nearest).unwrap!
  linear = Image.resize(image, 2, 1, Image.Kernel.Linear).unwrap!
  puts("#{Image.width(linear)}x#{Image.height(linear)}")
  puts(Image.to_pixels(nearest).unwrap! != Image.to_pixels(linear).unwrap!)
end
```

```output
2x1
true
```

### `Image.crop(image, left, top, width, height) -> Result[Image]`

The `width` by `height` area whose top left pixel is at `left`, `top`. An area that is not inside the image is an error.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4, 5, 6]).unwrap!, 3, 2, 1, Image.Format.U8).unwrap!
  part = Image.crop(image, 1, 0, 2, 2).unwrap!
  puts(Image.to_pixels(part).unwrap!.to_a)
end
```

```output
[2, 3, 5, 6]
```

### `Image.flip(image, direction) -> Result[Image]`

Mirrors the image left to right (`Image.Direction.Horizontal`) or top to bottom (`Image.Direction.Vertical`).

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4, 5, 6]).unwrap!, 3, 2, 1, Image.Format.U8).unwrap!
  mirrored = Image.flip(image, Image.Direction.Horizontal).unwrap!
  puts(Image.to_pixels(mirrored).unwrap!.to_a)
end
```

```output
[3, 2, 1, 6, 5, 4]
```

### `Image.rotate(image, degrees) -> Result[Image]`

Turns the image clockwise by `degrees`, a multiple of 90; a negative number turns it the other way. Another angle is an error.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4, 5, 6]).unwrap!, 3, 2, 1, Image.Format.U8).unwrap!
  turned = Image.rotate(image, 90).unwrap!
  puts("#{Image.width(turned)}x#{Image.height(turned)}")
  puts(Image.to_pixels(turned).unwrap!.to_a)
end
```

```output
2x3
[4, 1, 5, 2, 6, 3]
```

### `Image.colourspace(image, space) -> Result[Image]`

Converts the colours to `Image.Space.Srgb` or `Image.Space.Grey`, for a `U8` or a `U16` image of 1 to 4 bands; any other pixel format, or 5 bands or more, is an error. A `U16` image stays 16-bit, and an alpha band is kept. Grey is the luminance of the linear light, encoded again.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  pixels = Bytes.from_list([255, 0, 0, 0, 255, 0]).unwrap!
  image = Image.from_pixels(pixels, 2, 1, 3, Image.Format.U8).unwrap!
  grey = Image.colourspace(image, Image.Space.Grey).unwrap!
  puts("#{Image.bands(grey)} band: #{Image.to_pixels(grey).unwrap!.to_a}")
end
```

```output
1 band: [127, 220]
```

### `Image.cast(image, format) -> Result[Image]`

Changes the pixel format and keeps the values. They are clipped to the range of an integer format, and a float is cut toward zero (`0.9` becomes `0`). It does not rescale: `U8` to `F32` gives `255.0`, not `1.0`. The format `Complex` is an error.

```agentica
import Image from "pkg/image/image"

def main() -> Void
  image = Image.from_pixels(Bytes.from_list([1, 2, 3, 4, 5, 6]).unwrap!, 3, 2, 1, Image.Format.U8).unwrap!
  wide = Image.cast(image, Image.Format.U16).unwrap!
  puts("#{Image.pixel_format(wide)}, #{Image.to_pixels(wide).unwrap!.size} bytes")
end
```

```output
Format.U16, 12 bytes
```

## Memory and lifetime

- An `Image.Image` is a resource: it belongs to the task that made it. Its memory is freed by `Native.close(image)`, when the task ends, or when the run ends. A loop that makes many images closes each one, or runs in a task of its own.
- `load`, `from_bytes` and `from_pixels` hold their pixels in memory. A transform is lazy, as libvips is: it holds the image it came from, and its own pixels are made only when you read them (`to_pixels`, `save` or `to_bytes`), so a chain has no image for each step.
- `Native.close` of a source frees only your handle: its pixels stay until every result made from it is closed too. A loop that makes a thousand thumbnails of a thousand big images holds a thousand decodes until the thumbnails are closed.
- To free the source, make a result that stands alone: read its pixels with `to_pixels` and make an image of them with `from_pixels` (or `to_bytes` then `from_bytes`), then close the others.
- libvips starts worker threads of its own when pixels are read. Set the environment variable `VIPS_CONCURRENCY` to limit them.

## Untrusted input

- `load` and `from_bytes` block the loaders that libvips marks untrusted (ImageMagick, for one), so an image from a user cannot reach them.
- A `[` in a name starts options for libvips: `photo.jpg[shrink=2]` loads with the option `shrink`, so a file named `a[1].png` cannot be loaded or saved by that name. The same holds for the `suffix` of `to_bytes`.
- The size of a decoded image is not capped: a small file can decode to a huge image, so limit the size of what you accept.
- The operation cache of libvips is off, so a file that changed is read again.
- The error buffer of libvips is one for the process, so errors that happen at the same moment in two tasks may swap their messages.

## Requirements

- Agentica 0.35.0 and a C compiler: the C module is built on the first run.
- libvips with its development files: `libvips-dev` on Debian and Ubuntu, `brew install vips` on macOS (then `LIBRARY_PATH` must name the folder of `libvips.dylib`). The specs run on libvips 8.15 and 8.16; older 8.x may work but is not tested.
- Linux and macOS. Windows is not supported.
- Without libvips, the first use fails with the error of the C build.

## Tests

The fixtures of `specs/fixtures/` are written by `peer.py`, an independent PNG codec and image model in Python's standard library. A scenario checks that libvips decodes each PNG to the pixels of the peer, and that the peer decodes the PNGs that `image` writes to the pixels that went in. The peer also computes the transforms: the same bytes for crop, flip, rotate and cast, and within 1 level of u8 for grey and 3 for resize, which it models the way libvips does it (a box shrink, then the reduce of the rows and the columns with the kernel, each pass rounded to u8; `Nearest` is the exact pixel at the centre of each output pixel). The resize model holds only when each integer shrink divides the size, and does not cover an enlarge, except for `Nearest`, which is exact when the output size divides the source size, or the source size divides the output size. An enlarge and a shrink of `Linear` and `Cubic` are checked against `pillow_resize.json`, what Pillow 11.3.0 makes of a step edge and of two small images, enlarged and shrunk by a different factor on each axis (`pillow.py` writes it; it needs Pillow only to write it, and CI reads the committed file): the step edge is exact, and the other pixels are within the levels that the scenarios state, which come from the border and the rounding of each library: for an enlarge, at most 1 level for `Linear` (4 with an alpha band) and 4 for `Cubic`; for a shrink, at most 9 for `Linear` and 5 for `Cubic`; for an enlarge on one axis and a shrink on the other, at most 8 and 5. The tolerance of 3 for Lanczos 3 was measured with libvips 8.15 and 8.16, where the worst difference seen is 3. The tolerances of the other kernels, the exactness of `Nearest` and the Pillow golden were measured with libvips 8.16.1, and CI, which runs libvips 8.18.0, passes within the same levels (the largest gap there was not measured, only that it is within them); 8.15, the oldest that `image` supports, was not tested.
