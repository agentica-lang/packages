## The steps of the signed stream names (`turbo.feature`): the vectors of `fixtures/turbo_vectors.json`, which Rails
## made (`Turbo.signed_stream_verifier` of turbo-rails, from the vectors of once-campfire-rust), against
## `src/signing.agc`.

import BDD from "std/bdd"
import Signing from "../src/signing"

def steps() -> List[BDD.Step]
  [
    BDD.step("the stream key of the secret of the vectors is the key of Rails", &key_is_rails_key),
    BDD.step("an empty secret makes no stream key", &empty_secret_has_no_key),
    BDD.step("every name that Rails signed is signed the same here and read back", &generates_as_rails),
    BDD.step("every signed name of the vectors verifies as it did in Rails", &verifies_as_rails),
  ]
end

private

# Relative to the working directory of the run, which is the package folder (`make test`).
VECTORS = "specs/fixtures/turbo_vectors.json"

def vectors() -> JSON.Value = JSON.parse(File.read_text(VECTORS).unwrap!).unwrap!

def field(value: JSON.Value, name: String) -> JSON.Value = JSON.get(value, name).unwrap!

def text(value: JSON.Value, name: String) -> String = JSON.string(field(value, name)).unwrap!

def rows(name: String) -> List[JSON.Value] = JSON.list(field(vectors(), name)).unwrap!

def key() -> Bytes = Signing.stream_key(text(vectors(), "secret_key_base")).unwrap!

# A vector whose `expected` is not a string (null, or the number that Rails reads back as 42) is refused here.
def expected_name(row: JSON.Value) -> Optional[String]
  case JSON.string(field(row, "expected"))
    ok(name) -> some(name)
    error(_) -> none
  end
end

def key_is_rails_key(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  expected = OpenSSL.Digest.hexdecode(text(vectors(), "key_hex")).unwrap!
  BDD.assert(
    ctx,
    key() == expected,
    "the key is #{OpenSSL.Digest.hexencode(key())}, expected #{OpenSSL.Digest.hexencode(expected)}",
  )
end

def empty_secret_has_no_key(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  BDD.assert(ctx, not Signing.stream_key("").ok?, "an empty secret made a key")
end

# Every generated name is also read back, so that what `signed_stream_name` writes is what
# `verified_stream_name` takes.
def generates_as_rails(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  result = ctx
  for row in rows("generate")
    name = text(row, "stream_name")
    signed = Signing.signed_stream_name(key(), name)
    result = BDD.assert(
      result,
      signed == text(row, "signed"),
      "#{name} was signed as #{signed}, expected #{text(row, "signed")}",
    )

    result = BDD.assert(result, Signing.verified_stream_name(key(), signed) == some(name), "#{name} did not read back")
  end

  result
end

def verifies_as_rails(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  result = ctx
  for row in rows("verify")
    actual = Signing.verified_stream_name(key(), text(row, "signed"))
    result = BDD.assert(
      result,
      actual == expected_name(row),
      "#{text(row, "case")}: got #{actual}, expected #{expected_name(row)}",
    )
  end

  result
end
