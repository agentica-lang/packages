Feature: Signing against an independent signer
  `fixtures/sigv4_peer.py` signs random requests and presigned URLs with Python's `hmac` and `hashlib`, written from the
  AWS documentation. Keys, queries and headers hold spaces, unicode and the characters that S3 percent-encodes, and the
  cases vary the endpoint (with default ports), the addressing, the region, the session token, the time and the expiry.

  Scenario Outline: The URLs and the signatures are those of the peer
    Given the peer signs 150 random requests from the seed <seed>
    Then the package signs every one as the peer does

    Examples:
      | seed |
      | 1    |
      | 2    |
      | 3    |
