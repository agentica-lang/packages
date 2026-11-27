Feature: Nodes that share a cookie connect
  A node listens on a port that the system picks, and dials the nodes of its list. A node that proves the cookie is a
  peer; one that does not is refused. Every node of a scenario runs in one program on 127.0.0.1.

  Scenario: A node that dials another one is its peer, and so is the other
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    Then "alpha" has the peers "beta" within 5000 ms
    And "beta" has the peers "alpha" within 5000 ms

  Scenario: A node connects to another one when it is told to
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster"
    When "alpha" connects to the node "beta"
    Then "alpha" has the peers "beta" within 5000 ms
    And "beta" has the peers "alpha" within 5000 ms

  Scenario: Three nodes with static lists know each other
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    And the node "gamma" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha, beta"
    Then "alpha" has the peers "beta, gamma" within 5000 ms
    And "beta" has the peers "alpha, gamma" within 5000 ms
    And "gamma" has the peers "alpha, beta" within 5000 ms

  Scenario: A node dialed by its name is the one that answers
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha" by its name
    Then "beta" has the peers "alpha" within 5000 ms

  Scenario: A node with another cookie is not a peer
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "mallory" starts with the cookie "another-cookie-of-another-cluster"
    When "mallory" connects to the node "alpha" and it fails with "cluster.refused"
    Then "alpha" has the peers "" within 1000 ms
    And "mallory" has the peers "" within 1000 ms
    And "mallory" has refused 1 handshakes

  Scenario: A node that dials with a wrong cookie in its list does not become a peer
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "mallory" starts with the cookie "another-cookie-of-another-cluster" and dials "alpha"
    Then "mallory" has refused 1 handshakes
    And "alpha" has the peers "" within 500 ms

  Scenario: A node does not connect to itself
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    When "alpha" connects to the node "alpha" and it fails with "cluster.closed"
    Then "alpha" has the peers "" within 500 ms
    And "alpha" has refused 1 handshakes

  Scenario: A node dialed by a name that is not its own is refused
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster"
    When "alpha" connects to the node "beta" expecting the name "gamma" and it fails with "cluster.refused"
    Then "alpha" has the peers "" within 500 ms

  Scenario: Nothing listens at the address
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    When "alpha" connects to the address "127.0.0.1:1" and it fails with "cluster.unreachable"

  Scenario: Two nodes that connect to each other at the same moment keep one link
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster"
    When "alpha" and "beta" connect to each other at the same moment
    Then "alpha" has the peers "beta" within 5000 ms
    And "beta" has the peers "alpha" within 5000 ms
    And "alpha" still has the peers "beta" 500 ms later
    And "beta" still has the peers "alpha" 500 ms later

  Scenario: A peer that stops is forgotten
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster"
    When "alpha" connects to the node "beta"
    Then "alpha" has the peers "beta" within 5000 ms
    When the node "beta" stops
    Then "alpha" has the peers "" within 3000 ms

  Scenario: Dialing an address twice at the same moment makes one link
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster"
    When "alpha" connects to the node "beta" twice at the same moment
    Then "alpha" has the peers "beta" within 5000 ms
    And "beta" has the peers "alpha" within 5000 ms
    And "alpha" still has the peers "beta" 500 ms later
    And "beta" still has the peers "alpha" 500 ms later

  Scenario: A node that never answers is given up on when the deadline passes
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster" and a deadline of 1000 ms
    And a hole "hole" accepts connections and never answers
    Then "alpha" connects to the hole "hole" and it fails with "cluster.closed" within 2500 ms

  Scenario: Stopping a node ends the connections that it is dialing
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And a hole "hole" accepts connections and never answers
    When "alpha" starts connecting to the hole "hole"
    Then the node "alpha" stops within 1500 ms

  Scenario: A node closes the connections over its cap of handshakes at once
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster" and at most 2 handshakes at once
    Then 5 strangers connect to "alpha" and say nothing, and 3 of them are closed at once

  Scenario: A node does not listen on a public address with plain TCP
    Then starting the node "alpha" on the host "0.0.0.0" with the cookie "the-cookie-of-the-cluster" fails with "cluster.argument"

  Scenario: A node does not dial a public address with plain TCP
    Then starting the node "alpha" with the peer "10.255.255.1:4000" fails with "cluster.argument"

  Scenario: A node does not start with a short cookie
    Then starting the node "alpha" with the cookie "short" fails with "cluster.argument"

  Scenario: A node does not start with a name that is not valid
    Then starting the node "Alpha" with the cookie "the-cookie-of-the-cluster" fails with "cluster.argument"

  Scenario: A stranger that writes a web request is disconnected
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    Then a stranger writes "GET / HTTP/1.1" to "alpha" and is disconnected within 3000 ms
    And "alpha" has the peers "" within 500 ms

  Scenario: A stranger that sends a big frame before the handshake is disconnected
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    Then a stranger sends "alpha" a frame of 5000 bytes before the handshake and is disconnected
    And "alpha" has the peers "" within 500 ms

  Scenario: A stranger that sends a frame out of order is disconnected
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    Then a stranger sends "alpha" a ping before the handshake and is disconnected
    And "alpha" has the peers "" within 500 ms

  Scenario: A stranger that makes up a proof is disconnected and told nothing
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    Then a stranger answers "alpha" with a proof that it made up and is disconnected, with nothing said
    And "alpha" has the peers "" within 500 ms
    And "alpha" has refused 1 handshakes

  Scenario: A stranger that says nothing is disconnected when the deadline passes
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster" and a deadline of 300 ms
    Then a stranger says nothing to "alpha" and is disconnected within 3000 ms
