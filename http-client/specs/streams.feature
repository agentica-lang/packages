Feature: Streamed bodies and server-sent events
  `HttpClient.stream` gives the response once its head has come, and its body in pieces through a channel, as the
  server sends them. `HttpClient.get_events` reads such a body as server-sent events. The raw peer's `chunks` answer
  sends each piece as a chunk, a while apart.

  Scenario: The pieces of a body come as the server sends them, and the connection is kept after the end
    Given the raw peer "a" listens with the script:
      """
      chunks 300 one,two,three
      ok after
      """
    And a client of "a" with:
      | setting | value |
    When "s" streams "GET" from "/s"
    And "r" sends "GET" to "/r"
    Then "s" has the body "onetwothree"
    And the first piece of "s" came within 250 ms
    And "s" took at least 600 ms
    And "s" came on connection 1
    And "r" came on connection 1

  Scenario: A reader that closes the body early ends the request, and its connection
    Given the raw peer "a" listens with the script:
      """
      chunks 200 one,two,three,four
      ok after
      """
    And a client of "a" with:
      | setting | value |
    When "s" streams "GET" from "/s" and closes it after the first piece
    And "r" sends "GET" to "/r"
    Then "s" has the body "one"
    And "r" has the body "after"
    And "r" came on connection 2

  Scenario: A reader that takes nothing for read_timeout_ms gets an error after the pieces that waited
    Given the raw peer "a" listens with the script:
      """
      repeat 1 40 piece
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 300   |
    When "s" streams "GET" from "/s" and reads it after 800 ms
    Then "s" fails with the kind "http_client.timeout.read"

  Scenario: A reader of events that takes nothing for read_timeout_ms gets an error after the events that waited
    Given the raw peer "a" listens with the script:
      """
      repeat 1 60 data:_x\n\n
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 300   |
    When "e" reads the events of "/events" after 800 ms
    Then "e" fails with the kind "http_client.timeout.read"

  Scenario: A steady reader a little slower than the server gets the whole body
    Given the raw peer "a" listens with the script:
      """
      repeat 1 40 piece
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 500   |
    When "s" streams "GET" from "/s" taking a piece every 40 ms
    Then "s" has a body of 200 bytes

  Scenario: A steady reader of events a little slower than the server gets every event
    Given the raw peer "a" listens with the script:
      """
      repeat 1 40 data:_x\n\n
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 500   |
    When "e" reads the events of "/events" taking one every 40 ms
    Then "e" has a body of 399 bytes

  Scenario: A steady reader of events slower than a fast server gets every event
    Given the raw peer "a" listens with the script:
      """
      repeat 20 40 data:_x\n\n
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 300   |
    When "e" reads the events of "/events" taking one every 150 ms
    Then "e" has a body of 399 bytes

  Scenario: Events read by a task that is cancelled, or that crashes, end their body, and its connection goes
    Given the raw peer "a" listens with the script:
      """
      repeat 10 1000 data:_x\n\n
      repeat 10 1000 data:_x\n\n
      ok after
      """
    And a client of "a" with:
      | setting         | value |
      | pool_size       | 1     |
      | pool_timeout_ms | 3000  |
    When "c" reads the events of "/events" in a task that is cancelled after 300 ms
    And "k" reads the events of "/events" in a task that crashes after the first
    And "r" sends "GET" to "/r"
    Then "r" has the body "after"
    And "r" came on connection 3

  Scenario: A stream has one reader of events: a second events call is an argument error
    Given the raw peer "a" listens with the script:
      """
      repeat 10 20 data:_x\n\n
      """
    And a client of "a" with:
      | setting | value |
    When "e" reads the events of "/events" a second time
    Then "e" fails with the kind "argument"

  Scenario: Closing the events of a stream of comments closes its body, and its connection goes
    Given the raw peer "a" listens with the script:
      """
      repeat 50 200 :_beat\n
      ok after
      """
    And a client of "a" with:
      | setting         | value |
      | pool_size       | 1     |
      | pool_timeout_ms | 2000  |
    When "e" closes the events of "/events" after 300 ms
    And "r" sends "GET" to "/r"
    Then "r" has the body "after"
    And "r" came on connection 2

  Scenario: A stream that outlives timeout_ms and idle_ms keeps its pool
    Given the raw peer "a" listens with the script:
      """
      repeat 100 90 p
      """
    And a client of "a" with:
      | setting    | value |
      | timeout_ms | 1000  |
      | idle_ms    | 300   |
    When "s" streams "GET" from "/s"
    Then "s" has a body of 90 bytes

  Scenario: get_events refuses a response that is not a 2xx event stream
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "n" reads the events of "/status/404"
    And "t" reads the events of "/hello"
    Then "n" fails with the kind "http_client.events"
    And "t" fails with the kind "http_client.events"

  Scenario: A redirect is followed before the stream
    Given the server "a" listens
    And a client of "a" with:
      | setting | value |
    When "s" streams "GET" from "/redirect/302?to=/hello"
    Then "s" has the body "hello"
    And "s" ended at "{a}/hello"

  Scenario: A response that is retried is read whole and dropped, and the next one streams
    Given the raw peer "a" listens with the script:
      """
      status 503 busy
      chunks 10 one,two
      """
    And a client of "a" with:
      | setting     | value |
      | max_retries | 1     |
    When "s" streams "GET" from "/s"
    Then "s" has the status 200
    And "s" has the body "onetwo"
    And "s" came on connection 1

  Scenario: A piece that does not come within read_timeout_ms ends the stream with an error
    Given the raw peer "a" listens with the script:
      """
      chunks 1000 one,two
      """
    And a client of "a" with:
      | setting         | value |
      | read_timeout_ms | 300   |
    When "s" streams "GET" from "/s"
    Then "s" fails with the kind "http_client.timeout.read"

  Scenario: Server-sent events are read across pieces, with their type and data
    Given the raw peer "a" listens with the script:
      """
      chunks 50 :_hi\n,event:_add\ndata:_1\nda,ta:_2\n\n,data:_last\n\n
      """
    And a client of "a" with:
      | setting | value |
    When "e" reads the events of "/events"
    Then "e" has the body "add:1/2|message:last"
