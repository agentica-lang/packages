## The steps of the signed stream names (`turbo.feature`): the vectors of `fixtures/turbo_vectors.json`, which Rails
## made (`Turbo.signed_stream_verifier` of turbo-rails, from the vectors of once-campfire-rust), against
## `src/signing.agc`.

import BDD from "std/bdd"
import Signing from "../src/signing"

# Relative to the working directory of the run, which is the package folder (`make test`).
VECTORS = "specs/fixtures/turbo_vectors.json"

export def steps() -> List[BDD.Step]
  return [
    BDD.step("the stream key of the secret of the vectors is the key of Rails", &key_is_rails_key),
    BDD.step("an empty secret makes no stream key", &empty_secret_has_no_key),
    BDD.step("every name that Rails signed is signed the same here and read back", &generates_as_rails),
    BDD.step("every signed name of the vectors verifies as it did in Rails", &verifies_as_rails),
  ]
end

def vectors() -> Json
  return JSON.parse(File.read_text(VECTORS).unwrap!).unwrap!
end

def field(value: Json, name: String) -> Json
  return JSON.get(value, name).unwrap!
end

def text(value: Json, name: String) -> String
  return JSON.string(field(value, name)).unwrap!
end

def rows(name: String) -> List[Json]
  return JSON.list(field(vectors(), name)).unwrap!
end

def key() -> Bytes
  return Signing.stream_key(text(vectors(), "secret_key_base")).unwrap!
end

# A vector whose `expected` is not a string (null, or the number that Rails reads back as 42) is refused here.
def expected_name(row: Json) -> Optional[String]
  case JSON.string(field(row, "expected"))
    ok(name) -> return some(name)
    error(_) -> return none
  end
end

def key_is_rails_key(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  expected = OpenSSL.Digest.hexdecode(text(vectors(), "key_hex")).unwrap!
  return BDD.assert(
    ctx,
    key() == expected,
    "the key is #{OpenSSL.Digest.hexencode(key())}, expected #{OpenSSL.Digest.hexencode(expected)}",
  )
end

def empty_secret_has_no_key(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return BDD.assert(ctx, not Signing.stream_key("").ok?, "an empty secret made a key")
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

  return result
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

  return result
end
