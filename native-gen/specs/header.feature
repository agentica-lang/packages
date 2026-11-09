Feature: The C header of an extern module block
  `cli.agc FILE` writes the C header of the one `extern module` block of FILE: typed prototypes for the C author and,
  under `PREFIX_NATIVE_IMPLEMENTATION`, the wrappers and tables of the module. The fixtures are packages whose C file
  is written on that header: `stats` is agentica's examples/native_module, with its header committed as the golden;
  `kinds` has every argument kind that the header decodes, the names it changes, a compute def and a resource, and a
  step makes its header before the build.

  Scenario Outline: The committed header of <name> is the one its .agc gives
    Given the program argument "fixtures/<name>/<name>.agc"
    And the program argument "--output"
    And the program argument "fixtures/<name>/native/<name>_native.h"
    And the program argument "--check"
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds

    Examples:
      | name  |
      | stats |

  Scenario Outline: The stats module on the header, built as <language>, gives the output of the hand-written one
    Given a fresh package cache
    And the environment variable "CC" is "<cc>"
    And the Agentica program "fixtures/stats/stats.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout is:
      """
      some(Summary(count: 3, min: 2.0, max: 9.0, mean: 5.0))
      none
      {"name": Cell.Text("kiwi"), "qty": Cell.Number(3.0), "note": Cell.Empty}
      {"name": Cell.Text("apple"), "qty": Cell.Number(1.5), "note": Cell.Text("ripe")}
      error("a row has another number of cells")

      """

    Examples:
      | language | cc                               |
      | C11      | cc -std=c11 -Wall -Wextra -Werror |
      | C++      | sh ../cxx.sh                     |

  Scenario Outline: Every kind of argument reaches the C function, built as <language>
    Given a fresh package cache
    And the environment variable "CC" is "<cc>"
    And the header of the package of "fixtures/kinds/kinds.agc"
    And the Agentica program "fixtures/kinds/kinds.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout is:
      """
      42
      -7 2.5 true héllo (2 bytes, last 255)
      [true, false]
      1 e 0 2 3
      6
      [none, some(Point(x: 3, y: 4))]

      """

    Examples:
      | language | cc                               |
      | C11      | cc -std=c11 -Wall -Wextra -Werror |
      | C++      | sh ../cxx.sh                     |

  Scenario Outline: Structs and enums come back equal through their C values, built as <language>
    Given a fresh package cache
    And the environment variable "CC" is "<cc>"
    And the header of the package of "fixtures/shapes/shapes.agc"
    And the Agentica program "fixtures/shapes/shapes.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout is:
      """
      true
      true
      [true, true, true]
      true
      Shape.Circle(Point(x: 1, y: 2), 0.5)

      """

    Examples:
      | language | cc                               |
      | C11      | cc -std=c11 -Wall -Wextra -Werror |
      | C++      | sh ../cxx.sh                     |

  Scenario Outline: A read of a bad value fails the call with the path of the bad part, built as <language>
    Given a fresh package cache
    And the environment variable "CC" is "<cc>"
    And the header of the package of "fixtures/shapes/shapes.agc"
    And the program argument "<call>"
    And the Agentica program "fixtures/shapes/shapes.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [RUNTIME-NATIVE-ERROR]
      <call>: <path>
      """

    Examples:
      | language | cc                                | call            | path                                 |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread         | Point: expected Point                |
      | C++      | sh ../cxx.sh                      | misread         | Point: expected Point                |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_nested  | Label.at.x: expected Int             |
      | C++      | sh ../cxx.sh                      | misread_nested  | Label.at.x: expected Int             |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | echo_label      | argument 1: Label.at.x: expected Int |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_payload | Shape.Circle.0.x: expected Int       |
      | C++      | sh ../cxx.sh                      | misread_payload | Shape.Circle.0.x: expected Int       |

  Scenario: The bench of a struct of 26 fields runs
    Given a fresh package cache
    And the header of the package of "../bench/wide/wide.agc"
    And the program argument "10"
    And the Agentica program "../bench/wide/wide.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout includes:
      """
      decode and make:
      """

  Scenario: The header goes to stdout without --output, with names from --prefix, in lower case for functions
    Given the program argument "fixtures/errors/path.agc"
    And the program argument "--prefix"
    And the program argument "Lib_Stats"
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout includes:
      """
      an_term lib_stats_count(an_env *env, an_term values);
      """
    And stdout includes:
      """
      #define LIB_STATS_NATIVE_MODULE(LOAD)
      """

  Scenario Outline: A file the header cannot be made for fails with <code>
    Given the program argument "fixtures/errors/<file>"
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [<code>]
      """

    Examples:
      | file           | code              |
      | clash.agc      | NATIVE-GEN-NAME   |
      | keyword.agc    | NATIVE-GEN-NAME   |
      | two_blocks.agc | NATIVE-GEN-BLOCK  |
      | no_block.agc   | NATIVE-GEN-BLOCK  |
      | reserved.agc   | NATIVE-GEN-NAME   |
      | fields.agc     | NATIVE-GEN-NAME   |
      | macro.agc      | NATIVE-GEN-NAME   |
      | path.agc       | NATIVE-GEN-PREFIX |
      | missing.agc    | QUERY-USAGE       |

  Scenario Outline: The prefix <prefix> is in the namespace of the C API
    Given the program argument "fixtures/stats/stats.agc"
    And the program argument "--prefix"
    And the program argument "<prefix>"
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-PREFIX]
      """

    Examples:
      | prefix   |
      | an       |
      | ng       |
      | AN_stats |
      | agentica |

  Scenario: A name in a C string is escaped
    Given the program argument "fixtures/escapes.agc"
    And the program argument "--prefix"
    And the program argument "odd"
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout includes:
      """
      AN_MODULE_TABLES("tab\011here \"q\" ?\?=", odd_native_functions, 1, NULL, 0, NULL, 0, LOAD)
      """

  Scenario: --output writes the header
    Given the header goes to a fresh folder as "stats_native.h"
    And the program argument "fixtures/stats/stats.agc"
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And the written header includes:
      """
      #define STATS_NATIVE_MODULE(LOAD) AN_MODULE_TABLES("stats", stats_native_functions, 2, stats_native_types, 2, NULL, 0, LOAD)
      #endif
      """

  Scenario: A header that cannot be written fails with NATIVE-GEN-IO
    Given the program argument "fixtures/stats/stats.agc"
    And the program argument "--output"
    And the program argument "fixtures/no-such-folder/stats_native.h"
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-IO]
      """

  Scenario: --check fails when the header is not the one the file gives
    Given the program argument "fixtures/stats/stats.agc"
    And the program argument "--output"
    And the program argument "fixtures/stats/native/stats.c"
    And the program argument "--check"
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-STALE]
      """

  Scenario: --check without --output is bad usage
    Given the program argument "fixtures/stats/stats.agc"
    And the program argument "--check"
    And the Agentica program "../cli.agc"
    Then the program exits with code 2 within 25000 milliseconds
    And stderr includes:
      """
      --check needs --output
      """
