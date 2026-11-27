Feature: Groups of mailboxes
  A mailbox of a node can join a group, and every node that is connected to it sees the members of the group, its own
  and the ones of its peers. A node that connects later is told too, and the memberships of a peer end with its link.

  Scenario: The nodes see each other's members
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    And "alpha" has the peers "beta" within 5000 ms
    And "alpha" has the mailbox "jobs"
    And "beta" has the mailbox "jobs"
    And "beta" has the mailbox "audit"
    When "alpha" joins the group "workers" with the mailbox "jobs"
    And "beta" joins the group "workers" with the mailbox "jobs"
    And "beta" joins the group "auditors" with the mailbox "audit"
    Then the members of the group "workers" on "alpha" are "alpha/jobs, beta/jobs" within 3000 ms
    And the members of the group "workers" on "beta" are "alpha/jobs, beta/jobs" within 3000 ms
    And the members of the group "auditors" on "alpha" are "beta/audit" within 3000 ms
    And the members of the group "nobody" on "alpha" are "" within 100 ms

  Scenario: A node that connects later is told the members
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And "alpha" has the mailbox "jobs"
    And "alpha" joins the group "workers" with the mailbox "jobs"
    When the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    Then the members of the group "workers" on "beta" are "alpha/jobs" within 5000 ms

  Scenario: A member that leaves is gone for the peers
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    And "alpha" has the mailbox "jobs"
    And "alpha" joins the group "workers" with the mailbox "jobs"
    And the members of the group "workers" on "beta" are "alpha/jobs" within 5000 ms
    When "alpha" leaves the group "workers" with the mailbox "jobs"
    Then the members of the group "workers" on "beta" are "" within 3000 ms
    And the members of the group "workers" on "alpha" are "" within 3000 ms

  Scenario: The members of a node that goes down are gone
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    And "alpha" has the mailbox "jobs"
    And "alpha" joins the group "workers" with the mailbox "jobs"
    And the members of the group "workers" on "beta" are "alpha/jobs" within 5000 ms
    When the node "alpha" stops
    Then the members of the group "workers" on "beta" are "" within 3000 ms

  Scenario: A node that comes back with the same name says its new members
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    And "beta" has the mailbox "jobs"
    And "beta" joins the group "workers" with the mailbox "jobs"
    And the members of the group "workers" on "alpha" are "beta/jobs" within 5000 ms
    When the node "beta" stops
    And the members of the group "workers" on "alpha" are "" within 3000 ms
    And the node "beta" starts again on the port of its first run with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    And "beta" has the mailbox "audit"
    And "beta" joins the group "auditors" with the mailbox "audit"
    Then the members of the group "auditors" on "alpha" are "beta/audit" within 5000 ms
    And the members of the group "workers" on "alpha" are "" within 100 ms

  Scenario: A mailbox that is not registered cannot join
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    Then "alpha" joins the group "workers" with the mailbox "nowhere" and it fails with "cluster.argument"
