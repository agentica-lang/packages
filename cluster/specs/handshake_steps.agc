## The steps of handshake.feature. A node is a name and a cookie, and a connection runs the pure functions of
## `src/handshake.agc` from both sides in one step, as a socket would carry the messages. What each node decided is
## kept in the context: `accepted:A:B` or `refused:A:B` is what the node A decided about the node B.

import BDD from "std/bdd"
import Handshake from "../src/handshake"
import Types from "../src/types"

def steps() -> List[BDD.Step]
  [
    BDD.step("the node {string} and the node {string} have the cookie {string}", &two_nodes_have_cookie),
    BDD.step("the node {string} has the cookie {string}", &node_has_cookie),
    BDD.step("{string} connects to {string}", &connects),
    BDD.step("{string} connected to {string} earlier", &connected_earlier),
    BDD.step("{string} dials {string} and {string} answers", &answers_as_another),
    BDD.step("{string} answers {string} without checking its proof", &answers_unchecked),
    BDD.step("a stranger connects to {string} and sends the answer of that earlier connection", &replays),
    BDD.step("a stranger connects to {string} and sends back the proof that {string} made", &reflects),
    BDD.step("a stranger connects to {string} and sends a proof of its own", &guesses),
    BDD.step("{string} accepts {string}", &accepts),
    BDD.step("{string} refuses {string}", &refuses),
    BDD.step("{string} refuses the stranger", &refuses_stranger),
    BDD.step("a node is given the cookie {string}", &given_cookie),
    BDD.step("the cookie is accepted", &cookie_accepted),
    BDD.step("the cookie is refused", &cookie_refused),
    BDD.step("the node {string} connects to the node {string}", &names_connect),
    BDD.step("the connection is refused", &connection_refused),
  ]
end

private

STRANGER = "stranger"
CAPTURED = "captured"
COOKIE_OUTCOME = "cookie"
SESSION_OUTCOME = "session"

def cookie_of(ctx: BDD.Context, node: String) -> Bytes
  Handshake.cookie(JSON.string(BDD.get(ctx, "cookie:#{node}").unwrap!).unwrap!).unwrap!
end

def keep_cookie(ctx: BDD.Context, node: String, cookie: String) -> BDD.Context
  BDD.set(ctx, "cookie:#{node}", JSON.from(cookie))
end

