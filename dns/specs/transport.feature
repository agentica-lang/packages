Feature: Asking nameservers over TCP and TLS
  The resolver sends each query over a stream, with the 2-byte length in front (RFC 7766), and over TLS for DoT (RFC 7858).
  The peer is `fixtures/dns_tcp_peer.agc`, a program that does not use the codec of the package: it answers with the
  hex bytes of a script (`ID`, `OTHERID` and `QUESTION` stand for parts of the query that it read), so a scenario can
  send what no real server sends. It listens on 127.0.0.1 and a free port; `CLOSED` in a table is a port that nobody
  listens at. The script words: a header is the id, the flags (8180 is a response with recursion), then the counts of
  questions, answers, authorities and additionals. An A record of `example.com` with a pointer to the question is
  `c00c 0001 0001 0000012c 0004 c0000201`: 192.0.2.1 with a TTL of 300.

  Scenario: An A query over TCP is sent with its length and the answer is read
    Given the peer listens with the script "read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"
    And the peer saw "query ID01000001000000000000076578616d706c6503636f6d0000010001"

  Scenario: A lookup asks for the IPv4 and the IPv6 addresses and gives the IPv4 ones first
    Given the peer listens with the script "read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201 / accept / read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 001c 0001 0000003c 0010 20010db8000000000000000000000001"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver looks up "example.com"
    Then it gives "192.0.2.1,2001:db8::1"

  Scenario: A name that exists with no address is an error of its own
    Given the peer listens with the script "read / send ID 8180 0001 0000 0000 0000 QUESTION / accept / read / send ID 8180 0001 0000 0000 0000 QUESTION"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver looks up "example.com"
    Then it fails with "dns.no_address"

  Scenario: The query goes over TLS to a server with the certificate of a test CA
    Given the TLS peer listens with the script "read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name     |
      | tls  | PORT | dns.test |
    And the client trusts the CA of the specs
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"
    And the peer saw "query ID01000001000000000000076578616d706c6503636f6d0000010001"

  Scenario: With no name the certificate is checked for the host, here an IP address that the certificate has
    Given the TLS peer listens with the script "read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name |
      | tls  | PORT |      |
    And the client trusts the CA of the specs
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"

  Scenario Outline: A TLS server is refused when its certificate does not fit
    Given the TLS peer listens with the script "read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name   |
      | tls  | PORT | <name> |
    And the client trusts the CA of the specs
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "dns.network"

    Examples:
      | name       |
      | other.test |
      | localhost  |

  Scenario: A server that is not trusted by the system is refused
    Given the TLS peer listens with the script "read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name     |
      | tls  | PORT | dns.test |
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "dns.network"

  Scenario: The 2-byte length may come in two writes
    Given the peer listens with the script "read / split 1 150 ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"

  Scenario: An answer that comes one byte at a time is read
    Given the peer listens with the script "read / drip 3 ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"

  Scenario Outline: An answer that is not good is an error of its kind
    Given the peer listens with the script "<script>"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "<kind>"

    Examples:
      | script                                                                                       | kind          |
      | read / raw 0040 ID                                                                           | dns.network   |
      | read / raw 0000                                                                              | dns.malformed |
      | read / raw 0005 ID 8180 00                                                                   | dns.malformed |
      | read / send OTHERID 8180 0001 0000 0000 0000 QUESTION                                        | dns.mismatch  |
      | read / send ID 0180 0001 0000 0000 0000 QUESTION                                             | dns.mismatch  |
      | read / send ID 8180 0001 0000 0000 0000 056f7468657204746573740000010001                     | dns.mismatch  |
      | read / send ID 8380 0001 0000 0000 0000 QUESTION                                             | dns.truncated |
      | read / send ID 8182 0001 0000 0000 0000 QUESTION                                             | dns.servfail  |
      | read / send ID 8185 0001 0000 0000 0000 QUESTION                                             | dns.refused   |
      | read / send ID 8183 0001 0000 0000 0000 QUESTION                                             | dns.nxdomain  |
      | read / send ID 8184 0001 0000 0000 0000 QUESTION                                             | dns.servfail  |
      | read / send ID 8182 0000 0000 0000 0000                                                      | dns.servfail  |

  Scenario: A server that fails is followed by the next one
    Given the peer listens with the script "read / send ID 8182 0001 0000 0000 0000 QUESTION / accept / read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"

  Scenario: A server that nobody listens at is followed by the next one
    Given the peer listens with the script "read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port   | name |
      | tcp  | CLOSED |      |
      | tcp  | PORT   |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"

  Scenario: A name that does not exist ends the search
    Given the peer listens with the script "read / send ID 8183 0001 0000 0000 0000 QUESTION"
    And the nameservers are:
      | kind | port   | name |
      | tcp  | PORT   |      |
      | tcp  | CLOSED |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "dns.nxdomain"

  Scenario: When every server fails the error of the last one is the result
    Given the peer listens with the script "read / send ID 8182 0001 0000 0000 0000 QUESTION / accept / read / send ID 8185 0001 0000 0000 0000 QUESTION"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "dns.refused"

  Scenario: A server that never answers is left after its own timeout
    Given the peer listens with the script "read / sleep 1500"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    And each nameserver has 300 milliseconds
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "dns.timeout"
    And it took less than 1200 milliseconds

  Scenario: A CNAME in the answer is followed, and the TTL is the smallest of the chain
    Given the peer listens with the script "read / send ID 8180 0001 0002 0000 0000 QUESTION c00c 0005 0001 0000003c 0013 05616c696173076578616d706c65036e657400 c029 0001 0001 0000012c 0004 c0000202"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.2/60"

  Scenario: A CNAME that leaves the answer is asked again
    Given the peer listens with the script "read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0005 0001 0000003c 0013 05616c696173076578616d706c65036e657400 / accept / read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000203"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.3/60"
    And the peer saw "query ID01000001000000000000076578616d706c6503636f6d0000010001"
    And the peer saw "query ID0100000100000000000005616c696173076578616d706c65036e65740000010001"

  Scenario: A loop of CNAMEs is cut by the limit
    Given the peer listens with the script "read / send ID 8180 0001 0002 0000 0000 QUESTION c00c 0005 0001 0000003c 0008 016204746573 7400 c029 0005 0001 0000003c 0002 c00c"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "dns.cname_limit"

  Scenario: A record of another owner is not an address of the name
    Given the peer listens with the script "read / send ID 8180 0001 0001 0000 0000 QUESTION 056f746865720474657374 00 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives ""

  Scenario: A record that is not of the class IN is not an address
    Given the peer listens with the script "read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0003 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives ""

  Scenario: A CNAME that is not of the class IN is not followed
    Given the peer listens with the script "read / send ID 8180 0001 0002 0000 0000 QUESTION c00c 0005 0003 0000003c 0013 05616c696173076578616d706c65036e657400 c029 0001 0001 0000012c 0004 c0000202"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives ""

  Scenario: An answer to another type of question is not an answer
    Given the peer listens with the script "read / send ID 8180 0001 0000 0000 0000 076578616d706c6503636f6d00 001c0001"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "dns.mismatch"

  Scenario: A name error with no question does not end the search
    Given the peer listens with the script "read / send ID 8183 0000 0000 0000 0000 / accept / read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
      | tcp  | PORT |      |
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"

  Scenario: A server that times out is followed by the next one, which may be the same peer in its backlog
    Given the peer listens with the script "read / sleep 700 / accept / read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
      | tcp  | PORT |      |
    And each nameserver has 500 milliseconds
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"

  Scenario: A lookup that has no address reports the kind that failed, not that there is none
    Given the peer listens with the script "read / send ID 8180 0001 0000 0000 0000 QUESTION / accept / read / send ID 8182 0001 0000 0000 0000 QUESTION"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver looks up "example.com"
    Then it fails with "dns.servfail"

  Scenario: A lookup of a name that does not exist asks only for the IPv4 addresses
    Given the peer listens with the script "read / send ID 8183 0001 0000 0000 0000 QUESTION / accept / read / send ID 8180 0001 0001 0000 0000 QUESTION c00c 001c 0001 0000003c 0010 20010db8000000000000000000000001"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    When the resolver looks up "example.com"
    Then it fails with "dns.nxdomain"

  Scenario Outline: A chain of two CNAMEs is followed only when the limit allows it
    Given the peer listens with the script "read / send ID 8180 0001 0003 0000 0000 QUESTION c00c 0005 0001 0000003c 0008 0162 0474657374 00 c029 0005 0001 0000003c 0008 0163 0474657374 00 c03d 0001 0001 0000012c 0004 c0000204"
    And the nameservers are:
      | kind | port | name |
      | tcp  | PORT |      |
    And the resolver allows <limit> CNAMEs
    When the resolver asks for the "A" addresses of "example.com"
    Then <outcome>

    Examples:
      | limit | outcome                       |
      | 2     | it gives "192.0.2.4/60"       |
      | 1     | it fails with "dns.cname_limit" |
      | 0     | it fails with "dns.cname_limit" |
