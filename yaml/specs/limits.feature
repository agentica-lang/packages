Feature: Limits
  The options bound the nesting depth, the nodes that aliases add and the size of the text, so a hostile text fails
  fast with an error of kind `yaml.limit` instead of using the stack or the memory. The defaults are a depth of 256,
  100,000 alias nodes and 4 MiB.

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
