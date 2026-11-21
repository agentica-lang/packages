Feature: Requests and the pool of connections
  `HttpClient.new` makes a client, and `HttpClient.request` (or `get`, `post`, ...) sends a request through the pool
  of its origin and gives the whole response. The server of the normal flows is the one of `std/http`. A raw peer
  answers by hand with the answers of its script, in order, and each of its answers says which of its TCP connections
  served it (`x-connection`, from 1).

  Scenario: A pool with a live stream survives an idle sweep and is replaced after the stream ends
    Then the manager keeps watched pools and replaces expired ones

  Scenario: A GET gives the status, the headers and the body
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "r" sends "GET" to "/hello"
    Then "r" has the status 200
    And "r" has the body "hello"
    And "r" has the header "content-length: 5"

  Scenario: A 4xx or 5xx is a response, not an error
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "r" sends "GET" to "/status/503"
    Then "r" has the status 503

  Scenario: A POST sends its body, and the headers of the call go over those of the client
    Given the server "a" listens
    And a client of "a" with:
      | setting | value       |
      | header  | x-client: 1 |
      | header  | x-call: 1   |
    When "r" sends "POST" to "/echo" with the header "X-Call: 2"
    Then "r" has the body "POST /echo [] x-client=1 x-call=2"

  Scenario: The headers of the client go to every origin, not only to the one of base_url
    Given the server "a" listens
    And the server "b" listens
    And a client of "a" with:
      | setting | value       |
      | header  | x-client: 1 |
    When "r" sends "GET" to "{b}/echo"
    Then "r" has the body "GET /echo [] x-client=1"

  Scenario: A URL that is a path is joined to base_url, and an absolute one goes to its own origin
    Given the server "a" listens
    And the server "b" listens
    And a client of "a" with:
      | setting | value |
    When "r1" sends "PUT" to "echo?x=1" with the body "put"
    And "r2" sends "GET" to "{b}/hello"
    Then "r1" has the body "PUT /echo?x=1 [put]"
    And "r2" has the body "hello"

  Scenario: Requests to one origin reuse one connection
    Given the raw peer "a" listens with the script:
      """
      ok one
      ok two
      ok three
      """
    And a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/one"
    And "r2" sends "GET" to "/two"
    And "r3" sends "HEAD" to "/three"
    Then "r1" came on connection 1
    And "r2" has the body "two"
    And "r2" came on connection 1
    And "r3" came on connection 1

  Scenario: A connection that the server closed while idle is not reused
    Given the raw peer "a" listens with the script:
      """
      idle 200
      ok one
      ok two
      """
    And a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/one"
    And I wait 500 ms
    And "r2" sends "GET" to "/two"
    Then "r1" came on connection 1
    And "r2" has the status 200
    And "r2" came on connection 2

  Scenario: A response with Connection: close ends its connection
    Given the raw peer "a" listens with the script:
      """
      close closing
      ok two
      """
    And a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/close"
    And "r2" sends "GET" to "/two"
    Then "r1" came on connection 1
    And "r2" came on connection 2

  Scenario: A connection is not used past the Keep-Alive timeout of the server
    Given the raw peer "a" listens with the script:
      """
      keep-alive 1 kept
      ok two
      """
    And a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/keep-alive"
    And "r2" sends "GET" to "/two"
    Then "r1" came on connection 1
    And "r2" came on connection 2

  Scenario: A body that ends with the close of its connection is not followed by a reuse
    Given the raw peer "a" listens with the script:
      """
      until-close first
      ok two
      ok three
      """
    And a client of "a" with:
      | setting   | value |
      | pool_size | 1     |
    When "r1" sends "GET" to "/first"
    And "r2" sends "GET" to "/two"
    And "r3" sends "GET" to "/three"
    Then "r1" has the body "first"
    And "r2" came on connection 2
    And "r3" came on connection 2

  Scenario: A connection where the server wrote out of turn while it was idle is not reused
    Given the raw peer "a" listens with the script:
      """
      stray 100 one
      ok two
      """
    And a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/one"
    And I wait 400 ms
    And "r2" sends "GET" to "/two"
    Then "r1" came on connection 1
    And "r2" came on connection 2

  Scenario: A Keep-Alive timeout of years counts as a day
    Given the raw peer "a" listens with the script:
      """
      keep-alive 99999999999999999 kept
      ok two
      """
    And a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/keep-alive"
    And "r2" sends "GET" to "/two"
    Then "r1" came on connection 1
    And "r2" came on connection 1

  Scenario: Cancelling the task of a request leaves alone the connection it opened
    Given the raw peer "a" listens with the script:
      """
      ok one
      stall 600 firstlater
      ok three
      """
    And a client of "a" with:
      | setting   | value |
      | pool_size | 1     |
    When "u" starts "GET" to "/one"
    And I wait for "u"
    And "v" starts "GET" to "/stall"
    And the peer "a" has read request 2
    And the task of "u" is cancelled
    And I wait for "v"
    And "w" sends "GET" to "/three"
    Then "u" came on connection 1
    And "v" has the body "firstlater"
    And "v" came on connection 1
    And "w" came on connection 1

  Scenario: A request that std/http cannot write is an argument error, and its connection stays
    Given the raw peer "a" listens with the script:
      """
      ok one
      ok two
      """
    And a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/one"
    And "bad" sends "G T" to "/two"
    And "r2" sends "GET" to "/two"
    Then "bad" fails with the kind "argument"
    And "r2" came on connection 1

  Scenario: A request that a connection closed after 100 Continue is not sent again
    Given the raw peer "a" listens with the script:
      """
      ok one
      continue-close
      ok again
      """
    And a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/one"
    And "r2" sends "POST" to "/post" with the body "once"
    Then "r2" fails with the kind "http_client.network"
    And the peer "a" has read only 2 requests

  Scenario: A request waits at most pool_timeout_ms for a free connection
    Given the raw peer "a" listens with the script:
      """
      slow-head 800 slow
      """
    And a client of "a" with:
      | setting         | value |
      | pool_size       | 1     |
      | pool_timeout_ms | 150   |
    When "slow" starts "GET" to "/slow"
    And the peer "a" has read request 1
    And "r" sends "GET" to "/hello"
    And I wait for "slow"
    Then "r" fails with the kind "http_client.timeout.pool"
    And "r" ended within 600 ms
    And "slow" has the body "slow"

  Scenario: A head that comes later than read_timeout_ms is a read timeout
    Given the raw peer "a" listens with the script:
      """
      slow-head 1500 late
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 200   |
    When "r" sends "GET" to "/slow"
    Then "r" fails with the kind "http_client.timeout.read"
    And "r" ended within 1000 ms

  Scenario: A body that stalls past read_timeout_ms is a read timeout, and its connection is not reused
    Given the raw peer "a" listens with the script:
      """
      stall 1500 firstlater
      ok two
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 200   |
    When "r1" sends "GET" to "/stall"
    And "r2" sends "GET" to "/two"
    Then "r1" fails with the kind "http_client.timeout.read"
    And "r2" came on connection 2

  Scenario: A head that comes past body_idle_ms still comes, since the head has its own budget
    Given the raw peer "a" listens with the script:
      """
      slow-head 500 late
      ok after
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 1500  |
      | body_idle_ms    | 100   |
    When "r1" sends "GET" to "/slow"
    And "r2" sends "GET" to "/after"
    Then "r1" has the body "late"
    And "r2" came on connection 1

  Scenario: A body that stalls past body_idle_ms is a read timeout although the head came at once
    Given the raw peer "a" listens with the script:
      """
      stall 1200 firstlater
      ok two
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 4000  |
      | body_idle_ms    | 200   |
    When "r1" sends "GET" to "/stall"
    And "r2" sends "GET" to "/two"
    Then "r1" fails with the kind "http_client.timeout.read"
    And "r1" ended within 1000 ms
    And "r2" came on connection 2

  Scenario: A gzipped body that stalls past body_idle_ms is a read timeout as any other body is
    Given the raw peer "a" listens with the script:
      """
      stall-gzip 1200 aaaa
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 4000  |
      | body_idle_ms    | 200   |
    When "r" sends "GET" to "/gzip"
    Then "r" fails with the kind "http_client.timeout.read"
    And "r" ended within 1000 ms

  Scenario: A body with no idle limit may stall past read_timeout_ms and still come
    Given the raw peer "a" listens with the script:
      """
      stall 1200 firstlater
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 200   |
      | body_idle_ms    | 0     |
      | timeout_ms      | 5000  |
    When "r" sends "GET" to "/stall"
    Then "r" has the body "firstlater"

  Scenario: timeout_ms bounds the whole request
    Given the raw peer "a" listens with the script:
      """
      stall 1500 firstlater
      """
    And a client of "a" with:
      | setting    | value |
      | timeout_ms | 300   |
    When "r" sends "GET" to "/stall"
    Then "r" fails with the kind "http_client.timeout.request"
    And "r" ended within 1000 ms

  Scenario: A body over max_body_bytes is an error
    Given the server "a" listens
    And a client of "a" with:
      | setting        | value |
      | max_body_bytes | 100   |
    When "r1" sends "GET" to "/bytes?n=100"
    And "r2" sends "GET" to "/bytes?n=101"
    Then "r1" has the status 200
    And "r2" fails with the kind "http_client.too_large"

  Scenario: A port where nobody listens is a network error
    Given the port "dead" is closed
    And a client of "dead" with:
      | setting | value |
    When "r" sends "GET" to "/hello"
    Then "r" fails with the kind "http_client.network"

  Scenario: A request after the close is refused
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "r1" sends "GET" to "/hello"
    And I close the client
    And "r2" sends "GET" to "/hello"
    Then "r1" has the status 200
    And "r2" fails with the kind "http_client.closed"
