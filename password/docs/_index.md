---
title: password
description: Password hashing with scrypt. A digest that carries its cost, a constant-time check, limits for new passwords, and the same work for a missing user.
category: Infrastructure
keywords: [password, scrypt, hash, sign-in, authentication]
---

`password` hashes and checks passwords for an app with a sign-in. It is the part that is easy to get wrong: a random salt for each password, a digest that says which cost made it, a compare that takes the same time whatever the key, and the same work for a user that does not exist, so that the time of a sign-in does not tell whether an email is registered. It is written in Agentica over the `OpenSSL.KDF.scrypt` builtin, with no C.

It only hashes and checks. It stores nothing, and it does not read the bcrypt digests of other systems.

## Install

The released version needs Agentica 0.35.0. Add it in a project with an `agentica.toml`, with its prefixed tag and its folder as `--subdir`:

```sh
agentica add password agentica-lang/packages --tag password-0.1.0 --subdir password
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
password = { git = "https://github.com/agentica-lang/packages", tag = "password-0.1.0", subdir = "password" }
```

## Example

`hash` makes the digest to store, and `verify` checks a password against it:

```agentica
import Password from "pkg/password/password"

def main() -> Void
  digest = Password.hash("correct horse battery").unwrap!
  puts(digest.start_with?("scrypt$65536$8$2$"))
  puts(Password.verify("correct horse battery", digest).unwrap!)
  puts(Password.verify("correct horse batterz", digest).unwrap!)
end
```

```output
true
true
false
```

## The digest

A digest is one text, `scrypt$N$r$p$salt$key`, with the salt and the key in base64. The key derivation is standard scrypt (RFC 7914); the text format is this package's own. `N`, `r` and `p` are the cost that made it, so `verify` reads the cost from the digest: the cost of new passwords can be raised later and the old digests still verify. New digests use N of 65536, r of 8 and p of 2 (OWASP's setting, 64 MiB of memory for each hash), a 16 byte salt and a 32 byte key.

`verify` bounds the digest it reads, since a digest comes from a store that may be damaged or written by someone else: the memory of the work (`128 * r * (N + p + 2)` bytes) is at most 256 MiB, `r` is at most 32 and `p` at most 16, `N` is a power of 2 from 1024, the salt has 8 to 64 bytes and the key 16 to 64, and the numbers are written in plain decimal (`8`, not `08` or `+8`). A digest outside that is an `error` that names the field. This is also the limit of raising the cost: a cost whose memory is over 256 MiB, such as `N` of 1048576 with `r` of 8, makes digests that `verify` refuses.

A hash takes 64 MiB while it runs. An app that signs many people in at once should bound how many hashes run together.

A password is hashed as it is given, as UTF-8 bytes: there is no Unicode normalization, so the same text written with composed and with decomposed characters is two passwords.

## API

### `Password.hash(password) -> Result[String]`

The digest of `password` with a new random salt. It never holds the password. A password of more than `Password.MAX_BYTES` bytes is an `error`. It does not call `problem`: an app that takes a new password checks it first.

### `Password.verify(password, digest) -> Result[Bool]`

Whether `password` made `digest`. The keys are compared in constant time. A wrong password is `ok(false)`, and so is a password of more than `Password.MAX_BYTES` bytes, with no hashing. A digest that is not of this form, or that is out of the bounds above, is an `error`: that says nothing about the password, so an app should log it, call `verify_nobody` and then treat the sign-in as failed, so that a missing or damaged digest costs the same time as a wrong password. The error never holds the digest.

```agentica
import Password from "pkg/password/password"

def main() -> Void
  digest = "scrypt$1024$8$2$AQIDBAUGBwgJCgsMDQ4PEA==$k6UaLA1ch6VFTNpUo+rxtZz9UjXZ5kX/WzWpBpW+qS4="
  puts(Password.verify("another long password", digest).unwrap!)
  puts(Password.verify("another long passwore", digest).unwrap!)
  puts(Password.verify("another long password", "plain").ok?)
end
```

```output
true
false
false
```

### `Password.problem(password) -> String`

What is wrong with `password` as a new password, or `""` when it is fine: at least `Password.MIN_LENGTH` (8) characters and at most `Password.MAX_BYTES` (256) bytes. The limit is in bytes, so a password of 129 letters of two bytes each is too long. The text is for a person to read.

```agentica
import Password from "pkg/password/password"

def main() -> Void
  puts(Password.problem("short"))
  puts(Password.problem("long enough").empty?)
end
```

```output
The password needs at least 8 characters
true
```

### `Password.verify_nobody() -> Void`

Does the work of `hash` for a password that nobody has. A sign-in calls it for an email that no user has, and for a digest that `verify` refused, so that the time of the answer is the same for a user that exists and one that does not. A digest made with another cost takes the time of its own cost and not the time of `verify_nobody`, so an app that has raised its cost can tell the old digests apart by time; it can accept that, or hash the password again at the next sign-in.

```agentica {mode="check"}
import Password from "pkg/password/password"

def check(stored: Optional[String], password: String) -> Bool
  if stored.some?
    verdict = Password.verify(password, stored.unwrap!)
    return verdict.unwrap! if verdict.ok?
  end

  Password.verify_nobody()
  false
end
```

### `Password.MIN_LENGTH` and `Password.MAX_BYTES`

The limits of `problem`: 8 characters and 256 bytes. An app that takes a password from a request can refuse one over `MAX_BYTES` before it does any other work.

## Tests

The package is checked against `specs/fixtures/scrypt_peer.py`, a scrypt on Python's standard library that shares nothing with it. `specs/fixtures/golden.json` holds digests that the peer made (the cost of the package and other costs, another block size and lane count, a longer key, a password that is not ASCII), and the package verifies each. The peer also reads the digests that the package writes, so the two agree both ways. The passwords of the specs are fakes.
