## The rules for the names that cross the wire. A caller makes the error, since the same bad name is a bad option on
## one side and bad bytes on the other.

import Types from "types"

## A node name is a lowercase letter, then up to 62 lowercase letters, digits, `_` or `-`.
def node_name?(name: String) -> Bool
  bytes = name.bytes
  return false if bytes.empty? or bytes.size > MAX_NODE_NAME_BYTES
  return false if not LETTERS.include?(bytes[0])

  bytes.to_a.all? { |b| LETTERS.include?(b) or DIGITS.include?(b) or b == UNDERSCORE or b == HYPHEN }
end

## What a hello and a challenge carry: a valid node name and a nonce of the right size.
def peer?(name: String, nonce: Bytes) -> Bool = node_name?(name) and nonce.size == Types.NONCE_BYTES

## A mailbox name has 1 to 255 bytes.
def mailbox_name?(name: String) -> Bool = not name.bytes.empty? and name.bytes.size <= Types.MAX_MAILBOX_BYTES

private

MAX_NODE_NAME_BYTES = 63
LETTERS = "a".code.."z".code
DIGITS = "0".code.."9".code
UNDERSCORE = "_".code
HYPHEN = "-".code
