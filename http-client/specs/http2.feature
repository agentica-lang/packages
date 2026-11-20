Feature: HTTP/2 requests

  Scenario: Buffered requests reuse a connection and respect both send windows
    Then an HTTP/2 client reuses the socket and obeys flow control

  Scenario: HTTPS requires h2 ALPN
    Then the HTTP/2 client checks ALPN against a TLS peer

  Scenario: Startup control frames can refuse the first stream
    Then HTTP/2 startup rejects invalid settings and respects an adjacent GOAWAY

  Scenario: Resolver addresses are tried after an ALPN mismatch
    Then the HTTP/2 client finds h2 on the second resolved address
