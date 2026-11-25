"""An independent scrypt peer for the specs of the password package, on Python's standard library only.

    python3 -I scrypt_peer.py make
    python3 -I scrypt_peer.py check PASSWORD DIGEST

`make` writes golden.json: digests of fixed passwords with fixed salts, in the form `scrypt$N$r$p$salt$key` with salt
and key in base64, at the cost of the package and at others. `check` says `match` or `mismatch` for a digest of that
form, with hashlib.scrypt and hmac.compare_digest, so it tells whether the package wrote a digest that another
implementation reads the same way. The passwords are fakes for tests.
"""

import base64
import hashlib
import hmac
import json
import sys

SALT = bytes(range(1, 17))
MAXMEM = 1 << 28

# name, password, N, r, p, key length
VECTORS = [
    ("default cost", "correct horse battery", 65536, 8, 2, 32),
    ("a lower cost", "another long password", 1024, 8, 2, 32),
    ("other block size and lanes", "correct horse battery", 4096, 4, 1, 32),
    ("a longer key", "correct horse battery", 1024, 8, 2, 64),
    ("not ASCII", "contraseña ñandú 日本", 1024, 8, 2, 32),
]


def scrypt(password: str, salt: bytes, n: int, r: int, p: int, length: int) -> bytes:
    return hashlib.scrypt(password.encode(), salt=salt, n=n, r=r, p=p, dklen=length, maxmem=MAXMEM)


def digest_of(password: str, n: int, r: int, p: int, length: int) -> str:
    key = scrypt(password, SALT, n, r, p, length)
    return "scrypt$%d$%d$%d$%s$%s" % (
        n,
        r,
        p,
        base64.b64encode(SALT).decode(),
        base64.b64encode(key).decode(),
    )


def make() -> None:
    vectors = [
        {"name": name, "password": password, "digest": digest_of(password, n, r, p, length)}
        for name, password, n, r, p, length in VECTORS
    ]
    print(json.dumps(vectors, ensure_ascii=False, indent=2))


def check(password: str, digest: str) -> int:
    parts = digest.split("$")
    if len(parts) != 6 or parts[0] != "scrypt":
        print("malformed")
        return 2
    n, r, p = int(parts[1]), int(parts[2]), int(parts[3])
    salt = base64.b64decode(parts[4], validate=True)
    expected = base64.b64decode(parts[5], validate=True)
    key = scrypt(password, salt, n, r, p, len(expected))
    print("match" if hmac.compare_digest(key, expected) else "mismatch")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["make"]:
        make()
    elif len(sys.argv) == 4 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2], sys.argv[3]))
    else:
        sys.exit("usage: scrypt_peer.py make | check PASSWORD DIGEST")
