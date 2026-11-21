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
