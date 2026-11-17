Feature: Asking nameservers over HTTPS
  The resolver sends each query as the body of a POST of the type `application/dns-message` (RFC 8484), with the id 0.
  The peer is `fixtures/doh_peer.agc`, an HTTPS server of `std/http` with the certificate of the test CA, that does not
  use the codec of the package. Its script has one line for each path: `PATH STATUS TYPE DELAY HEX`, with the same
  words as in `transport.feature` (`ID`, `QUESTION`). A server in the table is `https | PORT | /path`.

  Scenario: A query is a POST of a DNS message and the answer is the body of a 200
    Given the HTTPS peer listens with the script "/ok 200 application/dns-message 0 ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind  | port | name |
      | https | PORT | /ok  |
    And the client trusts the CA of the specs
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"
    And the peer saw "request POST /ok type=application/dns-message accept=application/dns-message id=0 ID01000001000000000000076578616d706c6503636f6d0000010001"

  Scenario: The media type may have parameters and any case
    Given the HTTPS peer listens with the script "/ok 200 Application/DNS-Message;charset=x 0 ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind  | port | name |
      | https | PORT | /ok  |
    And the client trusts the CA of the specs
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"

  Scenario Outline: An answer that is not good is an error of its kind
    Given the HTTPS peer listens with the script "/bad <status> <type> 0 <words>"
    And the nameservers are:
      | kind  | port | name |
      | https | PORT | /bad |
    And the client trusts the CA of the specs
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "<kind>"

    Examples:
      | status | type                    | words                                           | kind          |
      | 503    | application/dns-message | ID 8182 0001 0000 0000 0000 QUESTION            | dns.network   |
      | 404    | text/html               | 3c68746d6c3e                                    | dns.network   |
      | 200    | text/html               | ID 8180 0001 0000 0000 0000 QUESTION            | dns.malformed |
      | 200    | -                       | ID 8180 0001 0000 0000 0000 QUESTION            | dns.malformed |
      | 200    | application/dns-messageXYZ | ID 8180 0001 0000 0000 0000 QUESTION         | dns.malformed |
      | 200    | application/dns-message | 00                                              | dns.malformed |
      | 200    | application/dns-message | OTHERID 8180 0001 0000 0000 0000 QUESTION       | dns.mismatch  |
      | 200    | application/dns-message | ID 8380 0001 0000 0000 0000 QUESTION            | dns.truncated |
      | 200    | application/dns-message | ID 8182 0001 0000 0000 0000 QUESTION            | dns.servfail  |
      | 200    | application/dns-message | ID 8185 0001 0000 0000 0000 QUESTION            | dns.refused   |
      | 200    | application/dns-message | ID 8183 0001 0000 0000 0000 QUESTION            | dns.nxdomain  |

  Scenario: A path that the server does not know is an error
    Given the HTTPS peer listens with the script "/ok 200 application/dns-message 0 ID 8180 0001 0000 0000 0000 QUESTION"
    And the nameservers are:
      | kind  | port | name     |
      | https | PORT | /missing |
    And the client trusts the CA of the specs
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "dns.network"

  Scenario: A server that fails is followed by the next one, whatever its transport
    Given the HTTPS peer listens with the script "/down 503 text/plain 0 6f6f7073 / /ok 200 application/dns-message 0 ID 8180 0001 0001 0000 0000 QUESTION c00c 0001 0001 0000012c 0004 c0000201"
    And the nameservers are:
      | kind  | port   | name  |
      | tcp   | CLOSED |       |
      | https | PORT   | /down |
      | https | PORT   | /ok   |
    And the client trusts the CA of the specs
    When the resolver asks for the "A" addresses of "example.com"
    Then it gives "192.0.2.1/300"

  Scenario: A server that never answers is left after its own timeout
    Given the HTTPS peer listens with the script "/slow 200 application/dns-message 1500 ID 8180 0001 0000 0000 0000 QUESTION"
    And the nameservers are:
      | kind  | port | name  |
      | https | PORT | /slow |
    And the client trusts the CA of the specs
    And each nameserver has 300 milliseconds
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "dns.timeout"
    And it took less than 1200 milliseconds

  Scenario: A server that the client does not trust is refused
    Given the HTTPS peer listens with the script "/ok 200 application/dns-message 0 ID 8180 0001 0000 0000 0000 QUESTION"
    And the nameservers are:
      | kind  | port | name |
      | https | PORT | /ok  |
    When the resolver asks for the "A" addresses of "example.com"
    Then it fails with "dns.network"
