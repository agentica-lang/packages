## The records, the kinds of the errors and the limits of the package.

import HTTP from "std/http"

## The kinds of the errors, for `e.is_a?("s3")` and `e.is_a?(S3.NO_SUCH_KEY)`: the code of the S3 error in snake case
## (`NoSuchKey` is `s3.no_such_key`), with its HTTP status as `e.code` and the code as it came in
## `e.details["s3_code"]`. A refusal before any request is `s3.invalid`, a body that is not what S3 answers
## `s3.protocol` and an answer with no S3 error body `s3.http`. A failed connection keeps the kind of `std/http`.
INVALID = "s3.invalid"
PROTOCOL = "s3.protocol"
HTTP_STATUS = "s3.http"
NO_SUCH_KEY = "s3.no_such_key"
NO_SUCH_BUCKET = "s3.no_such_bucket"
NO_SUCH_UPLOAD = "s3.no_such_upload"
ACCESS_DENIED = "s3.access_denied"
SIGNATURE_DOES_NOT_MATCH = "s3.signature_does_not_match"

## The most keys, parts and sizes S3 allows.
MAX_KEY_BYTES = 1024
MAX_PARTS = 10_000
MIN_PART_BYTES = 5_242_880
MAX_PART_BYTES = 5_368_709_120
MAX_EXPIRES_S = 604_800

## How a bucket is reached: `Path` is `https://host/bucket/key` (MinIO, rustfs, any endpoint with an IP), `Virtual`
## is `https://bucket.host/key` (AWS S3).
enum Addressing
  Path
  Virtual
end

## What every call needs. `endpoint` is the URL of the service without a path (`https://rustfs.example.com`,
## `http://127.0.0.1:9000`), and the presigned URLs are signed for that host. `session_token` is for temporary
## credentials. Never log a `Config`: it holds the secret key.
struct Config
  endpoint: String
  region: String
  access_key: String
  secret_key: String
  bucket: String
  session_token: String = ""
  addressing: Addressing = Addressing.Path
end

## A name and a value: a query parameter or a header.
struct Param
  name: String
  value: String
end

## What a client does with the network. `timeout_ms` bounds a call whole, `transfer_timeout_ms` the calls that move a
## file or a stream (`put_file`, `get_file`, `open`), `max_body_bytes` (at most 64 MiB) the answers held in memory.
## `tls` takes a client context (a private CA, a self-signed certificate), and `connect_to` an IP that every request
## connects to while the URL keeps its host.
struct Options
  timeout_ms: Int = 300_000
  transfer_timeout_ms: Int = 3_600_000
  max_body_bytes: Int = 16_777_216
  tls: Optional[TLS.Context] = none
  connect_to: String = ""
end

## The signing and the connections of one `Config`. Make it with `S3.client` and close it with `S3.close`.
struct Client
  config: Config
  http: HTTP.Client
  options: Options
  transfer: HTTP.ClientOptions
end

## What a presigned URL signs besides the host: a query (`response-content-disposition`, `partNumber`), headers that
## the caller must then send as they are, and the time to start from (seconds since the epoch; now by default).
struct Presign
  expires_s: Int = 900
  query: List[Param] = []
  headers: List[Param] = []
  at: Optional[Int] = none
end

## What a `put` or the creation of a multipart upload stores with the object. `headers` are `x-amz-meta-*` and others.
struct PutOptions
  content_type: String = ""
  headers: List[Param] = []
end

## What `head` and `put` tell about an object. A field the server did not send is empty or -1.
struct ObjectInfo
  etag: String = ""
  size: Int = -1
  content_type: String = ""
  last_modified: String = ""
  headers: List[Param] = []
end

## An object read whole: its `info` and its bytes.
struct Object
  info: ObjectInfo
  body: Bytes
end

## A part of a multipart upload, as `upload_part` and `list_parts` give it (`size` is -1 for the first).
struct Part
  number: Int
  etag: String
  size: Int = -1
end

## How `upload_file` cuts a file: a file up to `part_size` bytes goes in one request, a bigger one in parts of that size
## (raised when the file would need over 10,000 of them), and `headers` and `content_type` are those of `PutOptions`.
struct UploadOptions
  part_size: Int = 16_777_216
  content_type: String = ""
  headers: List[Param] = []
end
