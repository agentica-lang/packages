Feature: Turbo stream names
  `<turbo-cable-stream-source>` carries a signed stream name, in the format of Rails, so that a name signed by Rails
  verifies here and the other way round. The vectors of `fixtures/turbo_vectors.json` were made by Rails; the cable
  scenarios subscribe through `Turbo::StreamsChannel` of the program of `fixtures/server.agc`, which refuses the
  names that start with `secret:`.

  Background:
    Given the environment variable "BEAT_MS" is "60000"

  Scenario: The key is the one that Rails derives from the secret
    Then the stream key of the secret of the vectors is the key of Rails
    And an empty secret makes no stream key

  Scenario: The names that Rails signed are signed the same here, and read back
    Then every name that Rails signed is signed the same here and read back

  Scenario: A name signed by Rails verifies, and a tampered, foreign or non-string one does not
    Then every signed name of the vectors verifies as it did in Rails

  Scenario: A client streams from a signed name and hears its broadcasts
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" subscribes to the Turbo stream "room:1"
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When the app broadcasts "hello" to "room:1"
    Then client "ana" eventually receives a frame containing "\"message\":\"hello\""

  Scenario Outline: A subscription is rejected when the stream name <case>
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" subscribes to the Turbo stream with the signed name "<signed>"
    Then client "ana" eventually receives a frame containing "reject_subscription"

    Examples:
      | case                         | signed                                                                                     |
      | is not signed                | room:1                                                                                     |
      | was signed with another key  | InJvb21zIg==--60a2ff565fb2226042c779b5711156db1d1cc48f89e6f59c94e4bf1da3f0945c             |
      | is blank                     |                                                                                            |

  Scenario: A subscription is rejected when the stream name is missing
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"Turbo::StreamsChannel\"}"}
      """
    Then client "ana" eventually receives a frame containing "reject_subscription"

  Scenario: A subscription is rejected when the stream name is not a string
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"Turbo::StreamsChannel\",\"signed_stream_name\":5}"}
      """
    Then client "ana" eventually receives a frame containing "reject_subscription"

  Scenario: A validly signed empty name is rejected
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" subscribes to the Turbo stream ""
    Then client "ana" eventually receives a frame containing "reject_subscription"

  Scenario: A signed name that the app does not allow is rejected, and streams nothing
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" subscribes to the Turbo stream "secret:1"
    Then client "ana" eventually receives a frame containing "reject_subscription"
    When the app broadcasts "leak" to "secret:1"
    Then client "ana" receives nothing for 300 milliseconds
