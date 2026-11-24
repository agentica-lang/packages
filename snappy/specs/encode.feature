Feature: Encoding a raw Snappy block
  The codec writes a block and the peer decodes it, with its own decoder: the data must come back unchanged. The inputs
  of the scenario are noise from the peer, so the codec writes literals of every length form, and a repeat of the start
  of the noise at the end, which the codec may write as a copy.

  Scenario Outline: The peer decodes the blocks the codec writes from the peer's data
    Given the peer writes <count> blocks from the seed <seed>
    Then the codec compresses the peer's data and the peer decodes it back

    Examples:
      | seed | count |
      | 11   | 8     |
      | 12   | 8     |

  Scenario: Noise of every literal length form, and a repeat of its start
    Then the codec compresses these inputs and the peer decodes them to the same bytes:
      | size  | repeat | seed |
      | 0     | 0      | 1    |
      | 1     | 0      | 1    |
      | 59    | 0      | 2    |
      | 60    | 0      | 2    |
      | 61    | 0      | 2    |
      | 255   | 0      | 3    |
      | 256   | 0      | 3    |
      | 257   | 0      | 3    |
      | 65536 | 0      | 4    |
      | 65537 | 0      | 4    |
      | 100   | 6      | 6    |
      | 100   | 20     | 6    |
      | 70000 | 64     | 5    |
