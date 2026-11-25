Feature: Releasing an app
  `build` makes a folder with the agentica binary, the compiled program, a launcher and a manifest, that runs from any
  place with nothing else installed. `tar` packs it and `inspect` checks it against its manifest. The project is the
  copy of `specs/fixtures/hello`: a program that prints the greeting of a file that the release carries, and exits with a
  code. In a table, {NL} stands for a line break and {Q} for a quote.

  Scenario: A release runs from another folder
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built
    And the release folder is moved to "elsewhere"
    Then running "bin/hello" with "a b" prints "hello from the assets (a b)" and exits with 0
    And running "bin/hello" with "fail" prints "hello from the assets (fail)" and exits with 3
    And the manifest lists these files:
      | path                |
      | assets/greeting.txt |
      | bin/hello           |
      | erts/agentica       |
      | lib/hello.agcb      |

  Scenario Outline: inspect finds a release that is not its manifest
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built
    Then the release passes inspect
    When the release is damaged: "<damage>" "<file>"
    Then inspect fails as "release.corrupt" saying "<message>"

    Examples:
      | damage  | file                | message                  |
      | changes | lib/hello.agcb      | has another sha256       |
      | removes | assets/greeting.txt | is missing               |
      | adds    | extra.txt           | is not in the manifest   |

  Scenario: The folder packs as an archive that passes inspect
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built
    And the release is packed
    Then the archive is named for the version, the system and the architecture
    And the archive passes inspect

  Scenario: A release is not written over another
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built
    Then building again fails as "release.invalid" saying "exists already"

  Scenario: A project that cannot be released is refused before anything is built
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    Then a project with each of these agentica.toml is refused:
      | agentica.toml                                                                  | kind            | message                 |
      | name = {Q}hello{Q}{NL}                                                         | release.invalid | set version             |
      | name = {Q}a/b{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}                    | release.invalid | name {Q}a/b{Q}          |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1 2{Q}{NL}                | release.invalid | version {Q}1 2{Q}       |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}entry = {Q}../m.agc{Q}{NL} | release.invalid | inside the project      |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}entry = {Q}main.txt{Q}{NL} | release.invalid | not an .agc file        |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}include = [{Q}nothing{Q}]{NL} | release.invalid | is not in the project   |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}agentica = {Q}9.9.9{Q}{NL} | release.invalid | asks for agentica 9.9.9 |
      | name = {Q}hello{Q}{NL}[tool.release]{NL}version = {Q}1{Q}{NL}[native.x]{NL}linux = { file = {Q}native/libx.so{Q} }{NL} | release.invalid | agentica#1753 |

  Scenario: A library found by name is listed for the target
    Given a fresh folder
    And a copy of the project "specs/fixtures/hello" in it
    When the release is built from this agentica.toml:
      """
      name = "hello"
      agentica = "0.37.0"

      [tool.release]
      version = "1.2.3"
      include = ["assets"]

      [native.m]
      linux = { system = "libm.so.6" }
      macos = { system = "libm.dylib" }
      windows = { system = "m.dll" }
      """
    Then the release lists the system library "libm.so.6" and "libm.dylib" and "m.dll"
