## The handshake of two nodes that share a cookie, as pure functions: the cookie is never sent. Each side proves that
## it knows it with the HMAC-SHA256 of a transcript that holds both names and both nonces, and each role signs the
## transcript with its own label, so a proof cannot be sent back to the node that made it. A nonce is new for each
## connection, so a proof of an earlier one means nothing.
##
## The client writes `Hello` (its name and a nonce), the server answers `Challenge` (its name, its nonce and its
## proof), the client checks that and writes `Proof`, and the server checks that and writes `Welcome`. The caller
## holds the `Session` of the names and nonces, and sends the messages (src/wire.agc) over a socket.

import Names from "names"
import Types from "types"

## The cookie of the options, as bytes: at least 16 of them, so a proof that a listener saw cannot be guessed offline
## (`openssl rand -hex 32` makes a good one).
def cookie(text: String) -> Result[Bytes]
  if text.bytes.size < Types.MIN_COOKIE_BYTES
    return error(
      "cluster: the cookie has #{text.bytes.size} bytes, and it needs #{Types.MIN_COOKIE_BYTES} at least",
      kind: Types.ARGUMENT,
    )
  end

  ok(text.bytes)
end

## A new nonce, from the random generator of OpenSSL.
def fresh_nonce() -> Bytes = OpenSSL.Random.random_bytes(Types.NONCE_BYTES)

## The names and nonces of one connection. Both names must be valid and different (a node never connects to itself),
## and a nonce has 32 bytes: what a peer wrote is checked with the same function.
def session(client: String, server: String, client_nonce: Bytes, server_nonce: Bytes) -> Result[Types.Session]
  return protocol("the node name #{client} is not valid") if not Names.node_name?(client)
  return protocol("the node name #{server} is not valid") if not Names.node_name?(server)
  return protocol("a nonce has #{Types.NONCE_BYTES} bytes") if client_nonce.size != Types.NONCE_BYTES
  return protocol("a nonce has #{Types.NONCE_BYTES} bytes") if server_nonce.size != Types.NONCE_BYTES
  return refused("the node #{client} is the name of this node too") if client == server

  ok(Types.Session(client: client, server: server, client_nonce: client_nonce, server_nonce: server_nonce))
end

## The bytes that a proof signs: the Term CBOR of the protocol, the label of the role (`server` or `client`), the two
## names and the two nonces.
def transcript(role: String, session: Types.Session) -> Bytes
  Term.encode(
    Transcript(
      protocol: PROTOCOL,
      role: role,
      client: session.client,
      server: session.server,
      client_nonce: session.client_nonce,
      server_nonce: session.server_nonce,
    ),
  ).unwrap!
end

## What the server answers to a hello: its name, its nonce and its proof.
def challenge(cookie: Bytes, session: Types.Session) -> Types.Message
  Types.Message.Challenge(session.server, session.server_nonce, proof(cookie, SERVER, session))
end

## What the client writes after a challenge: its own proof, when the proof of the server is right.
def answer(cookie: Bytes, session: Types.Session, server_proof: Bytes) -> Result[Types.Message]
  return refused("the node does not know the cookie") if not right?(cookie, SERVER, session, server_proof)

  ok(Types.Message.Proof(proof(cookie, CLIENT, session)))
end

## What the server writes after a proof: `Welcome`, when the proof of the client is right.
def accept(cookie: Bytes, session: Types.Session, client_proof: Bytes) -> Result[Types.Message]
  return refused("the node does not know the cookie") if not right?(cookie, CLIENT, session, client_proof)

  ok(Types.Message.Welcome)
end

private

PROTOCOL = "agcn1"
SERVER = "server"
CLIENT = "client"

struct Transcript
  protocol: String
  role: String
  client: String
  server: String
  client_nonce: Bytes
  server_nonce: Bytes
end

def protocol[T](message: String) -> Result[T] = error("cluster: #{message}", kind: Types.PROTOCOL)

def refused[T](message: String) -> Result[T] = error("cluster: #{message}", kind: Types.REFUSED)

def proof(cookie: Bytes, role: String, session: Types.Session) -> Bytes
  OpenSSL.HMAC.sha256(cookie, transcript(role, session))
end

def right?(cookie: Bytes, role: String, session: Types.Session, given: Bytes) -> Bool
  OpenSSL.HMAC.secure_compare(proof(cookie, role, session), given)
end
