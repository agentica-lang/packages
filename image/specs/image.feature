Feature: Images on libvips
  An image is decoded, read as one buffer of pixels and encoded again. The fixtures are written by specs/fixtures/peer.py,
  an independent PNG codec that uses every scanline filter; it also reads the PNGs that this package writes.

  Scenario Outline: A PNG decodes to the pixels of the peer
    Then "<file>" decodes as <width> by <height> with <bands> bands of "<format>", the pixels of "<raw>"

    Examples:
      | file       | width | height | bands | format | raw        |
      | rgb.png    | 16    | 12     | 3     | U8     | rgb.raw    |
      | rgba.png   | 9     | 7      | 4     | U8     | rgba.raw   |
      | gray16.png | 8     | 6      | 1     | U16    | gray16.raw |

  Scenario Outline: Pixels come back unchanged from an image
    Then the pixels "<raw>" as <width> by <height> with <bands> bands of "<format>" come back from the image

    Examples:
      | raw          | width | height | bands | format |
      | rgb.raw      | 16    | 12     | 3     | U8     |
      | gray16.raw   | 8     | 6      | 1     | U16    |
      | ramp_f32.raw | 4     | 3      | 2     | F32    |
      | rgb.raw      | 16    | 12     | 3     | I8     |
      | rgb.raw      | 16    | 6      | 3     | I16    |
      | rgb.raw      | 12    | 12     | 1     | U32    |
      | rgb.raw      | 12    | 12     | 1     | I32    |
      | rgb.raw      | 12    | 6      | 1     | F64    |

  Scenario Outline: A lossless format keeps the pixels
    Then the pixels "<raw>" as <width> by <height> with <bands> bands of "<format>" survive "<encoding>"

    Examples:
      | raw          | width | height | bands | format | encoding |
      | rgba.raw     | 9     | 7      | 4     | U8     | png      |
      | gray16.raw   | 8     | 6      | 1     | U16    | png      |
      | ramp_f32.raw | 4     | 3      | 2     | F32    | tif      |

  Scenario Outline: The peer decodes the PNG that is written
    Then the pixels "<raw>" as <width> by <height> with <bands> bands of "<format>" are decoded by the peer

    Examples:
      | raw        | width | height | bands | format |
      | rgb.raw    | 16    | 12     | 3     | U8     |
      | rgba.raw   | 9     | 7      | 4     | U8     |
      | gray16.raw | 8     | 6      | 1     | U16    |

  Scenario Outline: A lossy format keeps the size
    Then the pixels "rgb.raw" as 16 by 12 with 3 bands of "U8" encode as "<encoding>"

    Examples:
      | encoding  |
      | jpg[Q=90] |
      | webp      |

  Scenario: A file that changed is read again
    Then a file that is loaded and then written with other pixels loads as the new pixels

  Scenario: Tasks decode at once
    Then 8 tasks decode "rgb.png" to the pixels of "rgb.raw"

  Scenario: Bad input fails
    Then these calls fail:
      | call         | a                             | b          | c          | d       | says                                                                                  |
      | from_bytes   | not an image                  |            |            |         |                                                                                       |
      | load         | specs/fixtures/missing.png    |            |            |         |                                                                                       |
      | load_nul     |                               |            |            |         | the path has a NUL byte                                                               |
      | save         | /nonexistent/folder/image.png |            |            |         |                                                                                       |
      | save         | image.nope                    |            |            |         |                                                                                       |
      | save_nul     |                               |            |            |         | the path has a NUL byte                                                               |
      | from_pixels  | 16                            | 12         | 4          | U8      | the size of the pixels does not match width * height * bands * the size of the format |
      | from_pixels  | 0                             | 12         | 3          | U8      | the width, the height and the bands must be positive                                  |
      | from_pixels  | 2147483648                    | 1          | 1          | U8      | the width and the height must be at most 2147483647                                   |
      | from_pixels  | 1                             | 1          | 65536      | U8      | the bands must be at most 65535                                                       |
      | from_pixels  | 2147483647                    | 2147483647 | 65535      | U8      | the size of the pixels does not match width * height * bands * the size of the format |
      | from_pixels  | 16                            | 12         | 3          | Complex | complex pixels are not supported                                                      |
      | to_bytes     | nope                          |            |            |         |                                                                                       |
      | to_bytes_nul |                               |            |            |         | the suffix has a NUL byte                                                             |
      | crop         | 10                            | 5          | 10         | 10      | the area is outside the image                                                         |
      | crop         | 15                            | 0          | 2          | 1       | the area is outside the image                                                         |
      | crop         | 0                             | 0          | 0          | 5       | the area is outside the image                                                         |
      | crop         | -1                            | 0          | 2          | 2       | the area is outside the image                                                         |
      | crop         | 0                             | 0          | 2147483648 | 1       | the area is outside the image                                                         |
      | rotate       | 45                            |            |            |         | the angle must be a multiple of 90 degrees                                            |
      | resize       | 0                             | 5          |            |         | the width and the height must be positive                                             |
      | resize       | 1000000                       | 1000000    |            |         | the size is more than 268435456 pixels                                                |
      | resize       | 2147483648                    | 1          |            |         | the width and the height must be at most 10000000                                                |
      | resize       | 100000000                     | 1          |            |         | the width and the height must be at most 10000000                                                       |
      | cast         | Complex                       |            |            |         | complex pixels are not supported                                                      |
      | colourspace  | Srgb                          |            |            |         | colourspace needs a U8 or U16 image                                                   |

  Scenario: The committed header is the one the block gives
    Given the program argument "../image.agc"
    And the program argument "--output"
    And the program argument "../native/image_native.h"
    And the program argument "--check"
    And the Agentica program "../deps/native-gen/cli.agc"
    Then the program exits with code 0 within 25000 milliseconds
