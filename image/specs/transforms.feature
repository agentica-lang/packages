Feature: Transforms of images
  A transform gives the pixels that an independent model in specs/fixtures/peer.py gives: the same bytes for crop,
  flip, rotate, cast and srgb, and for grey and resize a stated tolerance in levels of u8. libvips converts to grey
  through the luminance of linear light, and resizes with the Lanczos 3 kernel: a box shrink by the whole part of half
  the shrink on each side when that is 2 or more, then the reduce of each side (the rows first), each pass rounded to u8,
  which the peer models alike.
  The source image is closed before the pixels are read, since a result keeps what it needs.

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

  Scenario Outline: Cast keeps the values
    Then the pixels "<raw>" as <width> by <height> with <bands> bands of "<format>" under "cast <to>" are the peer's within 0

    Examples:
      | raw          | width | height | bands | format | to  |
      | rgb.raw      | 16    | 12     | 3     | U8     | f32 |
      | rgb.raw      | 16    | 12     | 3     | U8     | u16 |
      | ramp_f32.raw | 4     | 3      | 2     | F32    | u8  |
      | ramp_f32.raw | 4     | 3      | 2     | F32    | u16 |
