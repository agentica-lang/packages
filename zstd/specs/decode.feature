Feature: Decoding Zstandard frames
  The frames come from `fixtures/zstd_peer.py`, which drives the reference `zstd` command line: every level and window
  it has, with and without a checksum or a content size, several frames in a row, and damaged frames on which the codec
  and `zstd -d` must give the same answer. The fixed frames, one for each block type and each kind of error, are the
  unit tests of `test/zstd_test.agc`.

  Scenario Outline: The codec reads the frames the reference tool writes
    Given the reference tool is shown
    And the peer writes <count> frames from the seed <seed>
    Then the codec reads every frame as the peer says

    Examples:
      | seed | count |
      | 1    | 16    |
      | 2    | 16    |
      | 3    | 16    |

  Scenario: Frames written by hand, with every table a repeated symbol and each form of the sequence count
    Given the peer writes 5 hand-made frames from the seed 1
    Then the codec reads every frame as the peer says

  Scenario Outline: The codec reads frames that follow each other, with skippable frames between them
    Given the peer writes <count> multi-frame inputs from the seed <seed>
    Then the codec reads every frame as the peer says

    Examples:
      | seed | count |
      | 5    | 8     |

  Scenario Outline: The codec refuses the damaged frames that the reference tool refuses, and reads the same data from the rest
    Given the peer writes <count> damaged frames from the seed <seed>
    Then the codec refuses what the peer refuses and reads what the peer reads

    Examples:
      | seed | count |
      | 21   | 100   |
      | 22   | 100   |

  Scenario: A frame cut at every length is refused
    Given the peer writes 1 frames with a checksum from the seed 1
    Then the codec refuses the frame cut at every length

  Scenario: A frame with a checksum, with each of its bits flipped in turn, gives its data or an error
    Given the peer writes 1 frames with a checksum from the seed 1
    Then the codec gives the data or an error for the frame with every bit flipped in turn

  Scenario Outline: The codec reads frames of 1 to 3 MB of columns, at levels 1, 3 and 9
    Given the peer writes <count> columnar frames from the seed <seed>
    Then the codec reads every frame as the peer says

    Examples:
      | seed | count |
      | 1    | 2     |
      | 2    | 2     |
      | 3    | 2     |
      | 4    | 2     |
      | 5    | 2     |
      | 6    | 2     |

  Scenario: Frames as Arrow writes them are read when the limit is their size and refused one byte short
    Given the peer writes 4 single-segment frames from the seed 1
    Then the codec reads every frame at exactly its size and refuses it one byte short
