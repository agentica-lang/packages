import Handshake from "../src/handshake"
import Types from "../src/types"
import Wire from "../src/wire"

private

COOKIE = "0123456789abcdef-cookie"
CLIENT_NONCE = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
SERVER_NONCE = "6465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f80818283"
# HMAC-SHA256 of the transcript of each role with COOKIE, worked out once with Python's hmac module.
SERVER_PROOF = "098d13838e49805392f7e8cc2205cdd7a128ff9a484d52ed06703630c9f7f648"
CLIENT_PROOF = "7cfd4793fba3a3380878d326cfcec934954c42143fc63840c2caa604da7674a5"

def name_of(length: Int) -> String = (1..length).map { |_| "a" }.join("")

def bytes_of(text: String) -> Bytes = OpenSSL.Digest.hexdecode(text).unwrap!

def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

def kind_of[T](result: Result[T]) -> String
  case result
    ok(_) -> ""
    error(e) -> e.kind
  end
end

def session() -> Handshake.Session
  Handshake.session("alpha", "beta", bytes_of(CLIENT_NONCE), bytes_of(SERVER_NONCE)).unwrap!
end

def cookie() -> Bytes = Handshake.cookie(COOKIE).unwrap!

# The Term CBOR of a map of six fields (a6) written by hand: the protocol "agcn1", the role, the two names, and the
# two nonces, each a byte string of 32 bytes (5820).
def transcript_of(role: String) -> String
  (
    "a6" +
    "68" +
    "70726f746f636f6c" +
    "65" +
    "6167636e31" +
    "64" +
    "726f6c65" +
    role +
    "66" +
    "636c69656e74" +
    "65" +
    "616c706861" +
    "66" +
    "736572766572" +
    "64" +
    "62657461" +
    "6c" +
    "636c69656e745f6e6f6e6365" +
    "5820" +
    CLIENT_NONCE +
    "6c" +
    "7365727665725f6e6f6e6365" +
    "5820" +
    SERVER_NONCE
  )
end

def test_the_transcript_of_each_role_is_the_cbor_of_its_fields() -> Result[Void]
  try Test.eq(hex(Handshake.transcript("server", session())), transcript_of("66736572766572"))
  Test.eq(hex(Handshake.transcript("client", session())), transcript_of("66636c69656e74"))
end

def test_the_challenge_carries_the_server_proof() -> Result[Void]
  case Handshake.challenge(cookie(), session())
    Types.Message.Challenge(node, nonce, proof) ->
      try Test.eq(node, "beta")
      try Test.eq(hex(nonce), SERVER_NONCE)
      Test.eq(hex(proof), SERVER_PROOF)
    _ -> Test.assert(false, "the answer to a hello is a challenge")
  end
end

def test_the_client_answers_with_its_proof_once_the_server_proof_is_right() -> Result[Void]
  answer = try Handshake.answer(cookie(), session(), bytes_of(SERVER_PROOF))
  Test.eq(answer, Types.Message.Proof(bytes_of(CLIENT_PROOF)))
end

def test_the_client_refuses_a_server_proof_that_is_wrong_or_is_its_own() -> Result[Void]
  try Test.eq(kind_of(Handshake.answer(cookie(), session(), bytes_of(CLIENT_PROOF))), Types.REFUSED)
  try Test.eq(kind_of(Handshake.answer(cookie(), session(), bytes_of("00"))), Types.REFUSED)
  Test.eq(kind_of(Handshake.answer(cookie(), session(), "".bytes)), Types.REFUSED)
end

def test_the_server_welcomes_the_proof_of_the_client() -> Result[Void]
  try Test.eq(try Handshake.accept(cookie(), session(), bytes_of(CLIENT_PROOF)), Types.Message.Welcome)
  try Test.eq(kind_of(Handshake.accept(cookie(), session(), bytes_of(SERVER_PROOF))), Types.REFUSED)
  Test.eq(kind_of(Handshake.accept(cookie(), session(), bytes_of(CLIENT_NONCE))), Types.REFUSED)
