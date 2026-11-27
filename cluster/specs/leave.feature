Feature: A node that leaves
  A node that leaves tells its peers, which drop it as left and not as down, and do not dial it again. A node that only
  stops is down, and the peers of its list dial it until it answers.

  Scenario: A peer that leaves is told as left, not as down
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster" and a heartbeat of 100 ms
    And "alpha" watches the peers coming and going
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    And "alpha" has the peers "beta" within 5000 ms
    When the node "beta" leaves
    Then the events of "alpha" within 3000 ms:
      | node_up beta   |
      | node_left beta |
    And "alpha" has the peers "" within 3000 ms

  Scenario: A node that leaves hears no event of its own
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    And "beta" watches the peers coming and going
    And "beta" has the peers "alpha" within 5000 ms
    When the node "beta" leaves
    Then "alpha" has the peers "" within 3000 ms
    And the events of "beta" within 500 ms:
      | node_up alpha |

  Scenario: A peer of the list that left is not dialed again
    Given the node "beta" starts with the cookie "the-cookie-of-the-cluster"
    And the node "alpha" starts with the cookie "the-cookie-of-the-cluster", dials "beta" and retries every 100 ms
    And "alpha" has the peers "beta" within 5000 ms
    When the node "beta" leaves
    And "alpha" has the peers "" within 3000 ms
    And the node "beta" starts again on the port of its first run with the cookie "the-cookie-of-the-cluster"
    Then "alpha" has the peers "" within 500 ms
    And "alpha" still has the peers "" 1500 ms later

  Scenario: A node with no peers leaves
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    Then the node "alpha" leaves
