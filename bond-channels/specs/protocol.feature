Feature: Action Cable frames
  The `actioncable-v1-json` subprotocol, as pure functions of `src/protocol.agc`. Every frame is one line of
  compact JSON, and the identifiers and the commands are the ones that `loadgen cable` of
  basecamp/once-campfire-verification sends (the Rails client sends the same). The key order of a frame is the one of
  Rails, which the loadgen and `@rails/actioncable` do not need but a byte comparison with Rails does.

  Scenario: The server says welcome and pings with the Unix time
    Then the welcome frame is:
      """
      {"type":"welcome"}
      """
    And the ping frame at 1700000000 is:
      """
      {"type":"ping","message":1700000000}
      """

  Scenario: A subscription is confirmed with its identifier as a JSON string
    Given the identifier:
      """
      {"channel":"PresenceChannel","room_id":1}
      """
    Then the confirmation is:
      """
      {"identifier":"{\"channel\":\"PresenceChannel\",\"room_id\":1}","type":"confirm_subscription"}
      """

  Scenario: A subscription is rejected
    Given the identifier:
      """
      {"channel":"HeartbeatChannel"}
      """
    Then the rejection is:
      """
      {"identifier":"{\"channel\":\"HeartbeatChannel\"}","type":"reject_subscription"}
      """

  Scenario: A connection that is refused must not reconnect, and one that is dropped may
    Then the unauthorized disconnect is:
      """
      {"type":"disconnect","reason":"unauthorized","reconnect":false}
      """
    And the reconnecting disconnect is:
      """
      {"type":"disconnect","reason":null,"reconnect":true}
      """

  Scenario: A Turbo Stream is a string payload, with its quotes, backslashes and non-ASCII text as JSON
    Given the identifier:
      """
      {"channel":"Turbo::StreamsChannel","signed_stream_name":"IjEi--abc"}
      """
    And the text payload:
      """
      <turbo-stream action="append" target="messages_room_1"><template><div id="message_7">say "hi" \o/ café</div></template></turbo-stream>
      """
    Then the message is:
      """
      {"identifier":"{\"channel\":\"Turbo::StreamsChannel\",\"signed_stream_name\":\"IjEi--abc\"}","message":"<turbo-stream action=\"append\" target=\"messages_room_1\"><template><div id=\"message_7\">say \"hi\" \\o/ café</div></template></turbo-stream>"}
      """

  Scenario: A notice is an object payload, which the loadgen tells from a string by the opening brace
    Given the identifier:
      """
      {"channel":"UnreadRoomsChannel"}
      """
    And the object payload:
      """
      {"roomId":1,"at":1.5}
      """
    Then the message is:
      """
      {"identifier":"{\"channel\":\"UnreadRoomsChannel\"}","message":{"at":1.5,"roomId":1}}
      """

  Scenario: A client subscribes with the identifiers of the loadgen
    When the client sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"PresenceChannel\",\"room_id\":1}"}
      """
    Then the server reads:
      """
      {
        "command": "subscribe",
        "identifier": "{\"channel\":\"PresenceChannel\",\"room_id\":1}",
        "channel": "PresenceChannel",
        "params": {"channel": "PresenceChannel", "room_id": 1}
      }
      """
    When the client sends:
      """
      {"command":"subscribe","identifier":"{\"channel\":\"Turbo::StreamsChannel\",\"signed_stream_name\":\"IjEi--abc\"}"}
      """
    Then the server reads:
      """
      {
        "command": "subscribe",
        "identifier": "{\"channel\":\"Turbo::StreamsChannel\",\"signed_stream_name\":\"IjEi--abc\"}",
        "channel": "Turbo::StreamsChannel",
        "params": {"channel": "Turbo::StreamsChannel", "signed_stream_name": "IjEi--abc"}
      }
      """

  Scenario: The identifier is the key of the subscription, byte for byte, so the confirmation gives it back unchanged
    When the client sends:
      """
      {"command":"subscribe","identifier":"{ \"room_id\" : 1, \"channel\":\"Presence\\u0043hannel\", \"name\":\"caf\u00e9 \\\"x\\\"\" }"}
      """
    Then the server reads:
      """
      {
        "command": "subscribe",
        "identifier": "{ \"room_id\" : 1, \"channel\":\"Presence\\u0043hannel\", \"name\":\"café \\\"x\\\"\" }",
        "channel": "PresenceChannel",
        "params": {"room_id": 1, "channel": "PresenceChannel", "name": "café \"x\""}
      }
      """
    And the confirmation of that subscribe is:
      """
      {"identifier":"{ \"room_id\" : 1, \"channel\":\"Presence\\u0043hannel\", \"name\":\"café \\\"x\\\"\" }","type":"confirm_subscription"}
      """

  Scenario: A subscribe without a channel is read, and the hub finds no class for it
    When the client sends:
      """
      {"command":"subscribe","identifier":"{\"room_id\":1}"}
      """
    Then the server reads:
      """
      {"command":"subscribe","identifier":"{\"room_id\":1}","channel":"","params":{"room_id":1}}
      """

  Scenario: A client unsubscribes
    When the client sends:
      """
      {"command":"unsubscribe","identifier":"{\"channel\":\"HeartbeatChannel\"}"}
      """
    Then the server reads:
      """
      {"command":"unsubscribe","identifier":"{\"channel\":\"HeartbeatChannel\"}"}
      """

  Scenario: A message has its data parsed a second time, with the action and the rest of the object
    When the client sends:
      """
      {"command":"message","identifier":"{\"channel\":\"PresenceChannel\",\"room_id\":1}","data":"{\"action\":\"refresh\"}"}
      """
    Then the server reads:
      """
      {
        "command": "message",
        "identifier": "{\"channel\":\"PresenceChannel\",\"room_id\":1}",
        "action": "refresh",
        "data": {"action": "refresh"}
      }
      """
    When the client sends:
      """
      {"command":"message","identifier":"{\"channel\":\"TypingChannel\"}","data":"{\"action\":\"typing\",\"on\":true}"}
      """
    Then the server reads:
      """
      {
        "command": "message",
        "identifier": "{\"channel\":\"TypingChannel\"}",
        "action": "typing",
        "data": {"action": "typing", "on": true}
      }
      """

  Scenario Outline: A missing, null or blank action means receive (<case>)
    When the client sends a message whose data is:
      """
      <data>
      """
    Then the server reads:
      """
      {"command":"message","identifier":"{}","action":"receive","data":<data>}
      """

    Examples:
      | case        | data              |
      | no action   | {"body":"hi"}     |
      | null action | {"action":null}   |
      | empty       | {"action":""}     |
      | spaces      | {"action":"  "}   |

  Scenario Outline: A frame that Action Cable would only log is ignored (<case>)
    When the client sends:
      """
      <frame>
      """
    Then the server ignores it because "<reason>"

    Examples:
      | case                    | frame                                                                     | reason                |
      | not JSON                | hello                                                                     | JSON                  |
      | not an object           | [1]                                                                       | not a JSON object     |
      | no command              | {"identifier":"{}"}                                                       | no command            |
      | unknown command         | {"command":"ping","identifier":"{}"}                                      | unrecognized command  |
      | no identifier           | {"command":"subscribe"}                                                   | no identifier         |
      | identifier not a string | {"command":"unsubscribe","identifier":{}}                                 | identifier is not a string |
      | identifier not JSON     | {"command":"subscribe","identifier":"PresenceChannel"}                    | JSON                  |
      | identifier not an object| {"command":"subscribe","identifier":"[]"}                                 | not a JSON object     |
      | no data                 | {"command":"message","identifier":"{}"}                                   | no data               |
      | data not a string       | {"command":"message","identifier":"{}","data":{"action":"x"}}             | data is not a string  |
      | data not JSON           | {"command":"message","identifier":"{}","data":"refresh"}                  | JSON                  |
      | data not an object      | {"command":"message","identifier":"{}","data":"[]"}                       | not a JSON object     |
      | action not a string     | {"command":"message","identifier":"{}","data":"{\\"action\\":5}"}          | action is not a string |
