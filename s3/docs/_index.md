---
title: s3
description: An S3 client for AWS S3, MinIO and rustfs. SigV4 requests, presigned URLs, objects from memory or from a file, and multipart uploads.
---

`s3` talks to S3-compatible object storage from an Agentica program: AWS S3, MinIO, rustfs. It signs requests with Signature Version 4 (in the header and in the query of a presigned URL), reads and writes objects from memory, a file or a stream, and runs multipart uploads. It is written in Agentica over `std/http` and the `OpenSSL` builtins, with no C.

Its first user is a server that never touches the bytes of a big upload: it hands the browser presigned URLs, and the browser uploads to the bucket by itself ([direct uploads](direct-uploads.md)).

## Install

The released version needs Agentica 0.35.0. Add it in a project with an `agentica.toml`, with its prefixed tag and its folder as `--subdir`:

```sh
agentica add s3 agentica-lang/packages --tag s3-0.1.0 --subdir s3
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
s3 = { git = "https://github.com/agentica-lang/packages", tag = "s3-0.1.0", subdir = "s3" }
```

## Example

A presigned URL is made with no network: the server signs it for the host of the endpoint, and whoever holds it can do that one thing until it expires. `at` fixes the time here so that the output is the same on every run; leave it out to start now.

```agentica
import S3 from "pkg/s3/s3"

def main() -> Void
  config = S3.Config(
    endpoint: "https://s3.example.com",
    region: "us-east-1",
    access_key: "fake-access-key",
    secret_key: "fake-secret-key",
    bucket: "photos",
  )

  options = S3.Presign(expires_s: 300, at: some(1_369_353_600))
  url = S3.presign_get(config, "2026/cat.jpg", options).unwrap!
  # The signature depends on the secret key, so the example shows its place only.
  puts("#{url.split("&X-Amz-Signature=")[0]}&X-Amz-Signature=<signature>")
end
```

```output
https://s3.example.com/photos/2026/cat.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=fake-access-key%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=300&X-Amz-SignedHeaders=host&X-Amz-Signature=<signature>
```

The same `Config` makes a client, which sends the requests that need credentials:

```agentica {mode="check"}
import S3 from "pkg/s3/s3"

def main() -> Void
  config = S3.Config(
    endpoint: "http://127.0.0.1:9000",
    region: "us-east-1",
    access_key: "fake-access-key",
    secret_key: "fake-secret-key",
    bucket: "photos",
  )

  client = S3.client(config).unwrap!
  S3.put(client, "hello.txt", "hello".bytes, S3.PutOptions(content_type: "text/plain")).unwrap!
  object = S3.get(client, "hello.txt").unwrap!
  puts(String.from_bytes(object.body).unwrap!)
  S3.delete(client, "hello.txt").unwrap!
  S3.close(client)
end
```

## The config

```signature
S3.Config(endpoint: String, region: String, access_key: String, secret_key: String, bucket: String, session_token: String = "", addressing: S3.Addressing = S3.Addressing.Path)
S3.Options(timeout_ms: Int = 300000, transfer_timeout_ms: Int = 3600000, max_body_bytes: Int = 16777216, tls: Optional[TLS.Context] = none, connect_to: String = "")
```

- `endpoint` is the URL of the service with no path: `https://s3.eu-west-1.amazonaws.com`, `http://127.0.0.1:9000`. The presigned URLs are signed for that host, so it must be the address that the browser will use, not an address of your LAN.
- `addressing` is `S3.Addressing.Path` or `S3.Addressing.Virtual`. `Path` addressing writes `https://host/bucket/key`, which every server accepts and the only one that works with an IP address. `Virtual` writes `https://bucket.host/key`, which AWS S3 prefers. The default port of the scheme is dropped from the signed `Host`, as clients send it.
- `session_token` is for temporary credentials (STS).
- A `Config` holds the secret key: do not log it.
- `Options.timeout_ms` bounds a call whole and `transfer_timeout_ms` the calls that move a file or a stream. `max_body_bytes` (at most 64 MiB) is the largest answer that `get` keeps in memory. `tls` takes the context of a private CA or a self-signed certificate, and `connect_to` an IP that every request connects to, while the URL keeps its host (`Virtual` addressing on a local server, or a split-horizon name).

## API

### `S3.client(config, options = S3.Options()) -> Result[S3.Client]`

Checks the config and makes the client, which owns a pool of keep-alive connections. A config that S3 would refuse (an endpoint with a path, no region, an empty key, a bucket that is not a DNS name of 3 to 63 characters) is an `error` of the kind `s3.invalid`, before any request.

### `S3.close(client) -> Void`

Closes the connections of the client.

### `S3.put(client, key, body, options = S3.PutOptions()) -> Result[S3.ObjectInfo]`

Stores `body` under `key` and replaces what is there. The body is signed with its SHA-256. `options.content_type` and `options.headers` (`x-amz-meta-*` and others) are stored with the object. The `ObjectInfo` has the `etag`.

### `S3.put_file(client, key, path, options = S3.PutOptions()) -> Result[S3.ObjectInfo]`

Stores a file in one request, read and sent in pieces of 256 KiB, so its size is not held in memory. The body is not signed (`UNSIGNED-PAYLOAD`), as S3 allows; use HTTPS when the file is private. A file bigger than 5 GiB goes through `upload_file`.

### `S3.get(client, key) -> Result[S3.Object]`

Reads the object whole, up to `max_body_bytes`. `Object` has the `info` (`size`, `etag`, `content_type`, `last_modified`, and the `x-amz-meta-*` headers) and the `body`. A missing key is an `error` of the kind `s3.no_such_key`.

