Feature: Requests and the pool of connections
  `HttpClient.new` makes a client, and `HttpClient.request` (or `get`, `post`, ...) sends a request through the pool
  of its origin and gives the whole response. The peer is an HTTP/1.1 server of Python's standard library, and each
  response says which of its TCP connections served it (`x-connection`, from 1).

  Background:
    Given the peer "a" listens

  Scenario: A GET gives the status, the headers and the body
    Given a client of "a" with:
      | setting | value |
    When "r" sends "GET" to "/hello"
    Then "r" has the status 200
    And "r" has the body "hello"
    And "r" has the header "content-length: 5"

  Scenario: A 4xx or 5xx is a response, not an error
    Given a client of "a" with:
      | setting | value |
    When "r" sends "GET" to "/status/503"
    Then "r" has the status 503

  Scenario: A POST sends its body, and the headers of the call go over those of the client
    Given a client of "a" with:
      | setting | value       |
      | header  | x-client: 1 |
      | header  | x-call: 1   |
    When "r" sends "POST" to "/echo" with the header "X-Call: 2"
    Then "r" has the body "POST /echo [] x-client=1 x-call=2"

  Scenario: A URL that is a path is joined to base_url, and an absolute one goes to its own origin
    Given the peer "b" listens
    And a client of "a" with:
      | setting | value |
    When "r1" sends "PUT" to "echo?x=1" with the body "put"
    And "r2" sends "GET" to "{b}/hello"
    Then "r1" has the body "PUT /echo?x=1 [put]"
    And "r2" has the body "hello"

  Scenario: Requests to one origin reuse one connection
    Given a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/hello"
    And "r2" sends "GET" to "/hello"
    And "r3" sends "HEAD" to "/hello"
    Then "r1" came on connection 1
    And "r2" came on connection 1
    And "r3" came on connection 1

  Scenario: A connection that the server closed while idle is not reused
    Given the peer "b" listens and closes idle connections after 200 ms
    And a client of "b" with:
      | setting | value |
    When "r1" sends "GET" to "/hello"
    And I wait 500 ms
    And "r2" sends "GET" to "/hello"
    Then "r1" came on connection 1
    And "r2" has the status 200
    And "r2" came on connection 2

  Scenario: A response with Connection: close ends its connection
    Given a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/close"
    And "r2" sends "GET" to "/hello"
    Then "r1" came on connection 1
    And "r2" came on connection 2

  Scenario: A connection is not used past the Keep-Alive timeout of the server
    Given a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/keep-alive?s=1"
    And "r2" sends "GET" to "/hello"
    Then "r1" came on connection 1
    And "r2" came on connection 2

  Scenario: A request waits at most pool_timeout_ms for a free connection
    Given a client of "a" with:
      | setting         | value |
      | pool_size       | 1     |
      | pool_timeout_ms | 150   |
    When "slow" starts "GET" to "/slow-head?ms=800"
    And I wait 100 ms
    And "r" sends "GET" to "/hello"
    And I wait for "slow"
    Then "r" fails with the kind "http_client.timeout.pool"
    And "r" ended within 600 ms
    And "slow" has the status 200

  Scenario: A head that comes later than read_timeout_ms is a read timeout
    Given a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 200   |
    When "r" sends "GET" to "/slow-head?ms=1500"
    Then "r" fails with the kind "http_client.timeout.read"
    And "r" ended within 1000 ms

  Scenario: A body that stalls past read_timeout_ms is a read timeout, and its connection is not reused
    Given a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 200   |
    When "r1" sends "GET" to "/slow-body?ms=1500"
    And "r2" sends "GET" to "/hello"
    Then "r1" fails with the kind "http_client.timeout.read"
    And "r2" came on connection 2

  Scenario: timeout_ms bounds the whole request
    Given a client of "a" with:
      | setting    | value |
      | timeout_ms | 300   |
    When "r" sends "GET" to "/slow-body?ms=1500"
    Then "r" fails with the kind "http_client.timeout.request"
    And "r" ended within 1000 ms

  Scenario: A body over max_body_bytes is an error
    Given a client of "a" with:
      | setting        | value |
      | max_body_bytes | 100   |
    When "r1" sends "GET" to "/bytes?n=100"
    And "r2" sends "GET" to "/bytes?n=101"
    Then "r1" has the status 200
    And "r2" fails with the kind "http_client.too_large"

  Scenario: A port where nobody listens is a network error
    Given a client of "a" with:
      | setting | value |
    When "r" sends "GET" to "http://127.0.0.1:1/hello"
    Then "r" fails with the kind "http_client.network"

  Scenario: A request after the close is refused
    Given a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/hello"
    And I close the client
    And "r2" sends "GET" to "/hello"
    Then "r1" has the status 200
    And "r2" fails with the kind "http_client.closed"
