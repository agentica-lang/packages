Feature: The codec of RFC 1035 against an independent peer
  `specs/fixtures/dns_peer.py` has its own encoder and decoder, written with the standard library only. It writes random
  messages with compressed names (pointers that chain, labels with dots, backslashes and any byte, every type of
  record and any class), and the codec must read each one as the peer says. It also damages those messages (cut, a
  byte changed, a pointer put in, bytes added), and the codec must accept and refuse the same ones, with the same
  text for the ones it accepts. The queries of the codec are read by the peer.

  Scenario Outline: The codec reads what the peer writes
    Given the peer writes 100 random messages from the seed <seed>
    Then the codec reads every one as the peer says

    Examples:
      | seed |
      | 11   |
      | 12   |
      | 13   |
      | 14   |

  Scenario Outline: The codec and the peer accept and refuse the same damaged messages
    Given the peer writes 100 damaged messages from the seed <seed>
    Then the codec reads every one as the peer does

    Examples:
      | seed |
      | 21   |
      | 22   |
      | 23   |
      | 24   |
      | 25   |
      | 26   |

  Scenario Outline: The peer reads the query of the codec
    When the codec writes a query with the id <id> for "<name>" of the type <type>
    Then the peer reads it as "<text>"

    Examples:
      | id    | name            | type  | text                                                                                       |
      | 4242  | example.com     | 1     | id=4242 qr=0 op=0 aa=0 tc=0 rd=1 ra=0 rcode=0 ; Q example.com 1 1                         |
      | 0     | example.com.    | 28    | id=0 qr=0 op=0 aa=0 tc=0 rd=1 ra=0 rcode=0 ; Q example.com 28 1                           |
      | 65535 | Mixed.CASE.test | 5     | id=65535 qr=0 op=0 aa=0 tc=0 rd=1 ra=0 rcode=0 ; Q Mixed.CASE.test 5 1                    |
      | 7     | a\\.b.example    | 1     | id=7 qr=0 op=0 aa=0 tc=0 rd=1 ra=0 rcode=0 ; Q a\\.b.example 1 1                           |
      | 7     | a\\032b\\\\.c      | 16    | id=7 qr=0 op=0 aa=0 tc=0 rd=1 ra=0 rcode=0 ; Q a\\032b\\\\.c 16 1                            |
      | 9     |                 | 2     | id=9 qr=0 op=0 aa=0 tc=0 rd=1 ra=0 rcode=0 ; Q  2 1                                       |

  Scenario Outline: A name or a query that breaks the limits is refused before it is written
    When the codec writes a query with the id <id> for "<name>" of the type <type>
    Then writing fails with "dns.malformed"

    Examples:
      | id    | name         | type  |
      | 1     | a..b         | 1     |
      | 65536 | example.com  | 1     |
      | -1    | example.com  | 1     |
      | 1     | example.com  | 0     |
      | 1     | example.com  | 65536 |
      