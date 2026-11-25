## AWS Signature Version 4, pure: the canonical request, the signature, the `Authorization` header and the query of a
## presigned URL. Every function takes the time it signs at.

import Encoding from "encoding"
import Types from "types"

## The payload hash of a body that is not signed (a streamed file, a presigned URL).
UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD"
ALGORITHM = "AWS4-HMAC-SHA256"

## The part of the credentials that signs: `service` is `s3` here (the test vectors of AWS use others).
struct Scope
  access_key: String
  secret_key: String
  region: String
  service: String = "s3"
  session_token: String = ""
end

## A signed request: the value of `Authorization`, and the signature and the `;`-joined header names it covers.
struct Signed
  authorization: String
  signature: String
  signed_headers: String
end

## The signature of a request with headers (`host` and `x-amz-date` among them, and `x-amz-content-sha256` for S3):
## `path` is the path as sent, already encoded, `payload_hash` the hex SHA-256 of the body or `UNSIGNED-PAYLOAD`.
def sign(
  scope: Scope,
  method: String,
  path: String,
  query: List[Types.Param],
  headers: List[Types.Param],
  payload_hash: String,
  amz: String,
) -> Signed
  names = signed_names(headers)
  canonical = canonical_request(method, path, query, headers, payload_hash)
  signature = signature_of(scope, amz, canonical)
  credential = "#{scope.access_key}/#{credential_scope(scope, amz)}"
  authorization = "#{ALGORITHM} Credential=#{credential}, SignedHeaders=#{names}, Signature=#{signature}"
  Signed(authorization: authorization, signature: signature, signed_headers: names)
end

## The query string of a presigned URL: the `query` given, the `X-Amz-*` parameters and the `X-Amz-Signature`, which is
## last. Only `host` and `headers` are signed, and the payload is not.
def presign(
  scope: Scope,
  method: String,
  host: String,
  path: String,
  query: List[Types.Param],
  headers: List[Types.Param],
  expires_s: Int,
  amz: String,
) -> String
  covered = [Types.Param(name: "host", value: host)] + headers
  extra = [
    Types.Param(name: "X-Amz-Algorithm", value: ALGORITHM),
    Types.Param(name: "X-Amz-Credential", value: "#{scope.access_key}/#{credential_scope(scope, amz)}"),
    Types.Param(name: "X-Amz-Date", value: amz),
    Types.Param(name: "X-Amz-Expires", value: "#{expires_s}"),
    Types.Param(name: "X-Amz-SignedHeaders", value: signed_names(covered)),
  ]

  if scope.session_token != ""
    extra = extra.push(Types.Param(name: "X-Amz-Security-Token", value: scope.session_token))
  end

  params = query + extra
  canonical = canonical_request(method, path, params, covered, UNSIGNED_PAYLOAD)
  signature = signature_of(scope, amz, canonical)
  "#{canonical_query(params)}&X-Amz-Signature=#{signature}"
end

## The canonical request (the text that is hashed), for the tests and for a server that wants to compare.
def canonical_request(
  method: String,
  path: String,
  query: List[Types.Param],
  headers: List[Types.Param],
  payload_hash: String,
) -> String
  [method, path, canonical_query(query), canonical_headers(headers), signed_names(headers), payload_hash].join("\n")
end

## The query as signed: names and values encoded, sorted by name and then by value, `name=value` joined by `&`.
def canonical_query(query: List[Types.Param]) -> String
  pairs = query.map { |p| Types.Param(name: Encoding.component(p.name), value: Encoding.component(p.value)) }
  pairs.sort_by { |p| "#{p.name}\n#{p.value}" }.map { |p| "#{p.name}=#{p.value}" }.join("&")
end

private

def credential_scope(scope: Scope, amz: String) -> String
  "#{Encoding.day_of(amz)}/#{scope.region}/#{scope.service}/aws4_request"
end

def signature_of(scope: Scope, amz: String, canonical: String) -> String
  to_sign = [ALGORITHM, amz, credential_scope(scope, amz), Encoding.hex(OpenSSL.Digest.sha256(canonical.bytes))].join(
    "\n",
  )

  Encoding.hex(OpenSSL.HMAC.sha256(signing_key(scope, Encoding.day_of(amz)), to_sign.bytes))
end

def signing_key(scope: Scope, day: String) -> Bytes
  dated = OpenSSL.HMAC.sha256("AWS4#{scope.secret_key}".bytes, day.bytes)
  regional = OpenSSL.HMAC.sha256(dated, scope.region.bytes)
  serviced = OpenSSL.HMAC.sha256(regional, scope.service.bytes)
  OpenSSL.HMAC.sha256(serviced, "aws4_request".bytes)
end

# Names lowercase, values trimmed with inner runs of spaces folded, the same name's values joined by commas.
def normalized(headers: List[Types.Param]) -> List[Types.Param]
  lowered = headers.map { |h| Types.Param(name: h.name.downcase, value: fold(h.value)) }
  merged: List[Types.Param] = []
  ordered = lowered.sort_by { |h| h.name }
  for header in ordered
    last = merged.length - 1
    if last >= 0 and merged[last].name == header.name
      merged = merged.take(last).push(Types.Param(name: header.name, value: "#{merged[last].value},#{header.value}"))
    else
      merged = merged.push(header)
    end
  end

  merged
end

def fold(value: String) -> String = value.strip.split(" ").select { |word| word != "" }.join(" ")

def canonical_headers(headers: List[Types.Param]) -> String
  normalized(headers).map { |h| "#{h.name}:#{h.value}\n" }.join("")
end

def signed_names(headers: List[Types.Param]) -> String = normalized(headers).map { |h| h.name }.join(";")
