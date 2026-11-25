## Sending: the signed requests of a client, and the pure making of one (`prepare`).

import Address from "address"
import Encoding from "encoding"
import Failure from "failure"
import HTTP from "std/http"
import Sigv4 from "sigv4"
import Types from "types"

## A request made ready: its URL and the headers to send (`Host` is the client's).
struct Prepared
  url: String
  headers: List[HTTP.Header]
end

## The credentials that sign for a `Config`.
def scope_of(config: Types.Config) -> Sigv4.Scope
  Sigv4.Scope(
    access_key: config.access_key,
    secret_key: config.secret_key,
    region: config.region,
    session_token: config.session_token,
  )
end

## Signs a request at `at` (seconds since the epoch): the URL with its query, and the headers given with
## `x-amz-date`, `x-amz-content-sha256`, the session token and `Authorization`. All of them are signed, with `host`.
def prepare(
  config: Types.Config,
  method: String,
  key: String,
  query: List[Types.Param],
  headers: List[Types.Param],
  payload_hash: String,
  at: Int,
) -> Result[Prepared]
  target = try Address.target(config, key)
  amz = Encoding.amz_date(at)
  covered = (
    headers +
    [Types.Param(name: "x-amz-content-sha256", value: payload_hash), Types.Param(name: "x-amz-date", value: amz)]
  )

  if config.session_token != ""
    covered = covered.push(Types.Param(name: "x-amz-security-token", value: config.session_token))
  end

  signed = Sigv4.sign(
    scope_of(config),
    method,
    target.path,
    query,
    [Types.Param(name: "host", value: target.host)] + covered,
    payload_hash,
    amz,
  )

  sent = covered.map { |p| HTTP.Header(name: p.name, value: p.value) }
  authorized = sent.push(HTTP.Header(name: "authorization", value: signed.authorization))
  ok(Prepared(url: "#{target.origin}#{target.path}#{query_of(query)}", headers: authorized))
end

## A request with a body in memory, signed with its hash. The answer is whole, and a status of 300 or more is an
## `error` (`Failure.refused`).
def send(
  client: Types.Client,
  method: String,
  key: String,
  query: List[Types.Param],
  headers: List[Types.Param],
  body: Bytes,
) -> Result[HTTP.Response]
  payload = Encoding.hex(OpenSSL.Digest.sha256(body))
  prepared = try prepare(client.config, method, key, query, headers, payload, Time.now().to_i)
  response = try HTTP.request(client.http, method, prepared.url, body, prepared.headers)
  return Failure.refused(response.status, response.body) if response.status >= 300

  ok(response)
end

## A request whose body is the pieces of a channel, exactly `length` bytes, not signed (`UNSIGNED-PAYLOAD`).
def send_stream(
  client: Types.Client,
  method: String,
  key: String,
  headers: List[Types.Param],
  pieces: Channel[Bytes],
  length: Int,
) -> Result[HTTP.Response]
  prepared = try prepare(client.config, method, key, [], headers, Sigv4.UNSIGNED_PAYLOAD, Time.now().to_i)
  response = try HTTP.upload(method, prepared.url, pieces, length, prepared.headers, client.transfer)
  return Failure.refused(response.status, response.body) if response.status >= 300

  ok(response)
end

## A `GET` whose body is read as it arrives: the head has been checked, and `body` is the channel of the pieces.
def open(client: Types.Client, key: String, headers: List[Types.Param]) -> Result[HTTP.Stream]
  prepared = try prepare(
    client.config,
    "GET",
    key,
    [],
    headers,
    Encoding.hex(OpenSSL.Digest.sha256("".bytes)),
    Time.now().to_i,
  )

  stream = try HTTP.open("GET", prepared.url, "".bytes, prepared.headers, client.transfer)
  if stream.status >= 300
    detail = read_error(stream)
    return Failure.refused(stream.status, detail)
  end

  ok(stream)
end

private

ERROR_BODY_BYTES = 65_536

def query_of(query: List[Types.Param]) -> String
  return "" if query.empty?

  "?#{Sigv4.canonical_query(query)}"
end

# The XML of an error is small: read what comes, up to a limit, and stop the stream.
def read_error(stream: HTTP.Stream) -> Bytes
  collected = "".bytes
  while collected.size < ERROR_BODY_BYTES
    case stream.body.recv(5000)
      ok(piece) -> collected = collected + piece
      error(_) -> break
    end
  end

  stream.body.close
  Task.cancel(stream.done)
  collected
end
