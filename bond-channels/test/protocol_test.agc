import Protocol from "../src/protocol"

# The one rule that a feature would need a 4 KiB Doc String for.
def padded_identifier(bytes: Int) -> String
  frame_start = "{\"channel\":\"A\",\"pad\":\""
  frame_end = "\"}"
  return frame_start + "x" * (bytes - frame_start.bytes.length - frame_end.bytes.length) + frame_end
end

def subscribe_frame(identifier: String) -> String
  return JSON.encode({"command": "subscribe", "identifier": identifier})
end

def test_an_identifier_of_the_limit_is_read() -> Result[Void]
  identifier = padded_identifier(Protocol.MAX_IDENTIFIER_BYTES)
  try Test.eq(identifier.bytes.length, Protocol.MAX_IDENTIFIER_BYTES)
  return Test.ok?(Protocol.decode_command(subscribe_frame(identifier)))
end

def test_a_longer_identifier_is_ignored() -> Result[Void]
  identifier = padded_identifier(Protocol.MAX_IDENTIFIER_BYTES + 1)
  return Test.error?(Protocol.decode_command(subscribe_frame(identifier)))
end
