---
title: Testing
description: How the package is tested, how to run its specs on a real server, and how to use its S3 stand-in in the specs of an app.
weight: 3
---

## What checks the package

- The signing is checked against the published examples of the AWS documentation, in `test/sigv4_test.agc`: [the header examples](https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html) (GET with a range, PUT with an encoded key, a lifecycle query, a list), [the query example](https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html) (a presigned URL), and the get-vanilla case of [the AWS signature test suite](https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html). The other cases of that suite are for services that sign a normalized, twice-encoded path (dot segments, repeated slashes); S3 signs the path as it is, encoded once, so they do not apply to it.
- `specs/signing.feature` asks `specs/fixtures/sigv4_peer.py` for random requests and presigned URLs, signed with Python's `hmac` and `hashlib`, and checks that the package gives the same URL and the same `Authorization` header. The keys, queries and headers hold spaces, unicode and the characters that S3 percent-encodes.
- The other features run the package against `specs/fixtures/s3_stub.py`.

## The stand-in server

`specs/fixtures/s3_stub.py` is an S3 server of Python's standard library for tests. It checks the signature of every request (header or query, with an expiry) with code of its own, and serves one bucket: `PUT`, `GET` with `Range`, `HEAD`, `DELETE`, and the multipart calls, with the XML errors of S3 (`NoSuchKey`, `SignatureDoesNotMatch`, `EntityTooSmall`, ...). It answers CORS preflights too.

```sh
python3 -I s3_stub.py --bucket photos --access-key fake-access-key --secret-key fake-secret-key [--region us-east-1] [--session-token T]
```

It prints `port N` on its first line and serves until it is stopped; objects live in files of a temporary folder that it removes when it gets SIGTERM. `GET /__stub/requests` lists what it saw, one line per request. An app can start it from a step (`Process.spawn_captured`) and point its `S3.Config` at `http://127.0.0.1:PORT`. It is a test double, not a storage: it keeps nothing after it stops.

## A real server

Set these variables and the same specs run against MinIO, rustfs or AWS S3, in keys with a prefix of their own:

```sh
S3_TEST_ENDPOINT=http://127.0.0.1:9000 S3_TEST_REGION=us-east-1 S3_TEST_BUCKET=photos \
  S3_TEST_ACCESS_KEY=fake-access-key S3_TEST_SECRET_KEY=fake-secret-key agentica test
```

The bucket must exist. A server with a self-signed certificate is trusted by pointing `SSL_CERT_FILE` at its certificate. The scenarios that need the stand-in (the session token, the virtual host, the failing part, a bucket that is not ours) skip. Each scenario works under a prefix `spec-...` and deletes what it left there (and aborts its multipart upload) when it ends.

rustfs, MinIO and S3 do not answer every case alike, and the specs accept both where it does not matter: an access key that does not exist is a 403 `InvalidAccessKeyId` on S3 and a 401 on rustfs, and the parts of an aborted upload are a 404 `NoSuchUpload` on S3 and a 400 `InvalidPart` on rustfs. A reverse proxy in front of a server may also refuse a big body (nginx answers 413 above 1 MiB unless `client_max_body_size` is raised): the multipart specs send parts of 5 MiB.
