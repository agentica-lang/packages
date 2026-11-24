Feature: Decoding a raw Snappy block
  The blocks of the fixed scenarios are written from the format description (google/snappy format_description.txt).
  The blocks of the peer scenarios come from `fixtures/snappy_peer.py`, an encoder and a decoder of their own, with
  literals of every length form, copies with one, two and four byte offsets, overlapping copies, and copies that reach
  back past 65535 bytes.

  Scenario: Literals and the empty block
    Then the codec reads these blocks:
      | block      | data |
      | 00         | -    |
      | 010061     | 61   |
      | 3cec414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141     | 414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141414141 |
      | 3df03c42424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242     | 42424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242424242 |

  Scenario: Every copy kind, and overlapping copies
    Then the codec reads these blocks:
      | block              | data                           |
      | 080c616263640104   | 6162636461626364               |
      | 0f0c616263641d04   | 616263646162636461626364616263 |
      | 060061120100       | 616161616161                   |
      | 080461621702000000 | 6162616261626162               |

  Scenario: Malformed blocks are refused with the malformed kind
    Then the codec refuses these blocks:
      | block        |
      | -            |
      | 80           |
      | 8080808010   |
      | 808080808000 |
      | ffffffff0f   |
      | 0a           |
      | 0500610100   |
      | 0500610102   |
      | 040102       |
      | 0100610062   |
      | 030061       |
      | 051061       |
      | 01f0         |
      | 0500610201   |
      | 050061030100 |
      | 0200610101   |

  Scenario Outline: The codec reads the blocks the peer writes
    Given the peer writes <count> blocks from the seed <seed>
    Then the codec reads every block as the peer says

    Examples:
      | seed | count |
      | 11   | 8     |
      | 12   | 8     |

  Scenario Outline: The codec and the peer accept and refuse the same damaged blocks
    Given the peer writes <count> damaged blocks from the seed <seed>
    Then the codec gives the same outcome as the peer for every damaged block

    Examples:
      | seed | count |
      | 21   | 200   |
      | 22   | 200   |
