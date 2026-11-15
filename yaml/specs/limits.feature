Feature: Limits
  The options bound the nesting depth, the nodes that aliases add and the size of the text, so a hostile text fails
  fast with an error of kind `yaml.limit` instead of using the stack or the memory. The defaults are a depth of 256,
  100,000 alias nodes, 10 MiB of alias bytes and 4 MiB of text.

  Scenario Outline: Deep nesting stops at the depth limit
    Given <text>
    When the text is parsed
    Then it fails with "yaml.limit" at line <line>, column <column>
    And the parse took fewer than <steps> steps

    Examples:
      | text                                    | line | column | steps   |
      | a text of 100000 nested flow sequences  | 1    | 257    | 100000  |
      | a text of 100000 nested block sequences | 1    | 513    | 100000  |
      | a text of 300 nested block mappings     | 257  | 257    | 2000000 |

  Scenario: A depth within the limit parses
    Given a text of 300 nested flow sequences
    And the options allow a depth of 300
    When the text is parsed
    Then it parses

  Scenario: An alias bomb stops at the alias limit
    Given an alias bomb of 9 levels
    When the text is parsed
    Then it fails with "yaml.limit" at line 6, column 10
    And the parse took fewer than 100000 steps

  Scenario: Aliases within the limit parse
    Given an alias bomb of 2 levels
    And the options allow 1000 alias nodes
    When the text is parsed
    Then the value has 3 entries

  Scenario: A text over the size limit fails before it is read
    Given a text of 5000000 bytes
    When the text is parsed
    Then it fails with "yaml.limit" at line 1, column 1
    And the parse took fewer than 1000 steps

  Scenario: The size limit can be lowered
    Given the YAML text "key: value"
    And the options allow 5 bytes
    When the text is parsed
    Then it fails with "yaml.limit"

  Scenario: A depth outside 1 to 1000 is a bad argument
    Given the YAML text "key: value"
    And the options allow a depth of 5000
    When the text is parsed
    Then it fails with "argument"

  Scenario: Aliases of a big scalar stop at the alias bytes limit
    Given an anchor of 2000 bytes and 20 aliases of it
    And the options allow 10000 alias bytes
    When the text is parsed
    Then it fails with "yaml.limit" at line 2, column 25

  Scenario: The alias bytes limit can be raised
    Given an anchor of 1000 bytes and 20 aliases of it
    And the options allow 20000 alias bytes
    When the text is parsed
    Then it parses

  Scenario: Aliases cannot nest deeper than the depth limit
    Given a chain of 300 anchors, each in a list with the one before
    When the text is parsed
    Then it fails with "yaml.limit" at line 257, column 7

  Scenario: Many lines that look like keys parse in time linear in the text
    Given the Agentica program "fixtures/many_keys.agc"
    Then the program exits with code 0 within 20000 milliseconds
    And stdout is:
      """
      parsed 20000 lines in under 3000 ms

      """

  Scenario Outline: A hex integer past 64 bits keeps its digits up to 256 of them
    Given a hex integer of <digits> digits
    When the text is parsed
    Then <outcome>
    And the parse took fewer than 2000000 steps

    Examples:
      | digits | outcome                                           |
      | 256    | it parses                                         |
      | 257    | it fails with "yaml.parse" at line 1, column 8    |
      | 10000  | it fails with "yaml.parse" at line 1, column 8    |
