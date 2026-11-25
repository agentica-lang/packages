## The steps of `password.feature`. The package runs in the step itself; the peer (`fixtures/scrypt_peer.py`, Python's
## scrypt) is a program that a step runs for its answer, and `fixtures/golden.json` is what the peer made.

import BDD from "std/bdd"
import Password from "../password"

def main() -> Void
  BDD.run([
    BDD.step("I hash {string}", &hash_one),
    BDD.step("I hash {string} twice", &hash_twice),
    BDD.step("the golden digest {string}", &golden),
    BDD.step("I ask what is wrong with {int} copies of {string}", &ask_problem),
    BDD.step("I time a hash and a check against nobody", &time_nobody),
    BDD.step("the digest starts with {string}", &digest_starts),
    BDD.step("the digest does not contain {string}", &digest_lacks),
    BDD.step("the password {string} verifies against the digest", &verifies),
    BDD.step("the password {string} does not verify against the digest", &does_not_verify),
    BDD.step("the two digests differ", &digests_differ),
    BDD.step("both verify {string}", &both_verify),
    BDD.step("its password verifies against it", &golden_verifies),
    BDD.step("{string} does not verify against it", &golden_rejects),
    BDD.step("the peer says the digest matches {string}", &peer_matches),
    BDD.step("the peer says the digest does not match {string}", &peer_mismatches),
    BDD.step("verifying against the digest {string} is an error", &verify_is_error),
    BDD.step("the answer mentions {string}", &answer_mentions),
    BDD.step("the answer is empty", &answer_empty),
    BDD.step("hashing {int} copies of {string} is an error", &hashing_is_error),
    BDD.step(
      "verifying {int} copies of {string} against the digest {string} is false in under {int} milliseconds",
      &long_verify_is_false,
    ),
    BDD.step("the check against nobody took at least half of the time of the hash", &nobody_took_half),
  ])
end

private

PEER = "specs/fixtures/scrypt_peer.py"
GOLDEN = "specs/fixtures/golden.json"
PEER_MS = 60_000
DIGEST = "digest"
DIGEST_TWO = "digest_two"
GOLDEN_PASSWORD = "golden_password"
ANSWER = "answer"
HASH_MS = "hash_ms"
NOBODY_MS = "nobody_ms"

struct Vector
  name: String
  password: String
  digest: String
end

def hash_one(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, DIGEST, JSON.from(Password.hash(args[0]).unwrap!))
end

def hash_twice(ctx: BDD.Context, args: List[String]) -> BDD.Context
  first = BDD.set(ctx, DIGEST, JSON.from(Password.hash(args[0]).unwrap!))
  BDD.set(first, DIGEST_TWO, JSON.from(Password.hash(args[0]).unwrap!))
end

def golden(ctx: BDD.Context, args: List[String]) -> BDD.Context
  text = File.read_text(GOLDEN).unwrap!
  vectors = JSON.decode(text, List[Vector]).unwrap!
  found = vectors.find do |vector| vector.name == args[0] end
  return BDD.assert(ctx, false, "no golden digest named #{args[0].inspect}") if not found.ok?

  BDD.set(BDD.set(ctx, DIGEST, JSON.from(found.unwrap!.digest)), GOLDEN_PASSWORD, JSON.from(found.unwrap!.password))
end

def ask_problem(ctx: BDD.Context, args: List[String]) -> BDD.Context
  text = List.repeat(args[1], args[0].to_i!).join("")
  BDD.set(ctx, ANSWER, JSON.from(Password.problem(text)))
end

# The check against nobody must do the work of a hash, so it is timed against one: a check that skipped the work (the
# result is ignored, so a version that dropped the call would pass every other test) takes a fraction of it.
def time_nobody(ctx: BDD.Context, args: List[String]) -> BDD.Context
  started = Time.now_ms()
  Password.hash("a password to time").unwrap!
  hashed = Time.now_ms() - started
  started = Time.now_ms()
  Password.verify_nobody()
  nobody = Time.now_ms() - started
  BDD.set(BDD.set(ctx, HASH_MS, JSON.from(hashed)), NOBODY_MS, JSON.from(nobody))
end

def digest_starts(ctx: BDD.Context, args: List[String]) -> BDD.Context
  digest = text_of(ctx, DIGEST)
  BDD.assert(ctx, digest.start_with?(args[0]), "the digest is #{digest}")
end

