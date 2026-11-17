## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver holds the client, the peers and the requests in flight: a step program cannot keep tasks between its
## steps. It answers every request with one line: `ok`, or the reason the request or the expectation failed.

## The reply that means the request worked.
OK = "ok"

## A request. The ops:
##
## - `peer` (name: the peer, kind: `server` for `fixtures/server.agc`, `tls_server` for it over HTTPS, or `raw` for
##   `fixtures/raw_peer.agc`, text: the script of a raw peer, one answer per line) starts a peer;
## - `client` (name: the peer of `base_url`, table: a header row, then a setting and a value per row) makes the client,
##   with `max_retries` 0 and `retry_delay_ms` 10 unless a row sets them, so that only the scenarios of retries retry;
##   a `resolve` row (`name=address,address`, or `name=hang` for one it never answers) gives it a resolver that knows
##   those names and counts its questions, and
##   a `ca` row a TLS context that trusts that CA file;
## - `send` and `start` (name: the request, kind: the method, text: the URL, where `{a}` is the address of the peer
##   `a` and `{a:port}` its port alone, body, header: `name: value` or "") send a request and wait for it, or let it run; `wait` (name) waits for
##   one that runs, and `cancel` (name) cancels its task, which stays after the request until then;
## - `asked` (number) checks how many questions the resolver got in all;
## - `dead_port` (name) gives a peer name to a port where nobody listens, and `read` (name, number) waits until the
##   raw peer has read that many requests, and `read_only` also that it reads no other one;
## - `sleep` (number: ms) and `close` (the client);
## - the expectations, on a request's outcome: `expect_status` (number), `expect_body` (text), `expect_header` (text:
##   `name: value`), `expect_url` (text, where `{a}` is the address of `a`), `expect_kind` (text: the start of the
##   kind of its error), `expect_within` (number: it ended within that many ms) and `expect_after` (number: it took
##   that many ms or more).
struct Request
  op: String
  name: String = ""
  kind: String = ""
  text: String = ""
  body: String = ""
  header: String = ""
  number: Int = 0
  table: List[List[String]] = []
end
