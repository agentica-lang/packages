Feature: Events of the peers
  A node tells those who watch it when a peer comes and when it goes. A link that is quiet is kept alive with pings,
  so a peer that is up is not told as down, and one that closes its socket is.

  Scenario: A peer that connects and then stops is told as up and then down
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster" and a heartbeat of 100 ms
    And "alpha" watches the peers coming and going
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    When "alpha" has the peers "beta" within 5000 ms
    And the node "beta" stops
    Then the events of "alpha" within 3000 ms:
      | node_up beta   |
      | node_down beta |

  Scenario: A link with no traffic stays up for longer than the time that a silent peer is given
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster" and a heartbeat of 200 ms
    And "alpha" watches the peers coming and going
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and a heartbeat of 200 ms
    When "beta" connects to the node "alpha"
    Then "alpha" has the peers "beta" within 5000 ms
    And "alpha" still has the peers "beta" 1500 ms later
    And the events of "alpha" within 500 ms:
      | node_up beta |

  Scenario: A heartbeat has a bound
    Then starting the node "alpha" with a heartbeat of 5 ms fails with "cluster.argument"
