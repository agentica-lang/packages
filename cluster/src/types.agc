## The records of the package: what a node says to another one on a connection.

## The kinds of the errors of the package, for `e.is_a?("cluster.protocol")`. Bytes that break the wire format: a bad
## preamble, a length of zero, an unknown kind or a body that does not fit its kind.
PROTOCOL = "cluster.protocol"

## A frame is longer than the limit of the connection.
TOO_LARGE = "cluster.too_large"

## The most bytes of a frame (its kind and its body), when the options say nothing else.
MAX_FRAME_BYTES = 1_048_576

## The most bytes of the name of a mailbox.
MAX_MAILBOX_BYTES = 255

## What a node says. A `Mail` goes to the mailbox of the receiving node, with the Term CBOR bytes of the value. A
## frame of a kind that this version does not know, but that is meant to be skipped, reads as `Ignored`.
enum Message
  Ping
  Pong
  Bye(String)
  Mail(String, Bytes)
  Ignored(Int)
end
