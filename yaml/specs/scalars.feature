Feature: Scalars
  `YAML.parse` reads a scalar of any style. A plain scalar is resolved by the core schema of YAML 1.2: a null, a
  boolean, an integer, a float or a string. A quoted or block scalar is always a string, and a core tag picks the type.

  Scenario Outline: A plain scalar takes the type of the core schema
    Given the YAML text "value: <text>"
    When the text is parsed
    Then the value is:
      """
      {"value": <json>}
      """

    Examples:
      | text                  | json                    |
      | ~                     | null                    |
      | null                  | null                    |
      | NULL                  | null                    |
      | true                  | true                    |
      | False                 | false                   |
      | yes                   | "yes"                   |
      | 42                    | 42                      |
      | -17                   | -17                     |
      | +8                    | 8                       |
      | 0x1F                  | 31                      |
      | 0o17                  | 15                      |
      | 12345678901234567890  | 12345678901234567890    |
      | 1.5                   | 1.5                     |
      | -.5                   | -0.5                    |
      | 1e3                   | 1000.0                  |
      | 6.02E+23              | 6.02e+23                |
      | 1_000                 | "1_000"                 |
      | 0b101                 | "0b101"                 |
      | 12:30                 | "12:30"                 |
      | hello world           | "hello world"           |
      | http://example.com/a  | "http://example.com/a"  |

  Scenario: An empty value is null
    Given the YAML text:
      """
      empty:
      also: # a comment
      """
    When the text is parsed
    Then the value is:
      """
      {"empty": null, "also": null}
      """

  Scenario: Infinity and NaN have no JSON value
    Given the YAML text:
      """
      ratio: 1
      limit: .inf
      """
    When the text is parsed
    Then it fails with "yaml.parse" at line 2, column 8

  Scenario: A plain scalar on several lines folds them with spaces
    Given the YAML text:
      """
      text: one
        two

        three
      """
    When the text is parsed
    Then the value is:
      """
      {"text": "one two\nthree"}
      """

  Scenario: Quoted scalars are strings, with the escapes of double quotes
    Given the YAML text:
      """
      single: 'it''s 42'
      double: "tab\there \u00e9 \x41 \"q\" \\"
      number: "42"
      folded: "one
        two"
      """
    When the text is parsed
    Then the value is:
      """
      {"single": "it's 42", "double": "tab\there é A \"q\" \\", "number": "42", "folded": "one two"}
      """

  Scenario: A literal block scalar keeps its lines, and a folded one joins them
    Given the YAML text:
      """
      literal: |
        line one
          indented
        line three
      folded: >
        one
        two

        three
      end: here
      """
    When the text is parsed
    Then the value is:
      """
      {"literal": "line one\n  indented\nline three\n", "folded": "one two\nthree\n", "end": "here"}
      """

  Scenario Outline: The chomping indicator decides the last line breaks
    Given the YAML text:
      """
      text: <header>
        words

      after: x
      """
    When the text is parsed
    Then the value is:
      """
      {"text": <json>, "after": "x"}
      """

    Examples:
      | header | json         |
      | \|     | "words\\n"   |
      | \|-    | "words"      |
      | \|+    | "words\\n\\n" |
      | >-     | "words"      |

  Scenario: An indentation indicator keeps the leading spaces of the first line
    Given the YAML text:
      """
      code: |2
           indented
         base
      end: here
      """
    When the text is parsed
    Then the value is:
      """
      {"code": "   indented\n base\n", "end": "here"}
      """

  Scenario: A core tag picks the type of a scalar
    Given the YAML text:
      """
      - !!str 42
      - !!int "42"
      - !!float 1
      - !!bool "true"
      - !!null ""
      - ! 12
      """
    When the text is parsed
    Then the value is:
      """
      ["42", 42, 1.0, true, null, "12"]
      """
