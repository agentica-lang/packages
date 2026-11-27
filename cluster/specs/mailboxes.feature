Feature: Messages to the mailboxes of other nodes
  A node registers a name for a mailbox, and a peer sends bytes to that name. The bytes are what Term.encode wrote, and
  the node that receives them decodes them into its own type, so a message that does not fit is an error for that
  message and nothing else.

  Background:
    Given the node "alpha" starts with the cookie "the-cookie-of-the-cluster"
    And the node "beta" starts with the cookie "the-cookie-of-the-cluster" and dials "alpha"
    And "alpha" has the peers "beta" within 5000 ms
    And "beta" has the peers "alpha" within 5000 ms

  Scenario: A job sent to a mailbox arrives, decoded into the type of the receiver
    Given "beta" has the mailbox "jobs"
    When "alpha" sends "beta" the job 7 named "compile" in the mailbox "jobs"
    Then the mailbox "jobs" of "beta" has received within 3000 ms:
      | job 7 compile from alpha |

  Scenario: The other node can send back
    Given "alpha" has the mailbox "replies"
    When "beta" sends "alpha" the job 1 named "done" in the mailbox "replies"
    Then the mailbox "replies" of "alpha" has received within 3000 ms:
      | job 1 done from beta |

  Scenario: Messages from one task to one mailbox arrive in the order they were sent
    Given "beta" has the mailbox "jobs"
    When "alpha" sends "beta" 100 jobs in the mailbox "jobs"
    Then the mailbox "jobs" of "beta" has received 100 jobs in order within 5000 ms

  Scenario: A message that does not fit the type is an error for that message only
    Given "beta" has the mailbox "jobs"
    When "alpha" sends "beta" the bytes "not cbor at all" in the mailbox "jobs"
    And "alpha" sends "beta" a message of another type in the mailbox "jobs"
    And "alpha" sends "beta" the job 8 named "link" in the mailbox "jobs"
    Then the mailbox "jobs" of "beta" has received within 3000 ms:
      | unreadable        |
      | unreadable        |
      | job 8 link from alpha |
    And "alpha" has the peers "beta" within 500 ms

  Scenario: A message for a mailbox that does not exist is dropped and counted
    Given "beta" has the mailbox "jobs"
    When "alpha" sends "beta" the job 1 named "lost" in the mailbox "nobody"
    And "alpha" sends "beta" the job 2 named "kept" in the mailbox "jobs"
    Then "beta" has dropped 1 messages within 3000 ms
    And the mailbox "jobs" of "beta" has received within 3000 ms:
      | job 2 kept from alpha |

  Scenario: A mailbox that is registered again takes the next messages
    Given "beta" has the mailbox "jobs"
    And "beta" has the mailbox "jobs" again
    When "alpha" sends "beta" the job 3 named "again" in the mailbox "jobs"
    Then the mailbox "jobs" of "beta" has received within 3000 ms:
      | job 3 again from alpha |

  Scenario: A message to a node that is not a peer fails
    When "alpha" sends "gamma" the job 1 named "nowhere" in the mailbox "jobs" and it fails with "cluster.not_connected"

  Scenario: A message over the limit of the frame is not sent
    Given "beta" has the mailbox "jobs"
    When "alpha" sends "beta" a message of 2000000 bytes in the mailbox "jobs" and it fails with "cluster.too_large"
    Then "alpha" has the peers "beta" within 500 ms

  Scenario: A mailbox needs a name
    Then "beta" cannot have the mailbox "" and it fails with "cluster.argument"
