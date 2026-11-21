Feature: Retries
  An idempotent request (GET, HEAD, OPTIONS, TRACE, PUT, DELETE) goes again, at most `max_retries` times in all,
  after a transient error (a connect or read timeout, a broken connection) or a transient status (408, 429, 500, 502,
  503, 504). The wait doubles from `retry_delay_ms` with jitter, and a `Retry-After` is waited as it is, unless it is
  over `max_retry_delay_ms` or past `timeout_ms`, which bounds the whole call. The raw peer answers with its script, in
  order, and says which connection served each answer.

  Scenario: A GET answered 503 goes again
    Given the raw peer "a" listens with the script:
      """
      status 503 -
      ok fine
      """
    And a client of "a" with:
      | setting     | value |
      | max_retries | 2     |
    When "r" sends "GET" to "/flaky"
    Then "r" has the body "fine"
    And the peer "a" has read only 2 requests

  Scenario: A POST is never sent again
    Given the raw peer "a" listens with the script:
      """
      status 503 -
      ok fine
      """
    And a client of "a" with:
      | setting     | value |
      | max_retries | 2     |
    When "r" sends "POST" to "/order" with the body "one"
    Then "r" has the status 503
    And the peer "a" has read only 1 requests

  Scenario: A GET whose connection broke goes again on a new connection
    Given the raw peer "a" listens with the script:
      """
      drop
      ok fine
      """
    And a client of "a" with:
      | setting     | value |
      | max_retries | 1     |
    When "r" sends "GET" to "/flaky"
    Then "r" has the body "fine"
    And "r" came on connection 2

  Scenario: Without retries the broken connection is the error
    Given the raw peer "a" listens with the script:
      """
      drop
      ok fine
      """
    And a client of "a" with:
      | setting     | value |
      | max_retries | 0     |
    When "r" sends "GET" to "/flaky"
    Then "r" fails with the kind "http_client.network"

  Scenario: When the retries run out the last response is the answer
    Given the raw peer "a" listens with the script:
      """
      status 503 a
      status 500 b
      status 503 c
      ok late
      """
    And a client of "a" with:
      | setting     | value |
      | max_retries | 2     |
    When "r" sends "GET" to "/down"
    Then "r" has the status 503
    And "r" has the body "c"
    And the peer "a" has read only 3 requests

  Scenario: A Retry-After is waited
    Given the raw peer "a" listens with the script:
      """
      after 503 1
      ok fine
      """
    And a client of "a" with:
      | setting     | value |
      | max_retries | 1     |
    When "r" sends "GET" to "/busy"
    Then "r" has the body "fine"
    And "r" took at least 1000 ms

  Scenario: A Retry-After over max_retry_delay_ms gives the response back
    Given the raw peer "a" listens with the script:
      """
      after 503 120
      ok fine
      """
    And a client of "a" with:
      | setting            | value |
      | max_retries        | 1     |
      | max_retry_delay_ms | 1000  |
    When "r" sends "GET" to "/busy"
    Then "r" has the status 503
    And "r" ended within 900 ms
    And the peer "a" has read only 1 requests

  Scenario: timeout_ms bounds the whole call, its retries included
    Given the server "a" listens
    And a client of "a" with:
      | setting        | value |
      | max_retries    | 10    |
      | retry_delay_ms | 100   |
      | timeout_ms     | 800   |
    When "r" sends "GET" to "/status/503"
    Then "r" ended within 1100 ms
