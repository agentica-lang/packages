Feature: HTTP/2 requests

  Scenario: Buffered requests reuse a connection and respect both send windows
    Then an HTTP/2 client reuses the socket and obeys flow control

  Scenario: HTTPS requires h2 ALPN
    Then the HTTP/2 client checks ALPN against a TLS peer