def digest_lacks(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.assert(ctx, not text_of(ctx, DIGEST).include?(args[0]), "the digest holds #{args[0].inspect}")
end

def verifies(ctx: BDD.Context, args: List[String]) -> BDD.Context
  verdict = Password.verify(args[0], text_of(ctx, DIGEST))
  BDD.assert(ctx, verdict == ok(true), "verify gave #{verdict}")
end

def does_not_verify(ctx: BDD.Context, args: List[String]) -> BDD.Context
  verdict = Password.verify(args[0], text_of(ctx, DIGEST))
  BDD.assert(ctx, verdict == ok(false), "verify gave #{verdict}")
end

def digests_differ(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.assert(ctx, text_of(ctx, DIGEST) != text_of(ctx, DIGEST_TWO), "the two digests are the same")
end

def both_verify(ctx: BDD.Context, args: List[String]) -> BDD.Context
  first = Password.verify(args[0], text_of(ctx, DIGEST))
  second = Password.verify(args[0], text_of(ctx, DIGEST_TWO))
  BDD.assert(ctx, first == ok(true) and second == ok(true), "verify gave #{first} and #{second}")
end

def golden_verifies(ctx: BDD.Context, args: List[String]) -> BDD.Context
  verdict = Password.verify(text_of(ctx, GOLDEN_PASSWORD), text_of(ctx, DIGEST))
  BDD.assert(ctx, verdict == ok(true), "verify gave #{verdict} for #{text_of(ctx, DIGEST)}")
end

def golden_rejects(ctx: BDD.Context, args: List[String]) -> BDD.Context
  verdict = Password.verify(args[0], text_of(ctx, DIGEST))
  BDD.assert(ctx, verdict == ok(false), "verify gave #{verdict}")
end

def peer_matches(ctx: BDD.Context, args: List[String]) -> BDD.Context
  said = peer_says(args[0], text_of(ctx, DIGEST))
  BDD.assert(ctx, said == "match", "the peer said #{said.inspect}")
end

def peer_mismatches(ctx: BDD.Context, args: List[String]) -> BDD.Context
  said = peer_says(args[0], text_of(ctx, DIGEST))
  BDD.assert(ctx, said == "mismatch", "the peer said #{said.inspect}")
end

def peer_says(password: String, digest: String) -> String
  peer = Process.spawn_captured(
    "python3",
    ["-I", PEER, "check", password, digest],
    Process.Options(timeout_ms: PEER_MS),
  )

  output = Process.output(peer.unwrap!, PEER_MS).unwrap!
  output.stdout.strip
end

def verify_is_error(ctx: BDD.Context, args: List[String]) -> BDD.Context
  verdict = Password.verify("any password", args[0])
  BDD.assert(ctx, not verdict.ok?, "verify gave #{verdict}")
end

def answer_mentions(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.assert(ctx, text_of(ctx, ANSWER).include?(args[0]), "the answer is #{text_of(ctx, ANSWER).inspect}")
end

def answer_empty(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.assert(ctx, text_of(ctx, ANSWER) == "", "the answer is #{text_of(ctx, ANSWER).inspect}")
end

def hashing_is_error(ctx: BDD.Context, args: List[String]) -> BDD.Context
  hashed = Password.hash(List.repeat(args[1], args[0].to_i!).join(""))
  BDD.assert(ctx, not hashed.ok?, "hash gave a digest")
end

# A digest that would take seconds if it were hashed, so that a quick answer shows that nothing was.
def long_verify_is_false(ctx: BDD.Context, args: List[String]) -> BDD.Context
  started = Time.now_ms()
  verdict = Password.verify(List.repeat(args[1], args[0].to_i!).join(""), args[2])
  took = Time.now_ms() - started
  BDD.assert(ctx, verdict == ok(false) and took < args[3].to_i!, "verify gave #{verdict} after #{took} ms")
end

def nobody_took_half(ctx: BDD.Context, args: List[String]) -> BDD.Context
  hashed = JSON.int(BDD.get(ctx, HASH_MS).unwrap!).unwrap!
  nobody = JSON.int(BDD.get(ctx, NOBODY_MS).unwrap!).unwrap!
  BDD.assert(ctx, nobody * 2 >= hashed, "the check against nobody took #{nobody} ms and the hash #{hashed} ms")
end

def text_of(ctx: BDD.Context, name: String) -> String = JSON.string(BDD.get(ctx, name).unwrap!).unwrap!
