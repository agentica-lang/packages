Feature: Reading and writing CSV
  The fixed cases follow RFC 4180. In a table, a text is written as a JSON string without its outer quotes, so \r, \n and
  \" stand for a CR, a LF and a quote; the rows are JSON.

  Scenario: Rows, quotes and line breaks are read
    Then csv reads these texts:
      | text                       | rows                              |
      | a,b\r\nc,d\r\n             | [["a","b"],["c","d"]]             |
      | a,b\nc,d                   | [["a","b"],["c","d"]]             |
      | a,,c\r\n                   | [["a","","c"]]                    |
      | a,                         | [["a",""]]                        |
      | \"a,b\",c                  | [["a,b","c"]]                     |
      | \"a\"\"b\",c               | [["a\"b","c"]]                    |
      | \"line 1\r\nline 2\",x\r\n | [["line 1\r\nline 2","x"]]        |
      | \"\"                       | [[""]]                            |
      | \r\n                       | [[""]]                            |
      | é,✓\r\n                    | [["é","✓"]]                       |
      |                            | []                                |

  Scenario: A text that is not CSV is refused with its line
    Then csv refuses these texts as "csv.malformed":
      | text                  | line |
      | a,\"b\r\n             | 1    |
      | a\r\nb,\"c\r\nd       | 2    |
      | \"a\"b                | 1    |
      | a,b\"c                | 1    |
      | x\r\n\"a\"\"b\r\ny    | 2    |

  Scenario: Another separator is read and written
    Then csv reads these texts with the separator ";":
      | text            | rows                |
      | a;b,c\r\n1;2\r\n | [["a","b,c"],["1","2"]] |
    And csv writes these rows with the separator "\t":
      | rows                    | text              |
      | [["a b","c\td"]]        | a b\t\"c\td\"\r\n |

  Scenario: A bad separator is invalid
    Then csv refuses these separators:
      | separator |
      | ab        |
      | \"        |
      | \n        |

  Scenario: Rows are written with the quotes they need
    Then csv writes these rows:
      | rows                          | text                      |
      | [["a","b"],["c","d"]]         | a,b\r\nc,d\r\n            |
      | [["a,b","c\"d","e\nf"]]       | \"a,b\",\"c\"\"d\",\"e\nf\"\r\n |
      | [[""]]                        | \"\"\r\n                  |
      | [["",""]]                     | ,\r\n                     |
      | [["a b"," ","é"]]             | a b, ,é\r\n               |
      | []                            |                           |

  Scenario: Rows as maps use the header
    Then csv reads these texts as maps:
      | text                                | maps                                              |
      | name,age\r\nann,31\r\nbob,\r\n       | [{"name":"ann","age":"31"},{"name":"bob","age":""}] |
      |                                     | []                                                |
      | a\r\n                              | []                                                |
    And csv refuses these texts as maps:
      | text           | kind          |
      | a,b\r\n1\r\n    | csv.malformed |
      | a,a\r\n1,2\r\n  | csv.malformed |
    And csv writes these maps:
      | header   | maps                                                   | text                      |
      | name,age | [{"age":"31","name":"ann","extra":"x"},{"name":"bob"}] | name,age\r\nann,31\r\nbob,\r\n |

  Scenario Outline: The text of a peer table is read and written as Python's csv does
    Then the peer's 30 tables from the seed <seed> with the separator "<separator>" read and write as the peer says

    Examples:
      | seed | separator |
      | 1    | ,         |
      | 2    | ;         |
      | 3    | ,         |
