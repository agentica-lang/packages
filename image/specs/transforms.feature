Feature: Transforms of images
  A transform gives the pixels that an independent model in specs/fixtures/peer.py gives: the same bytes for crop,
  flip, rotate, cast and srgb, and for grey and resize a stated tolerance in levels of u8. libvips converts to grey
  through the luminance of linear light, and resizes with a kernel (Lanczos 3 by default): a box shrink by the whole
  part of half the shrink on each side when that is 2 or more, then the reduce of each side (the rows first), each pass
  rounded to u8, which the peer models alike.
  The source image is closed before the pixels are read, since a result keeps what it needs. The resize model is
  exact only when each integer shrink divides the size, so the scenarios use sizes that it does; the tolerance of 3
  levels was measured with libvips 8.15 and 8.16, where the worst difference seen is 3 (no margin).

  Scenario Outline: Crop, flip and rotate move pixels exactly
    Then the pixels "<raw>" as <width> by <height> with <bands> bands of "U8" under "<transform>" are the peer's within 0

    Examples:
      | raw      | width | height | bands | transform         |
      | rgb.raw  | 16    | 12     | 3     | crop 3 2 8 6      |
      | rgb.raw  | 16    | 12     | 3     | crop 15 11 1 1    |
      | rgba.raw | 9     | 7      | 4     | crop 0 0 9 7      |
      | rgba.raw | 9     | 7      | 4     | crop 2 1 5 6      |
      | rgb.raw  | 16    | 12     | 3     | flip h            |
      | rgb.raw  | 16    | 12     | 3     | flip v            |
      | rgba.raw | 9     | 7      | 4     | flip h            |
      | rgb.raw  | 16    | 12     | 3     | rotate 90         |
      | rgb.raw  | 16    | 12     | 3     | rotate 180        |
      | rgb.raw  | 16    | 12     | 3     | rotate 270        |
      | rgb.raw  | 16    | 12     | 3     | rotate -90        |
      | rgba.raw | 9     | 7      | 4     | rotate 90         |
      | rgba.raw | 9     | 7      | 4     | rotate 450        |
      | grey.raw | 10    | 6      | 1     | rotate 270        |

  Scenario Outline: Resize is the peer's within 3 levels
    Then the pixels "photo.raw" as 64 by 48 with 3 bands of "U8" under "resize <width> <height>" are the peer's within 3

    Examples:
      | width | height |
      | 32    | 24     |
      | 16    | 12     |
      | 40    | 30     |
      | 17    | 13     |
      | 63    | 47     |
      | 8     | 48     |
      | 64    | 7      |
      | 20    | 20     |

  # The kernels of libvips with the model of the peer: the same reduce with the kernel in place of Lanczos 3. The tolerance
  # is the one of Lanczos 3, but measured with libvips 8.16 only (8.15 was not rechecked).
  Scenario Outline: Resize with a kernel is the peer's within 3 levels
    Then the pixels "photo.raw" as 64 by 48 with 3 bands of "U8" under "resize <width> <height> <kernel>" are the peer's within 3

    Examples:
      | kernel   | width | height |
      | linear   | 32    | 24     |
      | linear   | 40    | 30     |
      | linear   | 17    | 13     |
      | cubic    | 32    | 24     |
      | cubic    | 40    | 30     |
      | cubic    | 17    | 13     |
      | lanczos2 | 32    | 24     |
      | lanczos2 | 40    | 30     |
      | lanczos3 | 40    | 30     |

  # libvips rounds the positions of nearest to a fixed-point mask: the peer models it only when the output size divides
  # the source size, or the source size divides the output size, and then the pixels are the same (measured with libvips
  # 8.16 only; 8.15 was not rechecked).
  Scenario Outline: Nearest picks the source pixels
    Then the pixels "photo.raw" as 64 by 48 with 3 bands of "U8" under "resize <width> <height> nearest" are the peer's within 0

    Examples:
      | width | height |
      | 32    | 24     |
      | 16    | 12     |
      | 128   | 96     |

  Scenario: Each kernel gives its own pixels
    Then the pixels "photo.raw" as 64 by 48 with 3 bands of "U8" resized to 40 by 30 differ by kernel

  # libvips enlarges with an interpolation that the peer does not model: only the size is compared.
  Scenario: Resize enlarges
    Then the pixels "rgb.raw" as 16 by 12 with 3 bands of "U8" under "resize 40 30" are the peer's within 255

  Scenario Outline: Colour conversions
    Then the pixels "<raw>" as <width> by <height> with <bands> bands of "U8" under "<transform>" are the peer's within <levels>

    Examples:
      | raw      | width | height | bands | transform | levels |
      | rgb.raw  | 16    | 12     | 3     | grey      | 1      |
      | rgba.raw | 9     | 7      | 4     | grey      | 1      |
      | grey.raw | 10    | 6      | 1     | srgb      | 0      |

  # The bytes of rgb.raw as grey and alpha.
  Scenario: Colours of a grey image with alpha
    Then the pixels "rgb.raw" as 24 by 12 with 2 bands of "U8" under "srgb" are the peer's within 0

  Scenario: A chain of transforms outlives the images it came through
    Then the pixels "rgba.raw" as 9 by 7 with 4 bands of "U8" turn a quarter and back

  # Each task makes an image of its own: a resource belongs to the task that made it.
  Scenario: Independent lazy images are read in parallel tasks
    Then 8 tasks resize an image of "photo.raw" repeated to 2000 by 1500 down to 500 by 375

  Scenario Outline: A resize up to the limits is accepted
    Then a resize to <width> by <height> is accepted

    Examples:
      | width    | height   |
      | 10000000 | 1        |
      | 1        | 10000000 |
      | 16384    | 16384    |

  # A 16-bit image stays 16-bit: the peer copies each 2-byte sample to the three bands.
  Scenario: Colours of a 16-bit image keep their depth
    Then the pixels "gray16.raw" as 8 by 6 with 1 bands of "U16" under "srgb 2" are the peer's within 0

  Scenario Outline: Cast keeps the values
    Then the pixels "<raw>" as <width> by <height> with <bands> bands of "<format>" under "cast <to>" are the peer's within 0

    Examples:
      | raw          | width | height | bands | format | to  |
      | rgb.raw      | 16    | 12     | 3     | U8     | f32 |
      | rgb.raw      | 16    | 12     | 3     | U8     | u16 |
      | ramp_f32.raw | 4     | 3      | 2     | F32    | u8  |
      | ramp_f32.raw | 4     | 3      | 2     | F32    | u16 |
      | ramp_f32.raw | 4     | 3      | 2     | F32    | i16 |
      | gray16.raw   | 8     | 6      | 1     | U16    | u8  |
