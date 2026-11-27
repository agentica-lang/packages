Feature: The frames that nodes write and read
  A node says a ping, a pong, a goodbye with a reason, or a mail for a mailbox of the other node. Each is one frame.
  The reader checks the length before it reads the body, and it refuses what is not a frame without ever stopping.

  Scenario Outline: A message is read back as it was written
    Given a node writes the message "<message>"
    Then another node reads "<message>"

    Examples:
      | message             |
      | ping                |
      | pong                |
      | bye done            |
      | bye                 |
      | mail jobs hello     |
      | mail jobs           |
      | mail a-b_c.d 1 2 3  |

  Scenario Outline: A greeting that is not from a node is refused
    When a node reads the greeting "<greeting>"
    Then it is refused as "cluster.protocol"

    Examples:
      | greeting                |
      | GET / HTTP/1.1          |
      | AGCN                    |
      |                         |
      | AGCN2 and more bytes    |

  Scenario: The greeting of a node is accepted
    When a node reads the greeting that a node writes
    Then it is accepted

  Scenario Outline: A frame that says too many bytes is refused before its body is read
    When a frame says it has <bytes> bytes and the limit is <limit>
    Then it is refused as "<kind>"

    Examples:
      | bytes      | limit   | kind              |
      | 1001       | 1000    | cluster.too_large |
      | 4294967295 | 1000    | cluster.too_large |
      | 0          | 1000    | cluster.protocol  |

  Scenario: A frame that says exactly the limit is accepted
    When a frame says it has 1000 bytes and the limit is 1000
    Then it is accepted

  Scenario: A message that would not fit the limit is not written
    When a node writes a mail of 2000 bytes for the mailbox "jobs" with a limit of 1000
    Then it is refused as "cluster.too_large"

  Scenario Outline: A mailbox has a name of one to 255 bytes
    When a node writes a mail for a mailbox of <size> bytes
    Then it is <outcome>

    Examples:
      | size | outcome                             |
      | 0    | refused as "cluster.protocol"       |
      | 1    | accepted                            |
      | 255  | accepted                            |
      | 256  | refused as "cluster.protocol"       |

  Scenario: A frame that lost its end is refused
    Given a node writes the message "mail jobs hello"
    When the frame loses its last 1 bytes
    Then another node refuses it as "cluster.protocol"

  Scenario: A frame that got more bytes is refused
    Given a node writes the message "mail jobs hello"
    When the frame gets 1 more bytes
    Then another node refuses it as "cluster.protocol"

  Scenario: A frame that is cut inside its length is refused
    Given a node writes the message "ping"
    When the frame is cut to its first 3 bytes
    Then another node refuses it as "cluster.protocol"

  Scenario Outline: A frame of a kind that is not known
    When a node reads a frame of the kind <kind>
    Then it is <outcome>

    Examples:
      | kind | outcome                       |
      | 64   | ignored                       |
      | 127  | ignored                       |
      | 63   | refused as "cluster.protocol" |
      | 128  | refused as "cluster.protocol" |
      | 255  | refused as "cluster.protocol" |
