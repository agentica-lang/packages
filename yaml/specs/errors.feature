Feature: Errors
  A text that is not valid YAML, or that has no JSON value, fails with an error of kind `yaml.parse`. Its message
  starts with the line and the column (from 1, in characters), and `details` has both.

  Scenario Outline: An invalid text fails where the problem is
    Given the YAML text:
      """
      <text>
      """
    When the text is parsed
    Then it fails with "yaml.parse" at line <line>, column <column>

    Examples:
      | case                         | text                         | line | column |
      | a mapping value on the line  | key: a: b                    | 1    | 7      |
      | a quote that never ends      | key: "open                   | 1    | 6      |
      | an unknown escape            | key: "\\q"                   | 1    | 7      |
      | a flow sequence never closed | key: [a, b                   | 1    | 6      |
      | text after a quoted scalar   | 'a' b                        | 1    | 5      |
      | an undefined alias           | key: *missing                | 1    | 6      |
      | a duplicate key              | a: 1\nb: 2\na: 3             | 3    | 1      |
      | a key that is an integer     | 200: ok                      | 1    | 1      |
      | a key that is a sequence     | [a, b]: c                    | 1    | 1      |
      | a custom tag                 | when: !timestamp 2001-12-14  | 1    | 7      |
      | a YAML 1.1 type              | set: !!set {a, b}            | 1    | 6      |
      | a bad indentation            | a:\n    b: 1\n  c: 2         | 3    | 3      |
      | a tab as indentation         | a:\n→b: 1                    | 2    | 1      |

  Scenario: The error names its line and column, and the position counts characters
    Given the YAML text:
      """
      título: "ñandú
      """
    When the text is parsed
    Then it fails with "yaml.parse" at line 1, column 9