```agentica {mode="check"}
import S3 from "pkg/s3/s3"

def read(client: S3.Client) -> Result[String]
  object = S3.get(client, "docs/readme.txt")
  case object
    ok(found) -> String.from_bytes(found.body)
    error(e) if e.is_a?(S3.NO_SUCH_KEY) -> ok("")
    error(e) -> error(e)
  end
end
```

### `S3.get_range(client, key, first, last) -> Result[S3.Object]`

Reads the bytes `first` to `last`, both included. `last` of -1 reads to the end. The `size` of the `info` is the number of bytes that came back, not the size of the object (`head` has that). A `first` at or past the end is an `error` of the kind `s3.invalid_range`.

### `S3.get_file(client, key, path) -> Result[S3.ObjectInfo]`

Streams the object into a file. The pieces go to a hidden file beside `path`, which replaces `path` only after the whole body came, so a failure never leaves a cut file.

### `S3.open(client, key) -> Result[HTTP.Stream]`

Gives the object as it arrives, as the `HTTP.Stream` of `std/http`: read `body` to its closed error, then `Task.await(done)`, which tells a whole body from a cut one. A status of 300 or more is an `error`.

### `S3.head(client, key) -> Result[S3.ObjectInfo]`

What the object is, with no body. A missing key is an `error` of the kind `s3.no_such_key`.

### `S3.delete(client, key) -> Result[Void]`

Deletes `key`. S3 answers success for a key that is not there.

### `S3.presign_get(config, key, options = S3.Presign()) -> Result[String]`

A URL for a `GET`. `S3.Presign` has `expires_s` (900 by default, from 1 to 604800), a `query` and `headers` that are signed too, and `at`, the time to start from. `response-content-disposition` and `response-content-type` in the query make the download name:

```agentica
import S3 from "pkg/s3/s3"

def main() -> Void
  config = S3.Config(endpoint: "http://127.0.0.1:9000", region: "us-east-1", access_key: "fake-access-key", secret_key: "fake-secret-key", bucket: "photos")
  query = [S3.Param(name: "response-content-disposition", value: "attachment; filename=\"cat.jpg\"")]
  url = S3.presign_get(config, "cat.jpg", S3.Presign(query: query, at: some(0))).unwrap!
  puts(url.split("&")[0])
end
```

```output
http://127.0.0.1:9000/photos/cat.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256
```

### `S3.presign_put(config, key, options = S3.Presign()) -> Result[String]`

A URL for a `PUT` of one object. A header in `options.headers` (`content-type`) is signed, so whoever uses the URL must send it as it is. With none, any header goes.

### `S3.presign_part(config, key, upload_id, number, options = S3.Presign()) -> Result[String]`

A URL for a `PUT` of part `number` (1 to 10,000) of a multipart upload. The answer of S3 carries the `ETag` of the part, which `complete_multipart` needs.

### `S3.create_multipart(client, key, options = S3.PutOptions()) -> Result[String]`

Starts a multipart upload and gives its id. `options` are those of the object that the upload makes.

### `S3.upload_part(client, key, upload_id, number, body) -> Result[S3.Part]`

Uploads one part. Every part but the last must have 5 MiB or more. The `Part` has the `number` and the `etag`.

### `S3.list_parts(client, key, upload_id) -> Result[List[S3.Part]]`

The parts uploaded so far, in order, with their `size` (every page of the answer). An upload that does not exist is an `error` of the kind `s3.no_such_upload`.

### `S3.complete_multipart(client, key, upload_id, parts) -> Result[S3.ObjectInfo]`

Joins the parts, which must be in ascending order of `number`, into the object. S3 may answer 200 with an error in the body when it fails after it started; that is an `error` here too, as is a part under 5 MiB that is not the last one (`s3.entity_too_small`).

### `S3.abort_multipart(client, key, upload_id) -> Result[Void]`

Drops the upload and its parts. Parts that are not aborted stay in the bucket and are billed: abort the uploads that fail or never complete.

### `S3.upload_file(client, key, path, options = S3.UploadOptions()) -> Result[S3.ObjectInfo]`

Stores a file of any size. A file up to `part_size` (16 MiB by default, from 5 MiB to 5 GiB) goes in one request, as `put_file` does. A bigger one goes in parts of that size, one after the other, each held in memory and signed; the part size grows when the file would need more than 10,000 parts. A failed part aborts the upload.

## Errors

Every call that can fail gives a `Result`. A refusal of S3 is an `error` whose kind is the code of the XML body in snake case: `NoSuchKey` is `s3.no_such_key`, `AccessDenied` is `s3.access_denied`, `SignatureDoesNotMatch` is `s3.signature_does_not_match`. The HTTP status is `e.code`, the code as S3 wrote it is `e.details["s3_code"]`, and the request id is `e.details["request_id"]`. Test the kinds with `e.is_a?(S3.NO_SUCH_KEY)` or `e.is_a?("s3")`, never with the message.

- `s3.invalid`: refused before any request (the config, a key over 1024 bytes, an expiry out of range).
- `s3.protocol`: an answer that is not what S3 says (no `UploadId`, no `ETag`).
- `s3.http`: a status of 300 or more with no S3 error in it; a `HEAD` of a missing key is `s3.no_such_key`, and a 403 `s3.access_denied`.
- A failed connection or timeout keeps the kind of `std/http` (`net.*`, `http.*`).

## Tests

The package is checked against the published examples of the AWS documentation and the get-vanilla case of the signature test suite, against an independent signer written on Python's `hmac` and `hashlib` that signs random requests, and against a small S3 server of Python's standard library that checks every signature with code of its own. [Testing](testing.md) says how to run the same specs on MinIO, rustfs or AWS, and how an app can use the server in its own specs.
