## Password hashing with scrypt. A digest is one text, `scrypt$N$r$p$salt$key` (salt and key in base64), so it carries
## the cost that made it and `verify` still works after the cost is raised for new passwords.

import Digest from "src/digest"

## The fewest characters of a new password.
MIN_LENGTH = 8
## The most bytes of a password. `hash` and `verify` refuse a longer one without hashing it.
MAX_BYTES = 256

## What is wrong with `password` as a new password, or "" when it is fine.
def problem(password: String) -> String
  return "The password needs at least #{MIN_LENGTH} characters" if password.length < MIN_LENGTH

  return "The password can have at most #{MAX_BYTES} bytes" if password.bytes.size > MAX_BYTES

  ""
end

## The digest of `password` with a new random salt. It never holds the password. It does not call `problem` (a caller
## that takes a new password checks it first), and it hashes the password as it is given. A password of more than
## `MAX_BYTES` bytes is an `error`.
def hash(password: String) -> Result[String]
  return error("password: more than #{MAX_BYTES} bytes") if password.bytes.size > MAX_BYTES

  salt = OpenSSL.Random.random_bytes(SALT_BYTES)
  key = try OpenSSL.KDF.scrypt(password.bytes, salt, COST, BLOCK_SIZE, PARALLELISM, KEY_BYTES)
  ok(Digest.write(Digest.Parts(cost: COST, block_size: BLOCK_SIZE, parallelism: PARALLELISM, salt: salt, key: key)))
end

## Whether `password` is the one that made `digest`. The keys are compared in constant time, and the digest names the
## cost, so a digest made with another cost verifies too. A password of more than `MAX_BYTES` bytes is false without
## any hashing. A digest that is not one of this package, or whose cost, salt or key is out of the bounds of a digest
## that `hash` could have made (at most 256 MiB of memory), is an `error`: it says nothing
## about the password.
def verify(password: String, digest: String) -> Result[Bool]
  parts = try Digest.parse(digest)
  return ok(false) if password.bytes.size > MAX_BYTES

  key = OpenSSL.KDF.scrypt(password.bytes, parts.salt, parts.cost, parts.block_size, parts.parallelism, parts.key.size)

  return error("password: the system refuses the cost of the digest: #{key.message}") if not key.ok?

  ok(OpenSSL.HMAC.secure_compare(key.unwrap!, parts.key))
end

## Does the work of `hash` for a password that nobody has. A sign-in calls it for a user that does not exist, so that
## the time does not tell whether the user is registered. A digest made with another cost takes the time of its own cost,
## not this one.
def verify_nobody() -> Void
  # The key is dropped on purpose (`_ =` is how a `Result` is discarded): the call is made for its time. It runs to its
  # end whether or not the result is read, which the spec checks by timing it against `hash`.
  _ = OpenSSL.KDF.scrypt(NOBODY_PASSWORD.bytes, NOBODY_SALT.bytes, COST, BLOCK_SIZE, PARALLELISM, KEY_BYTES)
end

private

# OWASP's scrypt setting for a cost of 2^16 (64 MiB of memory) with two lanes. The call runs to its end on the compute
# pool, so this is the time one sign-in takes of it; an app that signs many people in at once bounds how many run, for
# their memory.
COST = 65_536
BLOCK_SIZE = 8
PARALLELISM = 2
KEY_BYTES = 32
SALT_BYTES = 16
NOBODY_SALT = "nobody has this password"
NOBODY_PASSWORD = "nobody"
