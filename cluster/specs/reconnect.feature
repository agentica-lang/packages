Feature: Peers of the list that go away and come back
  A node dials the peers of its list again, with a wait that grows, when a dial fails or a link ends. So a node that
  starts before its peers, or a peer that is killed and started again, joins the cluster with no help.

  Scenario: A peer that is down when the node starts is dialed until it answers
    Given the node "beta" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" stops
    And the node "alpha" starts with the cookie "the-cookie-of-the-cluster", dials "beta" and retries every 100 ms
    And "alpha" watches the peers coming and going
    When the node "beta" starts again on the port of its first run with the cookie "the-cookie-of-the-cluster"
    Then "alpha" has the peers "beta" within 5000 ms
    And the events of "alpha" within 3000 ms:
      | node_up beta |

  Scenario: A peer that is killed and started again is told as down and then up
    Given the node "beta" starts with the cookie "the-cookie-of-the-cluster"
    And the node "alpha" starts with the cookie "the-cookie-of-the-cluster", dials "beta" and retries every 100 ms
    And "alpha" has the peers "beta" within 5000 ms
    And "alpha" watches the peers coming and going
    When the node "beta" stops
    And the node "beta" starts again on the port of its first run with the cookie "the-cookie-of-the-cluster"
    Then "alpha" has the peers "beta" within 5000 ms
    And the events of "alpha" within 3000 ms:
      | node_down beta |
      | node_up beta   |

  Scenario: A wait before a new dial needs a time
    Then starting the node "alpha" that retries every 0 ms fails with "cluster.argument"
