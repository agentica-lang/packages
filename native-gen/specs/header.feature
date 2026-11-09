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

  Scenario: --lang rust writes the Rust file, whose trait is named after --prefix
    Given the program argument "fixtures/stats/stats.agc"
    And the program argument "--lang"
    And the program argument "rust"
    And the program argument "--prefix"
    And the program argument "csv_stats"
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout includes:
      """
      pub trait CsvStatsNative {
          /// The count, smallest, largest and mean of the values; none for no values.
          fn summary(env: Env<'_>, values: Vec<f64>) -> Result<Option<Summary>, Raise>;
      """
    And stdout includes:
      """
          Module::new("stats")
              .function("summary", "(List[Float]) -> Optional[Summary]", native_summary::<I>, Mode::Short)
      """

  Scenario: --lang rust marks as text the code blocks of a doc that rustdoc would run
    Given the program argument "fixtures/shapes2/shapes2.agc"
    And the program argument "--lang"
    And the program argument "rust"
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout includes:
      """
          /// ```text
          /// chain(2) == Node(value: 2, next: some(Node(value: 1, next: none)))
          /// ```
          ///
          /// ```text
          ///     chain(0) is a node of 0
          ///
          /// ```
          /// ~~~text
          /// no Rust here either
          /// ~~~
          ///
          /// ````text
          /// a fence of four, closed by five
          /// `````
          ///
          /// - an item
          ///
          ///     more of the item, not code
          fn chain<'a>
      """

  Scenario: --lang rust keeps the case of --prefix in the name of the trait
    Given the program argument "fixtures/stats/stats.agc"
    And the program argument "--lang"
    And the program argument "rust"
    And the program argument "--prefix"
    And the program argument "MyDb"
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout includes:
      """
      pub trait MyDbNative {
      """

  Scenario: --check --lang rust fails when the file is not the one the .agc gives
    Given the program argument "fixtures/stats/stats.agc"
    And the program argument "--lang"
    And the program argument "rust"
    And the program argument "--output"
    And the program argument "fixtures/stats/native/stats.c"
    And the program argument "--check"
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-STALE]
      """

  Scenario: --lang rust refuses a prefix that is not an identifier
    Given the program argument "fixtures/stats/stats.agc"
    And the program argument "--lang"
    And the program argument "rust"
    And the program argument "--prefix"
    And the program argument "my-db"
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-PREFIX]
      """

  Scenario Outline: A file the Rust file cannot be made for fails with <code>
    Given the program argument "fixtures/errors/<file>"
    And the program argument "--lang"
    And the program argument "rust"
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [<code>]
      """

    Examples:
      | file             | code             |
      | clash.agc        | NATIVE-GEN-NAME  |
      | rust_keyword.agc | NATIVE-GEN-NAME  |
      | rust_prelude.agc | NATIVE-GEN-NAME  |
      | rust_self.agc    | NATIVE-GEN-NAME  |
      | two_blocks.agc   | NATIVE-GEN-BLOCK |

  Scenario: --lang other than c or rust is bad usage
    Given the program argument "fixtures/stats/stats.agc"
    And the program argument "--lang"
    And the program argument "go"
    And the Agentica program "../cli.agc"
    Then the program exits with code 2 within 25000 milliseconds

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
      2

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

  Scenario Outline: Lists and Maps come in through cursors and go out through builders, built as <language>
    Given a fresh package cache
    And the environment variable "CC" is "<cc>"
    And the header of the package of "fixtures/lists/lists.agc"
    And the Agentica program "fixtures/lists/lists.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout is:
      """
      [3.5, 0.0, 4.0]
      {"ab": [97, 98], "": [], "é": [195, 169]}
      [Point(x: 11, y: 22), Point(x: 9, y: 20)]
      [1025, 0]

      """

    Examples:
      | language | cc                                |
      | C11      | cc -std=c11 -Wall -Wextra -Werror |
      | C++      | sh ../cxx.sh                      |

  Scenario Outline: A bad item of a List or Map fails the call with its index, built as <language>
    Given a fresh package cache
    And the environment variable "CC" is "<cc>"
    And the header of the package of "fixtures/lists/lists.agc"
    And the program argument "<call>"
    And the Agentica program "fixtures/lists/lists.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [RUNTIME-NATIVE-ERROR]
      <call>: <path>
      """

    Examples:
      | language | cc                                | call                    | path                                                        |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_list            | List[Int].1: expected Int                                   |
      | C++      | sh ../cxx.sh                      | misread_list            | List[Int].1: expected Int                                   |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_map             | Map[String, Point].0.value.x: expected Int                  |
      | C++      | sh ../cxx.sh                      | misread_map             | Map[String, Point].0.value.x: expected Int                  |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_argument        | argument 1: List[List[Float]].1: expected List[Float]       |
      | C++      | sh ../cxx.sh                      | misread_argument        | argument 1: List[List[Float]].1: expected List[Float]       |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_nested_argument | argument 1: List[Float].1: expected Float                   |
      | C++      | sh ../cxx.sh                      | misread_nested_argument | argument 1: List[Float].1: expected Float                   |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_map_argument    | argument 1: Map[Int, List[Int]].2.value: expected List[Int] |
      | C++      | sh ../cxx.sh                      | misread_map_argument    | argument 1: Map[Int, List[Int]].2.value: expected List[Int] |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_map_value       | argument 1: List[Int].2: expected Int                       |
      | C++      | sh ../cxx.sh                      | misread_map_value       | argument 1: List[Int].2: expected Int                       |

  Scenario Outline: Optional and Result come in as structs and go out through constructors, built as <language>
    Given a fresh package cache
    And the environment variable "CC" is "<cc>"
    And the header of the package of "fixtures/options/options.agc"
    And the Agentica program "fixtures/options/options.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout is:
      """
      [some(Point(x: 1, y: 2)), none]
      [ok(3), error("no")]
      [some(ok([1, 2])), some(error("e")), none]
      [some("b"), none]
      [104, 3]

      """

    Examples:
      | language | cc                                |
      | C11      | cc -std=c11 -Wall -Wextra -Werror |
      | C++      | sh ../cxx.sh                      |

  Scenario Outline: A bad value in an Optional or Result fails the call with its path, built as <language>
    Given a fresh package cache
    And the environment variable "CC" is "<cc>"
    And the header of the package of "fixtures/options/options.agc"
    And the program argument "<call>"
    And the Agentica program "fixtures/options/options.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [RUNTIME-NATIVE-ERROR]
      <call>: <path>
      """

    Examples:
      | language | cc                                | call             | path                                         |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_result   | List[Result[Int]].0.ok: expected Int         |
      | C++      | sh ../cxx.sh                      | misread_optional | List[Optional[Point]].0.some.x: expected Int |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_nested   | argument 1: List[Int].2: expected Int        |
      | C++      | sh ../cxx.sh                      | misread_nested   | argument 1: List[Int].2: expected Int        |
      | C11      | cc -std=c11 -Wall -Wextra -Werror | misread_inner    | argument 1: List[Int].3: expected Int        |
      | C++      | sh ../cxx.sh                      | misread_inner    | argument 1: List[Int].3: expected Int        |

  Scenario Outline: A resource parameter is its state and each dropped resource is freed once, built as <language>
    Given a fresh package cache
    And the environment variable "CC" is "<cc>"
    And the header of the package of "fixtures/resources/resources.agc"
    And the Agentica program "fixtures/resources/resources.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And stdout is:
      """
      500500
      1000
      [7, 8]
      false

      """

    Examples:
      | language | cc                                |
      | C11      | cc -std=c11 -Wall -Wextra -Werror |
      | C++      | sh ../cxx.sh                      |

  Scenario Outline: native new writes a module that builds and loads with nothing filled in, built as <language>
    Given a fresh package cache
    And the C compiler builds as "<language>"
    And a fresh folder
    And native new "demo" in the fresh folder
    And the header of "demo.agc" in the fresh folder passes --check
    And the Agentica program "demo.agc" in the fresh folder
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [RUNTIME-NATIVE-ERROR]
      add: not written yet
      """

    Examples:
      | language |
      | C11      |
      | C++      |

  Scenario: native new adds its entry to the agentica.toml that is there, and keeps the rest
    Given a fresh package cache
    And a fresh folder
    And the agentica.toml of the fresh folder is:
      """
      name = "pkg"

      [dependencies]
      """
    And native new "demo" in the fresh folder
    And the Agentica program "demo.agc" in the fresh folder
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      add: not written yet
      """
    And the agentica.toml of the fresh folder starts with:
      """
      name = "pkg"

      [dependencies]

      # native/demo.c is written on native/demo_native.h
      """

  Scenario Outline: native new refuses an agentica.toml with native.demo already, written as <form>, and writes nothing
    Given a fresh folder
    And the agentica.toml of the fresh folder has the line "<form>"
    And the program argument "new"
    And the program argument "demo" in the fresh folder
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-EXISTS]
      """
    And the fresh folder has no "demo.agc"
    And the fresh folder has no "native"
    And the agentica.toml of the fresh folder still has only the line "<form>"

    Examples:
      | form                                  |
      | [native.demo]                         |
      | native.demo.build = { sources = [] } |

  Scenario: native new refuses to write over a module that is there
    Given a fresh folder
    And native new "demo" in the fresh folder
    And the program argument "new"
    And the program argument "demo" in the fresh folder
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-EXISTS]
      """

  Scenario Outline: native new refuses the name <path>
    Given the program argument "new"
    And the program argument "<path>"
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-PREFIX]
      """

    Examples:
      | path     |
      | ng       |
      | Demo     |
      | demo.agc |

  Scenario Outline: native new --lang rust writes the module <name> and its crate, whose Rust file is current
    Given a fresh folder
    And native new --lang rust "<name>" in the fresh folder
    And the fresh folder has "rust/Cargo.toml"
    And the fresh folder has "rust/src/lib.rs"
    And the fresh folder has "rust/.gitignore"
    And the fresh folder has no "native"
    And the agentica.toml of the fresh folder has only the name "<name>"
    And the program argument "build"
    And the program argument "<name>.agc" in the fresh folder
    And the program argument "--check"
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds

    Examples:
      | name   |
      | demo   |
      | raise  |
      | result |

  Scenario: native new --lang rust keeps the agentica.toml that is there as it is
    Given a fresh folder
    And the agentica.toml of the fresh folder is "name = 'pkg'"
    And native new --lang rust "demo" in the fresh folder
    Then the agentica.toml of the fresh folder is exactly "name = 'pkg'"
    And the fresh folder has "rust/src/lib.rs"

  Scenario: native new --lang rust FOLDER/NAME in a package puts the crate at the package root
    Given a fresh folder
    And the agentica.toml of the fresh folder has the line ""
    And native new --lang rust "src/demo" in the fresh folder
    And the fresh folder has "src/demo.agc"
    And the fresh folder has "rust/src/lib.rs"
    And the fresh folder has no "src/rust"
    And the fresh folder has no "src/agentica.toml"
    And the agentica.toml of the fresh folder still has only the line ""
    And the program argument "build"
    And the program argument "src/demo.agc" in the fresh folder
    And the program argument "--check"
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds

  Scenario: native new --lang rust writes the Cargo.toml and .gitignore of examples/rust_math for math
    Then native new --lang rust "math" writes the files of "../examples/rust_math"
    And the rust-version that native new --lang rust writes is the one of "../native/agentica-native/Cargo.toml"

  Scenario Outline: native new --lang rust refuses a folder with <file> already, and writes nothing
    Given a fresh folder
    And the file "<file>" in the fresh folder is:
      """
      kept
      """
    And the program argument "new"
    And the program argument "--lang"
    And the program argument "rust"
    And the program argument "demo" in the fresh folder
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-EXISTS]
      """
    And the fresh folder has no "agentica.toml"
    And the fresh folder has no "<absent>"

    Examples:
      | file                    | absent   |
      | demo.agc                | rust     |
      | rust/Cargo.toml         | demo.agc |
      | rust/.gitignore         | demo.agc |
      | rust/src/lib.rs         | demo.agc |
      | rust/src/demo_native.rs | demo.agc |

  Scenario Outline: native new --lang rust refuses the name <path>
    Given the program argument "new"
    And the program argument "--lang"
    And the program argument "rust"
    And the program argument "<path>"
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-PREFIX]
      """

    Examples:
      | path   |
      | Demo   |
      | fn     |
      | test   |
      | env_   |
      | a__b   |

  Scenario: native new --lang go is bad usage
    Given the program argument "new"
    And the program argument "--lang"
    And the program argument "go"
    And the program argument "demo"
    And the Agentica program "../cli.agc"
    Then the program exits with code 2 within 25000 milliseconds
    And stderr includes:
      """
      --lang is c or rust
      """

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
      an_term lib_stats_count(an_env *env, lib_stats_list_Int values);
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

  Scenario: build --check passes on the committed Rust file of examples/rust_math
    Given the program argument "build"
    And the program argument "../examples/rust_math/math.agc"
    And the program argument "--check"
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds

  Scenario: build --check fails when the Rust file is not the one the .agc gives
    Given a fresh package with the Rust module in "demo.agc"
    And the file "rust/src/demo_native.rs" in the fresh folder is:
      """
      // an older block
      """
    And the program argument "build"
    And the program argument "demo.agc" in the fresh folder
    And the program argument "--check"
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-STALE]
      """

  Scenario: build of a file below the package root uses the crate, the manifest and native/ of the root
    Given a fresh package with the Rust module in "src/demo.agc"
    And a fake cargo on PATH that exits with 0 and prints:
      """
      {"reason":"compiler-artifact","target":{"kind":["cdylib"]},"filenames":["FOLDER/libdemoEXT"]}
      {"reason":"build-finished","success":true}
      """
    And the program argument "build"
    And the program argument "src/demo.agc" in the fresh folder
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And the fresh folder has "rust/src/demo_native.rs"
    And the fresh folder has the library of "demo"
    And the agentica.toml of the fresh folder has the entry of "demo"
    And the fresh folder has no "src/rust"
    And the fresh folder has no "src/native"
    And the fresh folder has no "src/agentica.toml"
    And the fresh folder has no "src/demo_native.rs"

  Scenario: build of a FILE given relative to the current folder finds the root from it
    Given a fresh package with the Rust module in "src/demo.agc"
    And a fake cargo on PATH that exits with 0 and prints:
      """
      {"reason":"compiler-artifact","target":{"kind":["cdylib"]},"filenames":["FOLDER/libdemoEXT"]}
      """
    And the program argument "build"
    And the program argument "src/demo.agc" in the fresh folder, relative to the current folder
    And the Agentica program "../cli.agc"
    Then the program exits with code 0 within 25000 milliseconds
    And the fresh folder has the library of "demo"
    And the agentica.toml of the fresh folder has the entry of "demo"

  Scenario: build run in the package root prints the paths below it relative to it
    Given a fresh package with the Rust module in "demo.agc"
    And a fake cargo on PATH that exits with 0 and prints:
      """
      {"reason":"compiler-artifact","target":{"kind":["cdylib"]},"filenames":["FOLDER/target/libdemoEXT"]}
      """
    And a program in the fresh folder that runs build of "demo.agc" there
    Then the program exits with code 0 within 25000 milliseconds
    And stdout includes:
      """
      wrote rust/src/demo_native.rs
      copied target/libdemo
      """
    And stdout includes:
      """
      to agentica.toml
      """

  # The fresh folder is in TMPDIR (or /tmp): this assumes no folder above it has an agentica.toml. The steps cannot
  # make a folder above the temp folder, so the scenario cannot rule that out itself.
  Scenario: build without an agentica.toml up from the file fails with NATIVE-GEN-IO
    Given a fresh folder
    And the file "demo.agc" in the fresh folder is:
      """
      extern module "demo"
        def add(a: Int, b: Int) -> Int
      end
      """
    And the program argument "build"
    And the program argument "demo.agc" in the fresh folder
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-IO]
      """

  Scenario: build without a crate in rust/ fails with NATIVE-GEN-IO and writes nothing
    Given a fresh package with the Rust module in "demo.agc"
    And the file "rust/Cargo.toml" in the fresh folder is removed
    And the program argument "build"
    And the program argument "demo.agc" in the fresh folder
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-IO]
      """
    And the fresh folder has no "rust/src"
    And the agentica.toml of the fresh folder still has only the line ""

  Scenario: build without cargo on PATH fails with NATIVE-GEN-CARGO and leaves agentica.toml as it was
    Given a fresh package with the Rust module in "demo.agc"
    And the environment variable "PATH" is "/nonexistent-native-gen"
    And the program argument "build"
    And the program argument "demo.agc" in the fresh folder
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-CARGO] cannot run cargo
      """
    And the agentica.toml of the fresh folder still has only the line ""
    And the fresh folder has no "native"

  Scenario Outline: build fails with NATIVE-GEN-CARGO when cargo <case>, and leaves agentica.toml as it was
    Given a fresh package with the Rust module in "demo.agc"
    And a fake cargo on PATH that exits with <code> and prints:
      """
      {"reason":"compiler-artifact","target":{"kind":["lib"]},"filenames":["FOLDER/libdemo.rlib"]}
      {"reason":"compiler-artifact","target":{"kind":["cdylib"]},"filenames":[<files>]}
      """
    And the program argument "build"
    And the program argument "demo.agc" in the fresh folder
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-CARGO]
      """
    And the fresh folder has "rust/src/demo_native.rs"
    And the agentica.toml of the fresh folder still has only the line ""
    And the fresh folder has no "native"

    Examples:
      | case               | code | files                                   |
      | fails              | 101  | "FOLDER/libdemoEXT"                     |
      | builds no cdylib   | 0    |                                         |
      | builds two cdylibs | 0    | "FOLDER/libdemoEXT", "FOLDER/libtwoEXT" |

  Scenario Outline: build refuses an agentica.toml where <case>, before it runs cargo
    Given a fresh package with the Rust module in "demo.agc"
    And the agentica.toml of the fresh folder has the line "<entry>"
    And the environment variable "PATH" is "/nonexistent-native-gen"
    And the program argument "build"
    And the program argument "demo.agc" in the fresh folder
    And the Agentica program "../cli.agc"
    Then the program exits with code 1 within 25000 milliseconds
    And stderr includes:
      """
      [NATIVE-GEN-MANIFEST]
      """
    And the agentica.toml of the fresh folder still has only the line "<entry>"

    Examples:
      | case                                   | entry                                     |
      | native.demo builds C sources           | native.demo.build = { sources = [] }      |
      | native.demo is an inline table         | native = { demo = { optional = false } }  |
      | native is an inline table without demo | native = { other = { optional = false } } |

  Scenario: build adds the entry of the system under the [native.NAME] line, and keeps the rest
    Given a fresh folder
    And the agentica.toml of the fresh folder is:
      """
      name = "pkg"

      [native.demo] # the Rust module
      windows = { file = "native/demo.dll" }

      [dependencies]
      """
    Then the entry of "demo" on "linux" added to the agentica.toml of the fresh folder gives:
      """
      name = "pkg"

      [native.demo] # the Rust module
      linux = { file = "native/libdemo.so" }
      windows = { file = "native/demo.dll" }

      [dependencies]
      """

  Scenario Outline: build keeps the CRLF lines of an agentica.toml <form>
    Given a fresh folder
    And the agentica.toml of the fresh folder is "<text>" with CRLF lines
    Then the entry of "demo" on "linux" added to the agentica.toml of the fresh folder has only CRLF lines

    Examples:
      | form              | text                                                    |
      | with the table    | name = 'pkg'\n\n[native.demo]\nmacos = { system = 'a' }\n |
      | without the table | name = 'pkg'\n                                          |

  Scenario Outline: build refuses an agentica.toml where <case>
    Given a fresh folder
    And the agentica.toml of the fresh folder is "<text>"
    Then the entry of "demo" on "linux" cannot be added: "[NATIVE-GEN-MANIFEST]"

    Examples:
      | case                                       | text                                                              |
      | the entry of the system has no file        | name = 'pkg'\nnative.demo.linux = { system = 'libdemo.so' }\n     |
      | the entry's file is outside native/        | name = 'pkg'\nnative.demo.linux = { file = '../libdemo.so' }\n    |
      | the entry's file has a .. part             | name = 'pkg'\nnative.demo.linux = { file = 'native/../x.so' }\n   |
      | the only [native.demo] line is in a string | name = 'pkg'\nnote = '''\n[native.demo]\n'''\nnative.demo.x = 1\n |
      | the entry's file is native/                | name = 'pkg'\nnative.demo.linux = { file = 'native/' }            |
      | the entry's file is native/.               | name = 'pkg'\nnative.demo.linux = { file = 'native/.' }           |
      | the entry's file has an empty part         | name = 'pkg'\nnative.demo.linux = { file = 'native//x.so' }       |

  Scenario Outline: build plans again on an agentica.toml that changed during the build, where <case>
    Given a fresh folder
    And the agentica.toml of the fresh folder has the line ""
    Then the entry of "demo" on "linux", planned before agentica.toml became "<now>", gives "<result>"

    Examples:
      | case         | now                                                | result                |
      | table added  | [dependencies]                                     | added                 |
      | same entry   | native.demo.linux = { file = 'native/libdemo.so' } | kept                  |
      | another file | native.demo.linux = { file = 'native/o.so' }       | [NATIVE-GEN-MANIFEST] |
      | invalid TOML | name =                                             | [NATIVE-GEN-MANIFEST] |

  Scenario: build refuses an agentica.toml whose entry was removed during the build, as it names another file now
    Given a fresh folder
    And the agentica.toml of the fresh folder has the line "native.demo.linux = { file = 'native/c.so' }"
    Then the entry of "demo" on "linux", planned before agentica.toml became "", gives "[NATIVE-GEN-MANIFEST]"

  Scenario Outline: build names the library of demo on <os> <file>
    Then the library of "demo" on "<os>" is "<file>"

    Examples:
      | os      | file                 |
      | linux   | native/libdemo.so    |
      | macos   | native/libdemo.dylib |
      | windows | native/demo.dll      |
      | plan9   | [NATIVE-GEN-OS]      |
