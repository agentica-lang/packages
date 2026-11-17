## The content codings of a response body that the client undoes: `gzip` (and its old name `x-gzip`) and `deflate`.

import Exchange from "exchange"
import HTTP from "std/http"

## What the client asks for when it decompresses.
ACCEPTED = "gzip, deflate"

## The response with its body decoded, and without the `content-encoding` and `content-length` that no longer apply.
## A body in another coding, or none, stays as it is. The decoded body is at most `max_bytes` (`http_client.too_large`),
## and one that does not decode is an `http_client.decode` error.
def decoded(response: Exchange.Response, max_bytes: Int) -> Result[Exchange.Response]
  codings = HTTP.header_values(response.headers, "content-encoding").map { |value| value.strip.downcase }
  return ok(response) if response.body.empty? or codings.size != 1

  body = response.body
  if ["gzip", "x-gzip"].include?(codings[0])
    body = try undone([response.body].lazy.gunzip(max_bytes).to_a)
  elsif codings[0] == "deflate"
    body = try inflated(response.body, max_bytes)
  else
    return ok(response)
  end

  headers = response.headers.select { |header| not ["content-encoding", "content-length"].include?(header.name) }
  ok(response.with(headers: headers, body: body))
end

private

# `deflate` is the zlib format (RFC 9110), but some servers send raw DEFLATE, as browsers accept.
def inflated(body: Bytes, max_bytes: Int) -> Result[Bytes]
  wrapped = undone([body].lazy.inflate(false, max_bytes).to_a)
  case wrapped
    error(e) if e.is_a?("http_client.decode") -> undone([body].lazy.inflate(true, max_bytes).to_a)
    _ -> wrapped
  end
end

def undone(chunks: Result[List[Bytes]]) -> Result[Bytes]
  case chunks
    ok(parts) -> ok(Bytes.concat(parts))
    error(e) if e.is_a?("zlib.too_large") -> Exchange.failure("the decoded body is too large", "too_large", some(e))
    error(e) -> Exchange.failure("the body does not decode", "decode", some(e))
  end
end
