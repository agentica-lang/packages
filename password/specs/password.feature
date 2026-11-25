Feature: Hashing and checking passwords
  `Password.hash` makes a digest `scrypt$N$r$p$salt$key` that carries its cost, and `Password.verify` checks a password
  against it. The digests of fixtures/golden.json are made by fixtures/scrypt_peer.py, a Python scrypt that shares
  nothing with the package, so a digest is the same on both sides.

  Scenario: A digest verifies the password that made it, and no other, and does not hold the password
    When I hash "correct horse battery"
    Then the digest starts with "scrypt$65536$8$2$"
    And the digest does not contain "correct horse"
    And the password "correct horse battery" verifies against the digest
    And the password "correct horse batterz" does not verify against the digest

  Scenario: Each digest has its own salt
    When I hash "same password" twice
    Then the two digests differ
    And both verify "same password"

  Scenario Outline: A digest that another implementation made verifies, whatever its cost, and a wrong password does not
    Given the golden digest "<vector>"
    Then its password verifies against it
    And "not the password" does not verify against it

    Examples:
      | vector                     |
      | default cost               |
      | a lower cost               |
      | other block size and lanes |
      | a longer key               |
      | not ASCII                  |

  Scenario Outline: The peer reads the digest of the package as the package does
    When I hash "<password>"
    Then the peer says the digest matches "<password>"
    And the peer says the digest does not match "<other>"

    Examples:
      | password                  | other                    |
      | correct horse battery     | correct horse batterz    |
      | contraseña ñandú 日本     | contraseña ñandú 日本!   |

  Scenario Outline: A digest that is not one of the package, or that asks for too much, is an error and not a verdict
    Then verifying against the digest "<digest>" is an error

    Examples:
      | digest                                                                                                                                                 |
      |                                                                                                                                                        |
      | plain                                                                                                                                                  |
      | $2a$12$abcdefghijklmnopqrstuuabcdefghijklmnopqrstuvwxyz01234                                                                                           |
      | bcrypt$65536$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                 |
      | scrypt$65536$8$2$AAAAAAAAAAAAAAAAAAAAAA==                                                                                                              |
      | scrypt$65536$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=$x                                                               |
      | scrypt$x$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                     |
      | scrypt$+65536$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                |
      | scrypt$065536$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                |
      | scrypt$3$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                     |
      | scrypt$512$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                   |
      | scrypt$1000$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                  |
      | scrypt$65536$0$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                 |
      | scrypt$65536$+8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                |
      | scrypt$65536$08$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                |
      | scrypt$65536$33$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                |
      | scrypt$65536$8$17$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                |
      | scrypt$1048576$8$1$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                               |
      | scrypt$4294967296$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                            |
      | scrypt$9223372036854775807$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                   |
      | scrypt$65536$8$2$not base64$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                               |
      | scrypt$65536$8$2$$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                                         |
      | scrypt$65536$8$2$AAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                                                                             |
      | scrypt$65536$8$2$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= |
      | scrypt$65536$8$2$AAAAAAAAAAAAAAAAAAAAAA==$!!                                                                                                           |
      | scrypt$65536$8$2$AAAAAAAAAAAAAAAAAAAAAA==$                                                                                                             |
      | scrypt$65536$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AA==                                                                                                         |
      | scrypt$65536$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAA                                                                                         |
      | scrypt$65536$8$2$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=                     |


  Scenario Outline: A new password needs 8 characters and at most 256 bytes
    When I ask what is wrong with <count> copies of "<text>"
    Then the answer <outcome>

    Examples:
      | count | text | outcome                    |
      | 7     | x    | mentions "at least 8"      |
      | 7     | é    | mentions "at least 8"      |
      | 8     | x    | is empty                   |
      | 256   | x    | is empty                   |
      | 257   | x    | mentions "at most 256"     |
      | 128   | é    | is empty                   |
      | 129   | é    | mentions "at most 256"     |

  Scenario: A password of more than 256 bytes is not hashed, and verifies nothing
    Then hashing 257 copies of "x" is an error
    And verifying 257 copies of "x" against the digest "scrypt$131072$8$16$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" is false in under 100 milliseconds

  Scenario: Checking against nobody costs about the work of a hash
    When I time a hash and a check against nobody
    Then the check against nobody took at least half of the time of the hash
