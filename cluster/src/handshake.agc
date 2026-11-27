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

## The names and the nonces of one connection, which both proofs bind. Only `session` makes one, so every one has
## valid names that differ and two nonces that differ.
struct Session
  private

  client: String
  server: String
  client_nonce: Bytes
  server_nonce: Bytes
end

## The cookie of the options, as bytes. It needs 16 at least: a floor, not a measure of strength. A listener that saw
## one proof can try guesses offline, so the cookie should be a random secret (`openssl rand -hex 32`).
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
## and the nonces have 32 bytes and differ: what a peer wrote is checked with the same function. A client that dialed
## a node by its name passes that name as `server`, never the one in the challenge, so a node that answers under
## another name fails the proof.
def session(client: String, server: String, client_nonce: Bytes, server_nonce: Bytes) -> Result[Session]
  return protocol("the node name or the nonce is not valid") if not Names.peer?(client, client_nonce)
  return protocol("the node name or the nonce is not valid") if not Names.peer?(server, server_nonce)
  return protocol("the two nonces are the same") if client_nonce == server_nonce
  return refused("a node cannot connect to a node with its own name") if client == server

  ok(Session(client: client, server: server, client_nonce: client_nonce, server_nonce: server_nonce))
end

## The bytes that a proof signs: the Term CBOR of the protocol, the label of the role (`server` or `client`), the two
## names and the two nonces.
def transcript(role: String, session: Session) -> Bytes
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
def challenge(cookie: Bytes, session: Session) -> Types.Message
  Types.Message.Challenge(session.server, session.server_nonce, proof(cookie, SERVER, session))
end

## What the client writes after a challenge: its own proof, when the proof of the server is right.
def answer(cookie: Bytes, session: Session, server_proof: Bytes) -> Result[Types.Message]
  return refused("the node does not know the cookie") if not right?(cookie, SERVER, session, server_proof)

  ok(Types.Message.Proof(proof(cookie, CLIENT, session)))
end

## What the server writes after a proof: `Welcome`, when the proof of the client is right.
def accept(cookie: Bytes, session: Session, client_proof: Bytes) -> Result[Types.Message]
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

def proof(cookie: Bytes, role: String, session: Session) -> Bytes
  OpenSSL.HMAC.sha256(cookie, transcript(role, session))
end

def right?(cookie: Bytes, role: String, session: Session, given: Bytes) -> Bool
  OpenSSL.HMAC.secure_compare(proof(cookie, role, session), given)
end