end

def test_another_cookie_gives_other_proofs() -> Result[Void]
  other = try Handshake.cookie("another-cookie-of-16-bytes-or-more")
  try Test.eq(kind_of(Handshake.answer(other, session(), bytes_of(SERVER_PROOF))), Types.REFUSED)
  Test.eq(kind_of(Handshake.accept(other, session(), bytes_of(CLIENT_PROOF))), Types.REFUSED)
end

def test_a_cookie_has_at_least_16_bytes() -> Result[Void]
  try Test.eq(kind_of(Handshake.cookie("short")), Types.ARGUMENT)
  try Test.eq(kind_of(Handshake.cookie("")), Types.ARGUMENT)
  try Test.eq(kind_of(Handshake.cookie("123456789012345")), Types.ARGUMENT)
  Test.ok?(Handshake.cookie("1234567890123456"))
end

def test_a_session_needs_two_names_and_two_different_nonces() -> Result[Void]
  one = bytes_of(CLIENT_NONCE)
  other = bytes_of(SERVER_NONCE)
  try Test.ok?(Handshake.session("a", "b", one, other))
  try Test.eq(kind_of(Handshake.session("a", "a", one, other)), Types.REFUSED)
  try Test.eq(kind_of(Handshake.session("A", "b", one, other)), Types.PROTOCOL)
  try Test.eq(kind_of(Handshake.session("a", "", one, other)), Types.PROTOCOL)
  try Test.eq(kind_of(Handshake.session("a", "b", one.take(31), other)), Types.PROTOCOL)
  try Test.eq(kind_of(Handshake.session("a", "b", one, other + other)), Types.PROTOCOL)
  Test.eq(kind_of(Handshake.session("a", "b", one, one)), Types.PROTOCOL)
end

def test_an_error_does_not_repeat_what_the_peer_wrote() -> Result[Void]
  nonce = bytes_of(CLIENT_NONCE)
  other = bytes_of(SERVER_NONCE)
  case Handshake.session("Peer-controlled-name", "b", nonce, other)
    ok(_) -> Test.assert(false, "a name with upper case letters is refused")
    error(e) -> Test.assert(not e.message.include?("Peer-controlled-name"), "the message repeats the name")
  end
end

def test_a_node_that_answers_under_another_name_fails_the_proof() -> Result[Void]
  # The client dialed "beta"; the node that answers calls itself "gamma" and signs a transcript with that name.
  answering = try Handshake.session("alpha", "gamma", bytes_of(CLIENT_NONCE), bytes_of(SERVER_NONCE))
  proof = case Handshake.challenge(cookie(), answering)
    Types.Message.Challenge(_, _, p) -> p
    _ -> "".bytes
  end

  Test.eq(kind_of(Handshake.answer(cookie(), session(), proof)), Types.REFUSED)
end

def test_every_frame_of_the_handshake_fits_before_the_welcome() -> Result[Void]
  name = name_of(63)
  nonce = bytes_of(CLIENT_NONCE)
  proof = bytes_of(SERVER_PROOF)
  messages = [
    Types.Message.Hello(name, nonce),
    Types.Message.Challenge(name, bytes_of(SERVER_NONCE), proof),
    Types.Message.Proof(proof),
    Types.Message.Welcome,
  ]

  for message in messages
    frame = try Wire.encode(message, Types.PRE_AUTH_MAX_FRAME_BYTES)
    try Test.assert(frame.size - 4 <= Types.PRE_AUTH_MAX_FRAME_BYTES, "a frame of the handshake is too big")
  end

  ok()
end

def test_a_nonce_has_32_bytes_and_is_new_each_time() -> Result[Void]
  try Test.eq(Handshake.fresh_nonce().size, 32)
  Test.eq(Handshake.fresh_nonce() == Handshake.fresh_nonce(), false)
end
