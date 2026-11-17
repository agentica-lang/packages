Feature: Resolving and filtering addresses
  By default std/http resolves the host. With a `resolver` or `public_only`, the client resolves it itself (with the
  system's resolver when none is given), keeps the answers `dns_cache_ms`, and with `public_only` refuses every
  address that is not public. The connection goes to the address it checked, and the URL host still names the server:
  in `Host`, and for TLS in the server name and the certificate check. The resolver of these scenarios knows only the
  names of its `resolve` rows. The TLS server has a certificate for `api.test` alone.

  Scenario: A name goes to the address its resolver gives, and Host names the host
    Given the server "a" listens
    And a client of "a" with:
      | setting | value              |
      | resolve | api.test=127.0.0.1 |
    When "r" sends "GET" to "http://api.test:{a:port}/host"
    Then "r" has the body "api.test:{a:port}"
    And the resolver was asked 1 times

  Scenario: Without a resolver or public_only std/http resolves the host
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "r" sends "GET" to "http://localhost:{a:port}/host"
    Then "r" has the body "localhost:{a:port}"

  Scenario: HTTPS checks the certificate against the host, not the address
    Given the TLS server "s" listens
    And a client of "s" with:
      | setting | value                |
      | resolve | api.test=127.0.0.1   |
      | resolve | other.test=127.0.0.1 |
      | ca      | fixtures/tls/ca.pem  |
    When "good" sends "GET" to "https://api.test:{s:port}/host"
    And "wrong" sends "GET" to "https://other.test:{s:port}/host"
    Then "good" has the body "api.test:{s:port}"
    And "wrong" fails with the kind "http_client.network"

  Scenario: The next address is tried when one refuses
    Given the server "a" listens
    And a client of "a" with:
      | setting | value                        |
      | resolve | api.test=127.0.0.2,127.0.0.1 |
    When "r" sends "GET" to "http://api.test:{a:port}/hello"
    Then "r" has the body "hello"

  Scenario: The answers of the resolver are kept for dns_cache_ms
    Given the raw peer "a" listens with the script:
      """
      close one
      close two
      """
    And a client of "a" with:
      | setting      | value              |
      | resolve      | api.test=127.0.0.1 |
      | dns_cache_ms | 10000              |
    When "r1" sends "GET" to "http://api.test:{a:port}/one"
    And "r2" sends "GET" to "http://api.test:{a:port}/two"
    Then "r2" came on connection 2
    And the resolver was asked 1 times

  Scenario: With dns_cache_ms 0 each connection asks the resolver
    Given the raw peer "a" listens with the script:
      """
      close one
      close two
      """
    And a client of "a" with:
      | setting      | value              |
      | resolve      | api.test=127.0.0.1 |
      | dns_cache_ms | 0                  |
    When "r1" sends "GET" to "http://api.test:{a:port}/one"
    And "r2" sends "GET" to "http://api.test:{a:port}/two"
    Then "r2" came on connection 2
    And the resolver was asked 2 times

  Scenario: A host the resolver does not know is a DNS error
    Given the server "a" listens
    And a client of "a" with:
      | setting | value              |
      | resolve | api.test=127.0.0.1 |
    When "r" sends "GET" to "http://nowhere.test:{a:port}/hello"
    Then "r" fails with the kind "http_client.dns"

  Scenario: public_only refuses a name that resolves to a loopback address, before any connection
    Given the raw peer "a" listens with the script:
      """
      ok one
      """
    And a client of "a" with:
      | setting     | value              |
      | resolve     | api.test=127.0.0.1 |
      | public_only | 1                  |
    When "r" sends "GET" to "http://api.test:{a:port}/one"
    Then "r" fails with the kind "http_client.address_denied"
    And the peer "a" has read only 0 requests

  Scenario: public_only refuses an IP literal that is not public
    Given the server "a" listens
    And a client of "a" with:
      | setting     | value |
      | public_only | 1     |
    When "r" sends "GET" to "{a}/hello"
    Then "r" fails with the kind "http_client.address_denied"

  Scenario: public_only alone resolves with the system resolver and refuses localhost
    Given the server "a" listens
    And a client of "a" with:
      | setting     | value |
      | public_only | 1     |
    When "r" sends "GET" to "http://localhost:{a:port}/hello"
    Then "r" fails with the kind "http_client.address_denied"
