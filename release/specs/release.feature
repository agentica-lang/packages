Feature: Releasing an app
  `build` makes a folder with the agentica binary, the compiled program, a launcher and a manifest, that runs from any
  place with nothing else installed. `tar` packs it and `inspect` checks it against its manifest. The project is the
  copy of `specs/fixtures/hello`: a program that prints the greeting of a file that the release carries, and exits with a
  code. "Alone" is a program started with an empty environment (no PATH, so no `agentica`), after the project is gone.
  In a table, {NL} stands for a line break and {Q} for a quote.

  Scenario: A release runs from another folder
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built
    And the project folder is removed
    And the release folder is moved to "else where"
    Then running "bin/hello" alone from the release with "a b" prints "hello from the assets (a b)" and exits with 0
    And running "bin/hello" alone from another folder with "fail" prints "hello from the assets (fail)" and exits with 3
    And the manifest lists these files:
      | path                  |
      | assets/greeting.toml  |
      | bin/hello             |
      | erts/agentica         |
      | lib/hello.agcb        |

  Scenario: The launcher stops when it is run through a link
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built
    Then running the launcher through a link fails saying "run it by its own path"

  Scenario Outline: inspect finds a release that is not its manifest
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built
    Then the release passes inspect
    When the release is damaged: "<damage>" "<file>"
    Then inspect fails as "release.corrupt" saying "<message>"

    Examples:
      | damage      | file                 | message                       |
      | changes     | lib/hello.agcb       | has another sha256            |
      | removes     | assets/greeting.toml | is missing                    |
      | adds        | extra.txt            | is not in the manifest        |
      | locks       | bin/hello            | is not executable             |
      | locks       | erts/agentica        | is not executable             |
      | lists       | ../x                 | must be a path inside         |

  Scenario: The folder packs as an archive that passes inspect
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built
    And the release is packed
    Then the archive is named for the version, the system and the architecture
    And the archive passes inspect
    And packing again fails as "release.invalid" saying "exists already"

  Scenario Outline: inspect refuses an archive that is not a release
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built
    And the release is packed
    And the archive is made again with "<addition>"
    Then inspecting the new archive fails as "release.corrupt" saying "<message>"

    Examples:
      | addition        | message                |
      | an extra file   | is not in the manifest |
      | a link          | link or a special file |
      | a name outside  | leaves the folder      |

  Scenario: A release is not written over another
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built
    Then building again fails as "release.invalid" saying "exists already"

  Scenario: A project that cannot be released is refused, and no folder is left
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    Then a project with each of these agentica.toml is refused:
      | agentica.toml                                                                  | kind            | message                 |
      | name = {Q}hello{Q}{NL}                                                         | release.invalid | set version             |
      | name = {Q}a/b{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}                    | release.invalid | name {Q}a/b{Q}          |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1 2{Q}{NL}                | release.invalid | version {Q}1 2{Q}       |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}entry = {Q}../m.agc{Q}{NL} | release.invalid | inside the project      |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}entry = {Q}main.txt{Q}{NL} | release.invalid | not an .agc file        |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}entry = {Q}nothing.agc{Q}{NL} | release.invalid | is not in the project   |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}include = [{Q}nothing{Q}]{NL} | release.invalid | is not in the project   |
      | name = {Q}hello{Q}{NL}agentica = {Q}9.9.9{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL} | release.failed | 9.9.9 |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}[native.x]{NL}linux = { file = {Q}native/libx.so{Q} }{NL} | release.invalid | agentica#1753 |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}[native.x]{NL}plan9 = { system = {Q}x{Q} }{NL} | release.invalid | shape that release does not know |

  Scenario: A link, or a path that leaves the project through one, is refused
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    And a file "outside/x.txt" beside the project
    And the project has a link "link_file" to "../outside/x.txt"
    And the project has a link "link_dir" to "../outside"
    And the project has a link "link_main.agc" to "main.agc"
    Then a project with each of these agentica.toml is refused:
      | agentica.toml                                                                  | kind            | message              |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}include = [{Q}link_file{Q}]{NL} | release.invalid | is a link            |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}include = [{Q}link_dir/x.txt{Q}]{NL} | release.invalid | leaves the project   |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}entry = {Q}link_main.agc{Q}{NL} | release.invalid | is a link            |

  Scenario: A build that fails after it started leaves nothing
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    Then building with a program that is not agentica fails as "release.failed" saying "not a compiler" and leaves nothing

  Scenario: A dependency with a native library stored by path is refused
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    And the project has the dependency "dep" with this agentica.toml:
      """
      name = "dep"

      [native.x]
      linux = { file = "native/libx.so" }
      """
    Then building fails as "release.invalid" saying "deps/dep/agentica.toml"

  Scenario: A dependency of a namespace is read from its own folder of deps
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    And the project has the dependency "ns/sub" with this agentica.toml:
      """
      name = "sub"

      [native.x]
      linux = { system = "libx.so", extra = 1 }
      """
    Then building fails as "release.invalid" saying "deps/ns/sub/agentica.toml"

  Scenario: A dependency by path is read from its folder, inside the project or not
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    And the project has the path dependency "dep" at "libs/dep" with this agentica.toml:
      """
      name = "dep"

      [native.x]
      macos = { file = "native/libx.dylib" }
      """
    Then building fails as "release.invalid" saying "libs/dep/agentica.toml"

  Scenario: A dependency by path outside the project is read too
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    And the project has the path dependency "dep" at "../shared/dep" with this agentica.toml:
      """
      name = "dep"

      [native.x]
      build = { sources = ["native/x.c"] }
      """
    Then building fails as "release.invalid" saying "shared/dep/agentica.toml"

  Scenario: A member of the workspace of the project is read from the workspace
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    And the project is in a workspace with the member "member" that has this agentica.toml:
      """
      name = "member"

      [native.x]
      linux = "libx.so"
      """
    Then building fails as "release.invalid" saying "dependency member"

  Scenario: A package of the lock that is not installed is refused
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    And the lock names the package "dep" that is not installed
    Then building fails as "release.invalid" saying "deps/dep"

  Scenario: A folder of deps that the lock does not name is not read
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    And the folder "stale" of deps has this agentica.toml:
      """
      name = "stale"

      [native.x]
      linux = { file = "native/libx.so" }
      """
    When the release is built
    Then the release passes inspect

  Scenario: A library found by name is listed for the target
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built from this agentica.toml:
      """
      name = "hello"

      [tool.release]
      version = "1.2.3"
      include = ["assets"]

      [native.m]
      linux = { system = "libm.so.6" }
      macos = { system = "libm.dylib" }
      windows = { system = "m.dll" }
      """
    Then the release lists the system library "libm.so.6" on linux, "libm.dylib" on macos and "m.dll" on windows

  Scenario: The command line builds, packs and inspects
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    Then these commands of cli.agc give these exit codes and lines:
      | arguments                                   | exit | says             |
      | build project --out out                     | 0    | release: built   |
      | build project --out out                     | 1    | exists already   |
      | tar out/hello-1.2.3                         | 0    | release: wrote   |
      | inspect out/hello-1.2.3                     | 0    | files match      |
      | inspect out/missing                         | 1    | is not there |
      | frobnicate                                  | 2    | usage            |
