Feature: A WebSocket client
  `WebSocket.connect` opens a WebSocket (RFC 6455) over TCP or TLS. Two peers answer it. The server of `std/http`
  (`fixtures/server.agc`) is a real server: it checks that the frames are masked, so a scenario that gets an answer
  from it proves the frames. `fixtures/raw_peer.agc` writes the bytes that no real server writes (bad frames,
  fragments, pings) from a script of hex frames, and prints the frames that it reads. Both listen on 127.0.0.1, on a
  free port. A frame in hex: the first byte is FIN and the opcode (81 is a whole text), the second the length, then
  the payload.

  Scenario: Text and binary go to a server and come back, and the close handshake ends the connection
    Given the std server listens on a free port
    When the client connects to "ws://127.0.0.1:PORT/echo"
    And the client sends the text "héllo"
    Then the client receives the text "héllo"
    When the client sends the binary "00ff10"
    Then the client receives the binary "00ff10"
    When the client closes with 1000 and "done"
    Then the client has no connection

  Scenario Outline: The length of a frame takes the shortest form on the wire
    Given the std server listens on a free port
    When the client connects to "ws://127.0.0.1:PORT/echo"
    And the client sends a text of <size> bytes
    Then the client receives a text of <size> bytes

    Examples:
      | size  |
      | 125   |
      | 126   |
      | 70000 |

  Scenario: The headers of the handshake reach the server, cookies and authorization included
    Given the std server listens on a free port
    And the client sends the header "Cookie" with "user=ana"
    And the client sends the header "Authorization" with "Bearer secret"
    When the client connects to "ws://127.0.0.1:PORT/headers"
    Then the client receives the text "cookie=user=ana;authorization=Bearer secret"

  Scenario: The server picks one of the subprotocols that the client offers
    Given the std server listens on a free port
    And the client offers the subprotocols "unknown, chat"
    When the client connects to "ws://127.0.0.1:PORT/chat"
    Then the subprotocol is "chat"
    And the client receives the text "protocol=chat"

  Scenario: A wss URL is a TLS connection that checks the certificate
    Given the std server listens with TLS on a free port
    And the client trusts the certificate of the specs
    When the client connects to "wss://localhost:PORT/echo"
    And the client sends the text "secure"
    Then the client receives the text "secure"

  Scenario: A wss server whose certificate is not trusted is refused
    Given the std server listens with TLS on a free port
    When the client connects to "wss://localhost:PORT/echo"
    Then the connection fails with "certificate"

  Scenario: Nothing listens at the port
    When the client connects to a port that nobody listens at
    Then the connection fails with "websocket: "

  Scenario Outline: An answer that is not the handshake of RFC 6455 is refused
    Given the raw peer listens with the script:
      """
      handshake <answer>
      """
    When the client connects to "ws://127.0.0.1:PORT/"
    Then the connection fails with "<reason>"

    Examples:
      | answer         | reason                     |
      | status 403     | answered 403               |
      | bad-accept     | Sec-WebSocket-Accept       |
      | missing-upgrade | Upgrade                   |
      | extension      | extension                  |
      | protocol other | subprotocol                |

  Scenario: Every frame of the client is masked and whole
    Given the raw peer listens with the script:
      """
      expect
      expect
      expect
      expect
      wait
      """
    When the client connects to "ws://127.0.0.1:PORT/"
    And the client sends the text "Hello"
    And the client sends the binary "0102"
    And the client pings with "p1"
    And the client pongs with "p2"
    Then the peer saw "frame op=1 fin=true masked=true payload=48656c6c6f"
    And the peer saw "frame op=2 fin=true masked=true payload=0102"
    And the peer saw "frame op=9 fin=true masked=true payload=7031"
    And the peer saw "frame op=10 fin=true masked=true payload=7032"

  Scenario: A frame that comes with the handshake is not lost
    Given the raw peer listens with the script:
      """
      send 81 02 68 69
      wait
      """
    When the client connects to "ws://127.0.0.1:PORT/"
    Then the client receives the text "hi"

  Scenario: Fragments are joined, and a ping between them is answered with a pong that has its payload
    Given the raw peer listens with the script:
      """
      send 01 03 48 65 6c
      send 89 02 70 31
      send 80 02 6c 6f
      expect
      wait
      """
    When the client connects to "ws://127.0.0.1:PORT/"
    Then the client receives the text "Hello"
    And the peer saw "frame op=10 fin=true masked=true payload=7031"

  Scenario: A pong that nobody asked for is not a message
    Given the raw peer listens with the script:
      """
      send 8a 00 81 02 68 69
      wait
      """
    When the client connects to "ws://127.0.0.1:PORT/"
    Then the client receives the text "hi"

  Scenario: The server closes with a code and a reason, and the client answers with the code
    Given the raw peer listens with the script:
      """
      send 88 05 03 e9 62 79 65
      expect
      wait
      """
    When the client connects to "ws://127.0.0.1:PORT/"
    Then the client receives the close 1001 "bye"
    And the peer saw a close frame with the code 1001
    And the client has no connection

  Scenario: The client closes, and waits for the answer of the server
    Given the raw peer listens with the script:
      """
      expect
      send 88 02 03 e8
      wait
      """
    When the client connects to "ws://127.0.0.1:PORT/"
    And the client closes with 1000 and "done"
    Then the peer saw "frame op=8 fin=true masked=true payload=03e8646f6e65"
    And the client has no connection

  Scenario: A server that does not answer the close does not hold the client
    Given the raw peer listens with the script:
      """
      expect
      wait
      """
    And the client waits 300 milliseconds for the answer to a close
    When the client connects to "ws://127.0.0.1:PORT/"
    And the client closes with 1000 and ""
    Then the peer saw a close frame with the code 1000
    And the client has no connection

  Scenario: A server that drops the connection is a close with the code 1006
    Given the raw peer listens with the script:
      """
      close
      """
    When the client connects to "ws://127.0.0.1:PORT/"
    Then the client receives the close 1006 ""

  Scenario: A server that stays silent past the read timeout is an error
    Given the raw peer listens with the script:
      """
      sleep 5000
      """
    And the client waits 300 milliseconds for a read
    When the client connects to "ws://127.0.0.1:PORT/"
    Then the client fails to receive with "timed out"

  Scenario Outline: A frame that breaks the protocol is refused, and the server is told why
    The limit of a message is 10 bytes here.

    Given the raw peer listens with the script:
      """
      send <frame>
      expect
      wait
      """
    And the client reads at most 10 bytes of a message
    When the client connects to "ws://127.0.0.1:PORT/"
    Then the client fails to receive with "<reason>"
    And the peer saw a close frame with the code <code>

    Examples:
      | what                       | frame                    | code | reason                               |
      | a masked frame             | 81 85 37 fa 21 3d 7f 9f  | 1002 | must not be masked                   |
      | a reserved bit             | c1 01 61                 | 1002 | reserved bits                        |
      | an unknown opcode          | 83 00                    | 1002 | unknown opcode                       |
      | a control frame over 125   | 89 7e 00 7e              | 1002 | at most 125 bytes                    |
      | a fragmented control frame | 09 00                    | 1002 | cannot be fragmented                 |
      | text that is not UTF-8     | 81 02 c3 28              | 1007 | not valid UTF-8                      |
      | a message over the limit   | 82 0b                    | 1009 | message too big                      |
      | a length with the top bit  | 82 7f ff ff ff ff ff ff ff ff | 1002 | invalid frame length            |
      | a continuation of nothing  | 80 01 61                 | 1002 | continuation with no message         |
      | a close of one byte        | 88 01 03                 | 1002 | close frame of one byte              |

  Scenario: A control payload over 125 bytes and a message over 1 MiB are refused before they are sent
    Given the std server listens on a free port
    When the client connects to "ws://127.0.0.1:PORT/echo"
    Then sending a ping of 126 bytes fails with "125"
    And sending a text of 1048576 bytes fails with "too big"
