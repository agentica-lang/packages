Feature: The yaml-test-suite
  The cases of the official yaml-test-suite, fetched by `fetch-suite.sh` (`make install PACKAGES=yaml`) at a pinned
  commit. Each valid text in the scope of the package must parse to the JSON of the suite, and each invalid one must
  fail. `fixtures/suite.agc` runs them and prints the counts; the cases it leaves out are in `fixtures/README.md`.

  Scenario: Every case in scope passes
    Given the program argument "../.cache/yaml-test-suite-6ad3d2c62885d82fc349026c136ef560838fdf3d"
    And the Agentica program "fixtures/suite.agc"
    Then I receive the line "yaml-test-suite: 357 passed, 0 failed" within 60000 milliseconds
    And the program exits with code 0 within 5000 milliseconds
