Feature: Redirects
  A 301, 302, 303, 307 or 308 with a `Location` is followed, at most `max_redirects` times. A 303 turns the request
  into a GET without a body, and so do a 301 and a 302 for a POST; a 307 and a 308 keep the method and the body. A
  redirect to another origin goes without `Authorization` and `Cookie`. The server of `std/http` answers
  `/redirect/CODE?to=URL` with CODE and that `Location`, and `/echo` with the method, target, body and the
  `authorization` header.

  Scenario: A redirect is followed, and the response names where it ended
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "r" sends "GET" to "/redirect/302?to=/hello"
    Then "r" has the body "hello"
    And "r" ended at "{a}/hello"

  Scenario: A 303 after a POST is a GET without the body
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "r" sends "POST" to "/redirect/303?to=/echo" with the body "data"
    Then "r" has the body "GET /echo []"

  Scenario: A 307 keeps the method and the body
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "r" sends "POST" to "/redirect/307?to=/echo" with the body "data"
    Then "r" has the body "POST /echo [data]"

  Scenario: More redirects than max_redirects are an error
    Given the server "a" listens
    And a client of "a" with:
      | setting       | value |
      | max_redirects | 3     |
    When "r" sends "GET" to "/loop"
    Then "r" fails with the kind "http_client.redirect.too_many"

  Scenario: With max_redirects 0 the redirect is the response
    Given the server "a" listens
    And a client of "a" with:
      | setting       | value |
      | max_redirects | 0     |
    When "r" sends "GET" to "/redirect/302?to=/hello"
    Then "r" has the status 302

  Scenario: Authorization goes on a redirect to the same origin, not to another one
    Given the server "a" listens
    And the server "b" listens
    And a client of "a" with:
      | setting | value                 |
      | header  | authorization: secret |
    When "same" sends "GET" to "/redirect/302?to=/echo"
    And "other" sends "GET" to "/redirect/302?to={b}/echo"
    Then "same" has the body "GET /echo [] authorization=secret"
    And "other" has the body "GET /echo []"

  Scenario: A Location that is not an http URL is an error
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "r" sends "GET" to "/redirect/302?to=ftp://example.com/file"
    Then "r" fails with the kind "http_client.redirect.location"
