Feature: The cable
  `Channels.mount` adds an Action Cable WebSocket to a Bond app. The program of `fixtures/server.agc` listens on
  127.0.0.1 and a free port; the clients are `fixtures/cable_peer.py`, a raw-socket WebSocket client with cookies and
  an Origin, and every frame is text of the `actioncable-v1-json` subprotocol (`protocol.feature` has the frames).

  Background:
    Given the environment variable "BEAT_MS" is "60000"

  Scenario: A client is welcomed, subscribes, and hears the broadcasts of its room only, from HTTP or from a client
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                  |
      | Cookie | user=ana               |
      | Origin | http://127.0.0.1:PORT  |
      | Sec-WebSocket-Protocol | actioncable-v1-json, actioncable-unsupported |
    Then the handshake of "ana" is answered 101
    And client "ana" receives:
      """
      {"type":"welcome"}
      """
    When client "ben" connects with:
      | header | value    |
      | Cookie | user=ben |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" subscribes to the room "1"
    And client "ben" subscribes to the room "2"
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    And client "ben" eventually receives a frame containing "confirm_subscription"
    When the app broadcasts "hello" to "room:1"
    Then client "ana" receives:
      """
      {"identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}","message":"hello"}
      """
    When client "ana" says "hi" in the room "1"
    Then client "ana" receives:
      """
      {"identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}","message":"ana: hi"}
      """
    And client "ben" receives nothing for 300 milliseconds

  Scenario: The frames that `subscribed` transmits come before the confirmation
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"GreetChannel\"}"}
      """
    Then client "ana" receives:
      """
      {"type":"welcome"}
      """
    And client "ana" receives:
      """
      {"identifier":"{\"channel\":\"GreetChannel\"}","message":"hello ana"}
      """
    And client "ana" receives:
      """
      {"identifier":"{\"channel\":\"GreetChannel\"}","type":"confirm_subscription"}
      """

  Scenario: A subscription can be rejected
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"RefusedChannel\"}"}
      """
    Then client "ana" eventually receives a frame containing "reject_subscription"

  Scenario: A connection that `connect` refuses is told so, and not welcomed
    Given the cable server listens on a free port
    When client "eve" connects with:
      | header | value                                        |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    Then the handshake of "eve" is answered 101
    And client "eve" receives:
      """
      {"type":"disconnect","reason":"unauthorized","reconnect":false}
      """
    And client "eve" is closed by the server with the code 1000

  Scenario Outline: A handshake from <case> is answered <status>
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Origin | <origin>                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    Then the handshake of "ana" is answered <status>

    Examples:
      | case              | origin                | status |
      | a page of the app | http://127.0.0.1:PORT | 101    |
      | another site      | https://evil.test     | 403    |

  Scenario: A client that does not offer actioncable-v1-json is closed with 1002
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                  |
      | Cookie | user=ana               |
      | Sec-WebSocket-Protocol | chat   |
    Then client "ana" is closed by the server with the code 1002

  Scenario: What Action Cable only logs gets no reply, and the connection stays open
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" subscribes to the room "1"
    And client "ana" subscribes to the room "1"
    And client "ana" sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"NoSuchChannel\"}"}
      """
    And client "ana" sends:
      """
      {"command":"unsubscribe","identifier":"{\"channel\":\"RoomChannel\",\"room\":\"9\"}"}
      """
    And client "ana" performs "refresh" in the room "9"
    And client "ana" sends:
      """
      not a frame
      """
    And client "ana" performs "refresh" in the room "1"
    Then client "ana" receives:
      """
      {"type":"welcome"}
      """
    And client "ana" receives:
      """
      {"identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}","type":"confirm_subscription"}
      """
    And client "ana" receives:
      """
      {"identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}","message":{"action":"refresh"}}
      """

  Scenario: A blank action is the action receive
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" subscribes to the room "1"
    And client "ana" sends:
      """
      {"command":"message","identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}","data":"{\"body\":\"hi\"}"}
      """
    Then client "ana" eventually receives a frame containing "\"message\":{\"action\":\"receive\"}"

  Scenario: After an unsubscribe nothing is streamed, and `unsubscribed` has run
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "watch" connects with:
      | header | value                                        |
      | Cookie | user=watch                                   |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "watch" sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"WatchChannel\"}"}
      """
    And client "ana" subscribes to the room "1"
    And client "ana" eventually receives a frame containing "confirm_subscription"
    And client "ana" sends:
      """
      {"command":"unsubscribe","identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}"}
      """
    Then client "watch" eventually receives a frame containing "\"message\":{\"left\":\"ana\",\"room\":\"1\"}"
    When the app broadcasts "late" to "room:1"
    Then client "ana" receives nothing for 300 milliseconds

  Scenario Outline: `unsubscribed` runs when a connection ends (<how>)
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "watch" connects with:
      | header | value                                        |
      | Cookie | user=watch                                   |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "watch" sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"WatchChannel\"}"}
      """
    And client "ana" subscribes to the room "1"
    And client "ana" eventually receives a frame containing "confirm_subscription"
    And client "ana" <ending>
    Then client "watch" eventually receives a frame containing "\"message\":{\"left\":\"ana\",\"room\":\"1\"}"

    Examples:
      | how                       | ending                           |
      | a close frame             | closes                           |
      | no close frame            | drops the connection             |
      | a crash of the handler    | performs "crash" in the room "1" |

  Scenario: A client that cannot keep up is dropped by the hub, and `unsubscribed` still runs
    Given the environment variable "INBOX" is "2"
    And the cable server listens on a free port
    When client "slow" connects with:
      | header | value                                        |
      | Cookie | user=slow                                    |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "watch" connects with:
      | header | value                                        |
      | Cookie | user=watch                                   |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "watch" sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"WatchChannel\"}"}
      """
    And client "slow" subscribes to the room "1"
    And client "slow" eventually receives a frame containing "confirm_subscription"
    And client "slow" performs "slow" in the room "1"
    And client "watch" eventually receives a frame containing "{\"started\":\"slow\"}"
    And the app broadcasts "m1" to "room:1"
    And the app broadcasts "m2" to "room:1"
    And the app broadcasts "m3" to "room:1"
    And the app broadcasts "m4" to "room:1"
    Then client "slow" receives:
      """
      {"identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}","message":"m1"}
      """
    And client "slow" receives:
      """
      {"identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}","message":"m2"}
      """
    And client "slow" receives:
      """
      {"type":"disconnect","reason":null,"reconnect":true}
      """
    And client "watch" eventually receives a frame containing "\"message\":{\"left\":\"slow\",\"room\":\"1\"}"
    And the stats become:
      """
      {"connections":1,"subscriptions":1,"drops":1,"lost":0}
      """

  Scenario: The stats follow the connections and subscriptions
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ben" connects with:
      | header | value                                        |
      | Cookie | user=ben                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" subscribes to the room "1"
    And client "ana" subscribes to the room "2"
    And client "ben" subscribes to the room "1"
    Then the stats become:
      """
      {"connections":2,"subscriptions":3,"drops":0,"lost":0}
      """
    When client "ana" closes
    Then the stats become:
      """
      {"connections":1,"subscriptions":1,"drops":0,"lost":0}
      """

  Scenario: A quiet client stays connected past idle_ms, because the hub pings the WebSocket
    Given the environment variable "BEAT_MS" is "100"
    And the environment variable "IDLE_MS" is "1500"
    And the cable server listens on a free port
    When client "quiet" connects with:
      | header | value                                        |
      | Cookie | user=quiet                                   |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "quiet" subscribes to the room "1"
    Then client "quiet" eventually receives a frame containing "{\"type\":\"ping\",\"message\":"
    When 2000 milliseconds pass
    And client "quiet" performs "refresh" in the room "1"
    Then client "quiet" eventually receives a frame containing "\"message\":{\"action\":\"refresh\"}"

  Scenario: A subscription whose `subscribed` fails is rejected and forgotten
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"FailingChannel\"}"}
      """
    Then client "ana" eventually receives a frame containing "reject_subscription"
    And the stats become:
      """
      {"connections":1,"subscriptions":0,"drops":0,"lost":0}
      """

  Scenario: A hub that is stopped tells its connections to reconnect, and refuses new ones
    Given the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"WatchChannel\"}"}
      """
    Then client "ana" eventually receives a frame containing "confirm_subscription"
    When the app stops the hub
    Then client "ana" eventually receives a frame containing "{\"type\":\"disconnect\",\"reason\":null,\"reconnect\":true}"
    And client "ana" is closed by the server with the code 1001
    When client "late" connects with:
      | header | value                                        |
      | Cookie | user=late                                    |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    Then client "late" receives:
      """
      {"type":"disconnect","reason":null,"reconnect":true}
      """
    And client "late" is closed by the server with the code 1001
    And the stats become:
      """
      {"connections":0,"subscriptions":0,"drops":0,"lost":0}
      """

  Scenario: A broadcast that the hub cannot take is an error, and counted as lost
    Given the cable server listens on a free port
    When the app stops the hub
    And the app cannot broadcast "late" to "room:1"
    Then the stats become:
      """
      {"connections":0,"subscriptions":0,"drops":0,"lost":1}
      """

  Scenario: A client frame over max_message_bytes closes the connection with 1009
    Given the environment variable "MAX_MESSAGE_BYTES" is "1000"
    And the cable server listens on a free port
    When client "ana" connects with:
      | header | value                                        |
      | Cookie | user=ana                                     |
      | Sec-WebSocket-Protocol | actioncable-v1-json |
    And client "ana" sends a text of 2000 bytes
    Then client "ana" is closed by the server with the code 1009
