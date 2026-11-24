Feature: the RLE and bit-packed hybrid decoder
  specs/fixtures/rle_peer.py encodes seeded values in the hybrid format, independently of the decoder.

  Scenario Outline: the peer's encoding reads back as the values it encoded
    Then the hybrid decoder reads back the peer's <count> values from the seed <seed> at width <width>

    Examples:
      | count | seed | width |
      | 1     | 1    | 1     |
      | 9     | 2    | 1     |
      | 100   | 3    | 3     |
      | 300   | 4    | 8     |
      | 200   | 5    | 17    |
      | 64    | 6    | 32    |
      | 50    | 7    | 0     |

  Scenario Outline: an encoding cut short is refused as malformed
    Then the hybrid decoder refuses the peer's 100 values from the seed 3 at width 3 keeping its first <kept> bytes

    Examples:
      | kept |
      | 0    |
      | 1    |
      | 2    |
