Feature: The yaml-test-suite
  `fixtures/yaml-test-suite` is a copy of the cases of the official yaml-test-suite that are in the scope of this
  package (its README says which are left out and why). Each valid text must parse to the JSON of the suite, and each
  invalid one must fail. `fixtures/suite.agc` runs them all and prints the counts.

  Scenario: Every case of the copy passes
    Given the program argument "fixtures/yaml-test-suite"
    And the Agentica program "fixtures/suite.agc"
    Then the program exits with code 0 within 60000 milliseconds
    And stdout is:
      """
      yaml-test-suite: 357 passed, 0 failed

      """
