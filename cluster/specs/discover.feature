Feature: Finding the nodes of a cluster by a name
  A node that is given a name looks it up, with every address that it has, and dials the addresses that answer. It does
  so again and again, so that a node that was down when the name was first looked up is found when it is up.

  Scenario: A node finds another one by the name of its host
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and finds nodes at "localhost", port of "alpha", each 200 ms
    Then "beta" has the peers "alpha" within 5000 ms
    And "alpha" has the peers "beta" within 5000 ms

  Scenario: A node that is linked is not dialed again in the 10 lookups of a second
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and finds nodes at "localhost", port of "alpha", each 100 ms
    And "beta" has the peers "alpha" within 5000 ms
    Then "beta" still has the peers "alpha" 1000 ms later
    And "alpha" has refused 0 handshakes

  Scenario: A name that no machine has finds nobody, and the node goes on
    Given the node "beta" starts with the cookie "the-cookie-of-the-cluster" and finds the name "nothing.invalid:7000" on a trusted network, each 100 ms
    Then "beta" still has the peers "" 400 ms later
    And the node "beta" stops within 2000 ms

  Scenario: A node that was down is found when it comes back
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and finds nodes at "localhost", port of "alpha", each 200 ms
    And "beta" has the peers "alpha" within 5000 ms
    When the node "alpha" stops
    And the node "alpha" starts again on the port of its first run with the cookie "the-cookie-of-the-cluster"
    Then "beta" has the peers "alpha" within 5000 ms

  Scenario: The name needs a port
    Then starting the node "beta" that finds the nodes at "localhost" fails with "cluster.argument"

  Scenario: A name that is not this machine needs the node to trust the network
    Then starting the node "beta" that finds the nodes at "cluster.example.com:7000" fails with "cluster.argument"
