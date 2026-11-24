Feature: reading the rows of a Parquet file
  The fixtures in specs/fixtures are written by make_fixtures.py with pyarrow. Each one's rows are in its .json.

  Scenario Outline: a fixture reads as the rows that pyarrow wrote
    Then the rows of the fixture "<name>" are the expected rows

    Examples:
      | name             |
      | plain_required   |
      | kinds_dictionary_snappy |
      | kinds_v2_gzip    |
      | pages_v1         |
      | pages_v2_snappy  |
      | pages_dictionary |
      | nulls_plain      |
      | nulls_dictionary |
      | nulls_snappy     |
      | nulls_gzip       |
      | nulls_v2_snappy  |
      | nulls_v2_plain   |
      | runs_dictionary  |
      | row_groups       |
      | empty            |
      | special_floats   |

  Scenario: the schema and the row count come from the footer
    Then the schema of the fixture "nulls_plain" is:
      | name | kind   | nullable |
      | name | String | true     |
      | num  | Int64  | true     |
      | flag | Boolean | true    |
    And the row count of the fixture "row_groups" is 7

  Scenario: a column keeps NaN and the infinities, which rows write as null
    Then the column "x" of the fixture "special_floats" keeps NaN and the infinities

  Scenario Outline: a feature this package does not read is refused as unsupported
    Then the fixture "<name>" is refused as "parquet.unsupported"

    Examples:
      | name   |
      | nested |
      | int96  |
      | delta  |
      | codec_zstd |
      | codec_lz4  |

  Scenario Outline: a truncated or damaged file is refused as malformed
    Then the fixture "plain_required" keeping its first <kept> bytes is refused as "parquet.malformed"

    Examples:
      | kept |
      | 0    |
      | 11   |
      | 40   |

  Scenario Outline: a file whose footer or page header lies is refused as malformed
    Then the fixture "<name>" is refused as "parquet.malformed"

    Examples:
      | name                      |
      | damaged_magic             |
      | damaged_footer_past_start |
      | damaged_page_offset       |
      | damaged_chunk_size        |
      | damaged_value_count       |
      | damaged_page_compressed   |
      | damaged_page_size         |
      | damaged_page_count        |

  Scenario: a footer length that runs past the start of the file is refused as malformed
    Then the fixture "plain_required" with the byte 8 from its end set to 255 is refused as "parquet.malformed"

  Scenario: a missing end magic is refused as malformed
    Then the fixture "plain_required" missing its last 1 bytes is refused as "parquet.malformed"

  Scenario: every kind of value is named in the schema
    Then the schema of the fixture "plain_required" is:
      | name   | kind           | nullable |
      | id     | Int64          | false    |
      | small  | Int32          | false    |
      | ratio  | Double         | false    |
      | single | Float          | false    |
      | name   | String         | false    |
      | flag   | Boolean        | false    |
      | raw    | Binary         | false    |
      | fixed  | FixedBinary(3) | false    |

  Scenario: a limit keeps the first rows and a bad request is invalid
    Then reading 2 rows of the fixture "row_groups" gives 2 rows
    And reading the column "nope" of the fixture "row_groups" is refused as "parquet.invalid"
    And reading -1 rows of the fixture "row_groups" is refused as "parquet.invalid"
