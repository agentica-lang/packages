Feature: Auth, params, JSON, compressed bodies and steps
  `HttpClient.basic_auth` and `bearer_auth` make the `authorization` header, `params` go in the query, `json` sends a
  JSON body and `HttpClient.decode` reads one into a type. With `decompress` (the default) the client asks for gzip or
  deflate and decodes such a body. Request steps change each request before it goes, and response steps each
  response before it is given.

  Scenario: Basic and bearer auth set the authorization header
    Given the server "a" listens
    And the server "b" listens
    And a client of "a" with:
      | setting | value         |
      | basic   | user:password |
    When "r" sends "GET" to "/echo"
    Then "r" has the body "GET /echo [] authorization=Basic dXNlcjpwYXNzd29yZA=="
    And a client of "b" with:
      | setting | value |
      | bearer  | t0k3n |
    When "s" sends "GET" to "/echo"
    Then "s" has the body "GET /echo [] authorization=Bearer t0k3n"

  Scenario: The params of the client and of the call go in the query, after its own
    Given the server "a" listens
    And a client of "a" with:
      | setting | value   |
      | param   | key=k 1 |
    When "r" sends "GET" to "/echo?x=1" with the param "q=a&b"
    And "s" sends "GET" to "/echo"
    Then "r" has the body "GET /echo?x=1&key=k+1&q=a%26b []"
    And "s" has the body "GET /echo?key=k+1 []"

  Scenario: A JSON body goes as application/json, and a JSON response decodes into a type
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "r" sends "POST" to "/echo" with the JSON '{"a": [1, true]}'
    And "t" sends "POST" to "/header/content-type" with the JSON "{}"
    And "p" sends "GET" to "/json"
    And "h" sends "GET" to "/hello"
    Then "r" has the body 'POST /echo [{"a":[1,true]}]'
    And "t" has the body "application/json"
    And "p" decodes to the person "ana 3"
    And "h" does not decode

  Scenario: A gzip or deflate body is decoded, within max_body_bytes
    Given the server "a" listens
    And a client of "a" with:
      | setting        | value |
      | max_body_bytes | 4000  |
    When "asked" sends "GET" to "/header/accept-encoding"
    And "g" sends "GET" to "/gzip?n=3000"
    And "d" sends "GET" to "/deflate?n=5"
    And "big" sends "GET" to "/gzip?n=5000"
    And "bad" sends "GET" to "/bad-gzip"
    Then "asked" has the body "gzip, deflate"
    And "g" has a body of 3000 bytes
    And "d" has the body "aaaaa"
    And "big" fails with the kind "http_client.too_large"
    And "bad" fails with the kind "http_client.decode"

  Scenario: Without decompress the body stays as it came
    Given the server "a" listens
    And a client of "a" with:
      | setting    | value |
      | decompress | 0     |
    When "asked" sends "GET" to "/header/accept-encoding"
    And "g" sends "GET" to "/gzip?n=10"
    Then "asked" has the body ""
    And "g" has the header "content-encoding: gzip"

  Scenario: Request steps change the request and response steps the response
    Given the server "a" listens
    And a client of "a" with:
      | setting       | value        |
      | request_step  | x-step: 1    |
      | response_step | error_status |
    When "r" sends "GET" to "/echo"
    And "e" sends "GET" to "/status/404"
    Then "r" has the body "GET /echo [] x-step=1"
    And "e" fails with the kind "status"
