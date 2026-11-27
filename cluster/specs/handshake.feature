Feature: Two nodes that share a cookie shake hands
  The cookie is never sent. Each node proves that it knows it, and a node that does not know it cannot join, even with
  what it saw on the wire of an earlier connection.

  Scenario: Two nodes with the same cookie accept each other
    Given the node "alpha" and the node "beta" have the cookie "the-cookie-of-the-cluster"
    When "alpha" connects to "beta"
    Then "alpha" accepts "beta"
    And "beta" accepts "alpha"

  Scenario: A node with another cookie is not accepted by the one that connects to it
    Given the node "alpha" has the cookie "the-cookie-of-the-cluster"
    And the node "beta" has the cookie "another-cookie-of-the-cluster"
    When "alpha" connects to "beta"
    Then "alpha" refuses "beta"

  Scenario: A node with another cookie is not accepted by the one that it connects to
    Given the node "alpha" has the cookie "the-cookie-of-the-cluster"
    And the node "beta" has the cookie "another-cookie-of-the-cluster"
    When "beta" answers "alpha" without checking its proof
    Then "alpha" refuses "beta"

  Scenario: What a node saw on an earlier connection does not let another one in
    Given the node "alpha" and the node "beta" have the cookie "the-cookie-of-the-cluster"
    And "alpha" connected to "beta" earlier
    When a stranger connects to "beta" and sends the answer of that earlier connection
    Then "beta" refuses the stranger

  Scenario: A node that answers under another name is refused
    Given the node "alpha" and the node "beta" have the cookie "the-cookie-of-the-cluster"
    And the node "gamma" has the cookie "the-cookie-of-the-cluster"
    When "alpha" dials "beta" and "gamma" answers
    Then "alpha" refuses "beta"

  Scenario: The proof of a node cannot be sent back to it
    Given the node "alpha" and the node "beta" have the cookie "the-cookie-of-the-cluster"
    When a stranger connects to "beta" and sends back the proof that "beta" made
    Then "beta" refuses the stranger

  Scenario: A stranger that guesses an answer is refused
    Given the node "alpha" and the node "beta" have the cookie "the-cookie-of-the-cluster"
    When a stranger connects to "beta" and sends a proof of its own
    Then "beta" refuses the stranger

  Scenario Outline: A cookie needs 16 bytes
    When a node is given the cookie "<cookie>"
    Then the cookie is <outcome>

    Examples:
      | cookie                            | outcome  |
      | short                             | refused  |
      | 123456789012345                   | refused  |
      | 1234567890123456                  | accepted |
      | a-long-cookie-of-32-bytes-or-more | accepted |

  Scenario Outline: A node cannot connect to a node with its own name or with a bad name
    When the node "<client>" connects to the node "<server>"
    Then the connection is refused

    Examples:
      | client | server |
      | alpha  | alpha  |
      | Alpha  | beta   |
      | alpha  | b e    |
      | 1alpha | beta   |
