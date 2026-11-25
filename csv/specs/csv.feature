Feature: Reading and writing CSV
  The fixed cases follow RFC 4180. In a table, {CRLF}, {LF}, {TAB} and {Q} stand for a CRLF, a LF, a tab and a quote;
  the rows are JSON.

  Scenario: Rows, quotes and line breaks are read
    Then csv reads these texts:
      | text                       | rows                              |
      | a,b{CRLF}c,d{CRLF}             | [["a","b"],["c","d"]]             |
      | a,b{LF}c,d                   | [["a","b"],["c","d"]]             |
      | a,,c{CRLF}                   | [["a","","c"]]                    |
      | a,                         | [["a",""]]                        |
      | {Q}a,b{Q},c                  | [["a,b","c"]]                     |
      | {Q}a{Q}{Q}b{Q},c               | [["a{Q}b","c"]]                    |
      | {Q}line 1{CRLF}line 2{Q},x{CRLF} | [["line 1{CRLF}line 2","x"]]        |
      | {Q}{Q}                       | [[""]]                            |
      | {CRLF}                       | [[""]]                            |
      | é,✓{CRLF}                    | [["é","✓"]]                       |
      |                            | []                                |
      | {BOM}name,age{CRLF}ann,31  | [["name","age"],["ann","31"]]     |
      | a{CR}b                     | [["a{CR}b"]]                      |
      | a,b{LF}c,d{LF}             | [["a","b"],["c","d"]]             |
      | {Q}a{Q},{Q}b{Q}            | [["a","b"]]                       |
      | a,b{CRLF}c,d               | [["a","b"],["c","d"]]             |

  Scenario: A text that is not CSV is refused with its line
    Then csv refuses these texts as "csv.malformed":
      | text                  | line |
      | a,{Q}b{CRLF}             | 1    |
      | a{CRLF}b,{Q}c{CRLF}d       | 2    |
      | {Q}a{Q}b                | 1    |
      | a,b{Q}c                | 1    |
      | x{CRLF}{Q}a{Q}{Q}b{CRLF}y    | 2    |
      | {Q}a{Q}{CR}b          | 1    |

  Scenario: Another separator is read and written
    Then csv reads these texts with the separator ";":
      | text            | rows                |
      | a;b,c{CRLF}1;2{CRLF} | [["a","b,c"],["1","2"]] |
    And csv writes these rows with the separator "{TAB}":
      | rows                    | text              |
      | [["a b","c{TAB}d"]]        | a b{TAB}{Q}c{TAB}d{Q}{CRLF} |

  Scenario: A bad separator is invalid
    Then csv refuses these separators:
      | separator |
      | ab        |
      | {Q}        |
      | {LF}        |

  Scenario: Rows are written with the quotes they need
    Then csv writes these rows:
      | rows                          | text                      |
      | [["a","b"],["c","d"]]         | a,b{CRLF}c,d{CRLF}            |
      | [["a,b","c{Q}d","e{LF}f"]]       | {Q}a,b{Q},{Q}c{Q}{Q}d{Q},{Q}e{LF}f{Q}{CRLF} |
      | [[""]]                        | {Q}{Q}{CRLF}                  |
      | [["",""]]                     | ,{CRLF}                     |
      | [["a b"," ","é"]]             | a b, ,é{CRLF}               |
      | []                            |                           |

  Scenario: Rows as maps use the header
    Then csv reads these texts as maps:
      | text                                | maps                                              |
      | name,age{CRLF}ann,31{CRLF}bob,{CRLF}       | [{"name":"ann","age":"31"},{"name":"bob","age":""}] |
      |                                     | []                                                |
      | a{CRLF}                              | []                                                |
    And csv reads these texts as maps:
      | text                         | maps                                         |
      | a,b{CRLF}1,2{CRLF}{CRLF}       | [{"a":"1","b":"2"}]                          |
      | a{CRLF}1{CRLF}{CRLF}2          | [{"a":"1"},{"a":""},{"a":"2"}]               |
    And csv refuses these texts as maps:
      | text           | kind          |
      | a,b{CRLF}1{CRLF}    | csv.malformed |
      | a,a{CRLF}1,2{CRLF}  | csv.malformed |
    And csv writes these maps:
      | header   | maps                                                   | text                      |
      | name,age | [{"age":"31","name":"ann","extra":"x"},{"name":"bob"}] | name,age{CRLF}ann,31{CRLF}bob,{CRLF} |

  Scenario Outline: The text of a peer table is read and written as Python's csv does
    Then the peer's 30 tables from the seed <seed> with the separator "<separator>" read and write as the peer says

    Examples:
      | seed | separator |
      | 1    | ,         |
      | 2    | ;         |
      | 3    | ,         |
