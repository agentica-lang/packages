## The records of the package: what a node says to another one on a connection.

## The kinds of the errors of the package, for `e.is_a?("cluster.protocol")`. Bytes that break the wire format: a bad
## preamble, a length of zero, an unknown kind or a body that does not fit its kind.
PROTOCOL = "cluster.protocol"

## The peer did not prove that it knows the cookie, or it has the name of this node or another name than the one
## that was dialed.
REFUSED = "cluster.refused"

## A bad option, such as a cookie that is too short.
ARGUMENT = "cluster.argument"

## A frame is longer than the limit of the connection.
TOO_LARGE = "cluster.too_large"

## The most bytes of a frame (its kind and its body), when the options say nothing else.
MAX_FRAME_BYTES = 1_048_576

## The most bytes of the name of a mailbox.
MAX_MAILBOX_BYTES = 255

## The most bytes of a frame before the handshake ends. The biggest frame of the handshake has less than 200, so a
## stranger cannot make a node read more before it proves the cookie.
PRE_AUTH_MAX_FRAME_BYTES = 256

## The bytes of a nonce and of a proof (HMAC-SHA256), and the least bytes of a cookie. The least is a floor, not a
## measure of strength: the cookie should be a random secret (`openssl rand -hex 32`).
NONCE_BYTES = 32
PROOF_BYTES = 32
MIN_COOKIE_BYTES = 16

## What a node says: the four messages of the handshake (src/handshake.agc), then ping, pong and bye. A `Mail` goes
## to the mailbox of the receiving node, with the Term CBOR bytes of the value. A frame of a kind that this version
## does not know, but that is meant to be skipped, reads as `Ignored`.
enum Message
  Hello(String, Bytes)
  Challenge(String, Bytes, Bytes)
  Proof(Bytes)
  Welcome
  Ping
  Pong
  Bye(String)
  Mail(String, Bytes)
  Ignored(Int)
end
