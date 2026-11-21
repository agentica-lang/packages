Feature: HTTP/2 requests

  Scenario: Buffered requests reuse a connection and respect both send windows
    Then an HTTP/2 client reuses the socket and obeys flow control

  Scenario: HTTPS requires h2 ALPN
    Then the HTTP/2 client checks ALPN against a TLS peer

  Scenario: Startup control frames can refuse the first stream
    Then HTTP/2 startup rejects invalid settings and respects an adjacent GOAWAY

  Scenario: Resolver addresses are tried after stalled settings
    Then the HTTP/2 client tries the next address after stalled settings

  Scenario: An unsent POST uses a fresh connection and returns an early final response
    Then an unsent HTTP/2 POST reconnects and returns the early response

  Scenario: Connect and read budgets keep distinct errors from the request deadline
    Then HTTP/2 reports the limiting deadline

  Scenario: Closing the client settles an active HTTP/2 request
    Then closing the HTTP/2 client settles an active request

  Scenario: A GET completes while a POST on the same socket has no upload credit
    Then the GET finishes on the socket that is waiting to upload

  Scenario: A stream times out while a second request waits for capacity
    Then HTTP/2 pauses admission and preserves HPACK across a cancelled stream

  Scenario: An initial window update affects concurrent uploads
    Then two uploads share one connection window

  Scenario: A failed socket settles its streams and is replaced on demand
    Then the origin replaces a failed session after settling all requests

  Scenario: An idle socket expires independently of a busy socket
    Then a spare HTTP/2 session closes while its origin has an active request

  Scenario: A malformed response preserves the shared HPACK decoder
    Then a mismatched content length resets only its stream

  Scenario: Queued writes expire while another write is blocked
    Then a blocked writer skips expired stream writes

  Scenario: An early response completes before its final queued upload expires
    Then a skipped final upload releases the peer stream slot
