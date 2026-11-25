#!/usr/bin/env python3
"""The independent signer of the specs of the s3 package: Signature Version 4 on Python's standard library (hmac and
hashlib), written from the AWS documentation, not from the package.

    sigv4_peer.py SEED COUNT

writes COUNT random cases as JSON lines, with the signature each one must have: the request of a client (`header`: the
URL and the `Authorization` header) or a presigned URL (`presign`). Keys, query values and headers hold spaces, unicode
and the characters that S3 percent-encodes, so the encoding is checked together with the signature.
"""

import hashlib
import hmac
import json
import random
import sys
from urllib.parse import quote

UNRESERVED = "-._~"
ALPHABET = "abcXYZ019 /+=&?#%*!'()[]{}<>@:;,$_-.~éñ中\U0001f600\"\\"
HEXDIGITS = "0123456789abcdef"


def enc(text, keep_slash=False):
    return quote(text, safe=UNRESERVED + ("/" if keep_slash else ""))


def hmac256(key, text):
    return hmac.new(key, text.encode(), hashlib.sha256).digest()


def signature(secret, region, amz, canonical):
    day = amz[:8]
    scope = f"{day}/{region}/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    key = hmac256(("AWS4" + secret).encode(), day)
    for part in (region, "s3", "aws4_request"):
        key = hmac256(key, part)
    return hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()


def canonical_query(pairs):
    return "&".join(f"{k}={v}" for k, v in sorted((enc(k), enc(v)) for k, v in pairs))


def canonical(method, path, query, headers, payload):
    merged = {}
    for name, value in headers:
        merged.setdefault(name.lower(), []).append(" ".join(value.split()))
    names = sorted(merged)
    block = "".join(f"{n}:{','.join(merged[n])}\n" for n in names)
    return "\n".join([method, path, canonical_query(query), block, ";".join(names), payload])


def amz_date(at):
    import time
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(at))


def text(rng, low=0, high=12):
    return "".join(rng.choice(ALPHABET) for _ in range(rng.randint(low, high)))


def make_case(rng):
    scheme = rng.choice(["http", "https"])
    port = rng.choice(["", ":9000", ":80", ":443", ":8443"])
    authority = rng.choice(["s3.example.com", "127.0.0.1", "rustfs.local"]) + port
    virtual = rng.random() < 0.4
    bucket = "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789-") for _ in range(rng.randint(3, 20))).strip("-") or "abc"
    if len(bucket) < 3:
        bucket += "xyz"
    key = "/".join(text(rng, 1, 8) for _ in range(rng.randint(1, 3)))
    key = key.lstrip("/") or "k"
    default = {"http": ":80", "https": ":443"}[scheme]
    host_base = authority[: -len(default)] if authority.endswith(default) else authority
    host = f"{bucket}.{host_base}" if virtual else host_base
    path = "/" + enc(key, True) if virtual else f"/{enc(bucket)}/{enc(key, True)}"
    origin = f"{scheme}://{bucket + '.' if virtual else ''}{authority}"
    config = {
        "endpoint": f"{scheme}://{authority}",
        "region": rng.choice(["us-east-1", "eu-west-3", "auto", "ap-southeast-2"]),
        "access_key": "AK" + "".join(rng.choice("ABCDEF0123456789") for _ in range(10)),
        "secret_key": text(rng, 8, 30) + "k",
        "bucket": bucket,
        "addressing": "Virtual" if virtual else "Path",
        "session_token": rng.choice(["", "", text(rng, 5, 40)]),
    }
    query = [[text(rng, 1, 6), text(rng, 0, 8)] for _ in range(rng.randint(0, 3))]
    at = rng.randint(0, 4_000_000_000)
    amz = amz_date(at)
    method = rng.choice(["GET", "PUT", "POST", "DELETE", "HEAD"])
    case = {"config": config, "method": method, "key": key, "query": query, "at": at}
    if rng.random() < 0.5:
        headers = [[n, text(rng, 0, 20)] for n in rng.sample(["content-type", "x-amz-meta-note", "range", "Cache-Control"], rng.randint(0, 3))]
        payload = rng.choice(["UNSIGNED-PAYLOAD", "".join(rng.choice(HEXDIGITS) for _ in range(64))])
        sent = headers + [["x-amz-content-sha256", payload], ["x-amz-date", amz]]
        if config["session_token"]:
            sent.append(["x-amz-security-token", config["session_token"]])
        signed = [["host", host]] + sent
        sig = signature(config["secret_key"], config["region"], amz, canonical(method, path, query, signed, payload))
        names = ";".join(sorted(set(n.lower() for n, _ in signed)))
        credential = f"{config['access_key']}/{amz[:8]}/{config['region']}/s3/aws4_request"
        auth = f"AWS4-HMAC-SHA256 Credential={credential}, SignedHeaders={names}, Signature={sig}"
        qs = canonical_query(query)
        case.update(kind="header", headers=headers, payload=payload,
                    url=origin_url(origin, path, qs), authorization=auth)
    else:
        expires = rng.randint(1, 604800)
        headers = [[n, text(rng, 1, 20)] for n in rng.sample(["content-type", "x-amz-meta-note"], rng.randint(0, 2))]
        covered = [["host", host]] + headers
        names = ";".join(sorted(set(n.lower() for n, _ in covered)))
        extra = [["X-Amz-Algorithm", "AWS4-HMAC-SHA256"],
                 ["X-Amz-Credential", f"{config['access_key']}/{amz[:8]}/{config['region']}/s3/aws4_request"],
                 ["X-Amz-Date", amz], ["X-Amz-Expires", str(expires)], ["X-Amz-SignedHeaders", names]]
        if config["session_token"]:
            extra.append(["X-Amz-Security-Token", config["session_token"]])
        params = query + extra
        sig = signature(config["secret_key"], config["region"], amz,
                        canonical(method, path, params, covered, "UNSIGNED-PAYLOAD"))
        case.update(kind="presign", headers=headers, expires=expires,
                    url=origin_url(origin, path, canonical_query(params) + "&X-Amz-Signature=" + sig))
    return case


def origin_url(origin, path, query):
    return f"{origin}{path}?{query}" if query else f"{origin}{path}"


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    rng = random.Random(int(sys.argv[1]))
    for _ in range(int(sys.argv[2])):
        print(json.dumps(make_case(rng), ensure_ascii=False))


if __name__ == "__main__":
    main()
