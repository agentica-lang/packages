Feature: Collections, anchors and documents
  Block and flow collections become JSON arrays and objects. An alias stands for the value of its anchor, a text may
  hold several documents, and comments are ignored.

  Scenario: Block mappings and sequences nest by indentation
    Given the YAML text:
      """
      # A service
      name: api
      ports:
        - 80
        - 443
      env:
        mode: production
        hosts:
        - a.example.com
        - b.example.com
      """
    When the text is parsed
    Then the value is:
      """
      {
        "name": "api",
        "ports": [80, 443],
        "env": {"mode": "production", "hosts": ["a.example.com", "b.example.com"]}
      }
      """

  Scenario: A sequence entry may be a compact mapping or sequence
    Given the YAML text:
      """
      - name: one
        size: 1
      - - a
        - b
      - ? explicit
        : value
      """
    When the text is parsed
    Then the value is:
      """
      [{"name": "one", "size": 1}, ["a", "b"], {"explicit": "value"}]
      """

  Scenario: Flow collections may span lines, and a pair in a flow sequence is a mapping
    Given the YAML text:
      """
      flow: {a: 1, "b": [x, 'y', {c: d}],
        e: }
      pairs: [one: 1, two: 2]
      empty: [[], {}]
      """
    When the text is parsed
    Then the value is:
      """
      {"flow": {"a": 1, "b": ["x", "y", {"c": "d"}], "e": null}, "pairs": [{"one": 1}, {"two": 2}], "empty": [[], {}]}
      """

  Scenario: An alias is the value of its anchor
    Given the YAML text:
      """
      base: &base {host: localhost, port: 5432}
      copy: *base
      names: [&first ana, *first]
      """
    When the text is parsed
    Then the value is:
      """
      {
        "base": {"host": "localhost", "port": 5432},
        "copy": {"host": "localhost", "port": 5432},
        "names": ["ana", "ana"]
      }
      """

  Scenario: A stream holds several documents
    Given the YAML text:
      """
      %YAML 1.2
      ---
      first: 1
      ...
      --- second
      ---
      # an empty document
      """
    When the stream is parsed
    Then the documents are:
      """
      [{"first": 1}, "second", null]
      """

  Scenario: YAML.parse reads one document and refuses a second
    Given the YAML text:
      """
      --- one
      --- two
      """
    When the text is parsed
    Then it fails with "yaml.parse" at line 2, column 1

  Scenario: An empty text is null
    Given the YAML text "# nothing but a comment"
    When the text is parsed
    Then the value is:
      """
      null
      """

  Scenario: Keys keep their order, and a big mapping parses
    Given a mapping of 400 entries
    When the text is parsed
    Then the value has 400 entries
