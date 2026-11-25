---
title: Testing
description: How the package is tested, how to run its specs on a real server, and how to use its S3 stand-in in the specs of an app.
weight: 3
---

## What checks the package

- The signing is checked against the published examples of the AWS documentation (GET with a range, PUT with an encoded key, queries, a presigned URL) and the get-vanilla case of the AWS signature test suite, in `test/sigv4_test.agc`.
- `specs/signing.feature` asks `specs/fixtures/sigv4_peer.py` for random requests and presigned URLs, signed with Python's `hmac` and `hashlib`, and checks that the package gives the same URL and the same `Authorization` header. The keys, queries and headers hold spaces, unicode and the characters that S3 percent-encodes.
- The other features run the package against `specs/fixtures/s3_stub.py`.

## The stand-in server

`specs/fixtures/s3_stub.py` is an S3 server of Python's standard library for tests. It checks the signature of every request (header or query, with an expiry) with code of its own, and serves one bucket: `PUT`, `GET` with `Range`, `HEAD`, `DELETE`, and the multipart calls, with the XML errors of S3 (`NoSuchKey`, `SignatureDoesNotMatch`, `EntityTooSmall`, ...). It answers CORS preflights too.

```sh
python3 -I s3_stub.py --bucket photos --access-key AKIDEXAMPLE --secret-key SECRET [--region us-east-1] [--session-token T]
```

It prints `port N` on its first line and serves until it is stopped; objects live in files of a temporary folder that it removes when it gets SIGTERM. `GET /__stub/requests` lists what it saw, one line per request. An app can start it from a step (`Process.spawn_captured`) and point its `S3.Config` at `http://127.0.0.1:PORT`. It is a test double, not a storage: it keeps nothing after it stops.

## A real server

Set these variables and the same specs run against MinIO, rustfs or AWS S3, in keys with a prefix of their own:

```sh
S3_TEST_ENDPOINT=http://127.0.0.1:9000 S3_TEST_REGION=us-east-1 S3_TEST_BUCKET=photos \
  S3_TEST_ACCESS_KEY=minioadmin S3_TEST_SECRET_KEY=minioadmin agentica test
```

The bucket must exist. The scenarios that need the stand-in (the session token, the virtual host) skip, and the objects that the specs leave stay in the bucket under their `spec-...` prefix.