def two_nodes_have_cookie(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_cookie(keep_cookie(ctx, args[0], args[2]), args[1], args[2])
end

def node_has_cookie(ctx: BDD.Context, args: List[String]) -> BDD.Context = keep_cookie(ctx, args[0], args[1])

def decide(ctx: BDD.Context, by: String, whom: String, accepted: Bool) -> BDD.Context
  verdict = "refused"
  if accepted
    verdict = "accepted"
  end

  BDD.set(ctx, "#{verdict}:#{by}:#{whom}", JSON.from(true))
end

def decided?(ctx: BDD.Context, verdict: String, by: String, whom: String) -> Bool
  BDD.get(ctx, "#{verdict}:#{by}:#{whom}").ok?
end

def new_session(client: String, server: String) -> Handshake.Session
  Handshake.session(client, server, Handshake.fresh_nonce(), Handshake.fresh_nonce()).unwrap!
end

# The proof of the challenge that the server writes.
def server_proof(server_cookie: Bytes, session: Handshake.Session) -> Bytes
  case Handshake.challenge(server_cookie, session)
    Types.Message.Challenge(_, _, proof) -> proof
    _ -> "".bytes
  end
end

def proof_of(message: Result[Types.Message]) -> Bytes
  case message
    ok(Types.Message.Proof(proof)) -> proof
    _ -> "".bytes
  end
end

# The client checks the server and answers; the server checks the answer. A node whose proof the other refused never
# gets to the next step, as on a socket.
def connect(ctx: BDD.Context, client: String, server: String) -> BDD.Context
  session = new_session(client, server)
  client_cookie = cookie_of(ctx, client)
  server_cookie = cookie_of(ctx, server)
  answer = Handshake.answer(client_cookie, session, server_proof(server_cookie, session))
  return decide(ctx, client, server, false) if not answer.ok?

  welcomed = Handshake.accept(server_cookie, session, proof_of(answer))
  decide(decide(ctx, client, server, true), server, client, welcomed.ok?)
end

def connects(ctx: BDD.Context, args: List[String]) -> BDD.Context = connect(ctx, args[0], args[1])

def connected_earlier(ctx: BDD.Context, args: List[String]) -> BDD.Context
  session = new_session(args[0], args[1])
  answer = Handshake.answer(cookie_of(ctx, args[0]), session, server_proof(cookie_of(ctx, args[1]), session))
  BDD.set(ctx, CAPTURED, JSON.from(OpenSSL.Digest.hexencode(proof_of(answer))))
end

# The client skips the check of the server's proof: it signs with its own cookie what a server of the same cookie
# would have said, which is the proof that a node without the cookie could make.
def answers_unchecked(ctx: BDD.Context, args: List[String]) -> BDD.Context
  session = new_session(args[0], args[1])
  own = cookie_of(ctx, args[0])
  answer = Handshake.answer(own, session, server_proof(own, session))
  welcomed = Handshake.accept(cookie_of(ctx, args[1]), session, proof_of(answer))
  decide(ctx, args[1], args[0], welcomed.ok?)
end

# The client dialed `expected` and builds its session with that name; the node that answers signs with its own.
def answers_as_another(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client_nonce = Handshake.fresh_nonce()
  server_nonce = Handshake.fresh_nonce()
  answering = Handshake.session(args[0], args[2], client_nonce, server_nonce).unwrap!
  expected = Handshake.session(args[0], args[1], client_nonce, server_nonce).unwrap!
  proof = server_proof(cookie_of(ctx, args[2]), answering)
  answer = Handshake.answer(cookie_of(ctx, args[0]), expected, proof)
  decide(ctx, args[0], args[1], answer.ok?)
end

def stranger_sends(
  ctx: BDD.Context,
  server: String,
  as_name: String,
  send: Fn[Handshake.Session, Bytes],
) -> BDD.Context
  session = new_session(as_name, server)
  welcomed = Handshake.accept(cookie_of(ctx, server), session, send.call(session))
  decide(ctx, server, STRANGER, welcomed.ok?)
end

def replays(ctx: BDD.Context, args: List[String]) -> BDD.Context
  captured = OpenSSL.Digest.hexdecode(JSON.string(BDD.get(ctx, CAPTURED).unwrap!).unwrap!).unwrap!
  stranger_sends(ctx, args[0], "alpha", ->(_) { captured })
end

def reflects(ctx: BDD.Context, args: List[String]) -> BDD.Context
  server_cookie = cookie_of(ctx, args[1])
  stranger_sends(ctx, args[0], "alpha", ->(session) { server_proof(server_cookie, session) })
end

def guesses(ctx: BDD.Context, args: List[String]) -> BDD.Context
  stranger_sends(ctx, args[0], "alpha", ->(_) { OpenSSL.Random.random_bytes(Types.PROOF_BYTES) })
end

def accepts(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.assert(ctx, decided?(ctx, "accepted", args[0], args[1]), "#{args[0]} did not accept #{args[1]}")
end

def refuses(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.assert(ctx, decided?(ctx, "refused", args[0], args[1]), "#{args[0]} did not refuse #{args[1]}")
end

def refuses_stranger(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.assert(ctx, decided?(ctx, "refused", args[0], STRANGER), "#{args[0]} did not refuse the stranger")
end

def given_cookie(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, COOKIE_OUTCOME, JSON.from(Handshake.cookie(args[0]).ok?))
end

def cookie_accepted(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  BDD.assert(ctx, JSON.bool(BDD.get(ctx, COOKIE_OUTCOME).unwrap!).unwrap!, "the cookie was refused")
end

def cookie_refused(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  BDD.assert(ctx, not JSON.bool(BDD.get(ctx, COOKIE_OUTCOME).unwrap!).unwrap!, "the cookie was accepted")
end

def names_connect(ctx: BDD.Context, args: List[String]) -> BDD.Context
  made = Handshake.session(args[0], args[1], Handshake.fresh_nonce(), Handshake.fresh_nonce())
  BDD.set(ctx, SESSION_OUTCOME, JSON.from(made.ok?))
end

def connection_refused(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  made = JSON.bool(BDD.get(ctx, SESSION_OUTCOME).unwrap!).unwrap!
  BDD.assert(ctx, not made, "the connection was not refused")
end
