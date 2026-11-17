## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver holds the client, the peers and the requests in flight: a step program cannot keep tasks between its
## steps. It answers every request with one line: `ok`, or the reason the request or the expectation failed.

## The reply that means the request worked.
OK = "ok"

## A request. The ops:
##
## - `peer` (name: the peer, number: the idle time after which it closes a connection, 0 for its default) starts
##   `fixtures/peer.py`;
## - `client` (name: the peer of `base_url`, table: a header row, then a setting and a value per row) makes the client;
## - `send` and `start` (name: the request, kind: the method, text: the URL, where `{a}` is the address of the peer
##   `a`, body, header: `name: value` or "") send a request and wait for it, or let it run; `wait` (name) waits for
##   one that runs;
## - `sleep` (number: ms) and `close` (the client);
## - the expectations, on a request's outcome: `expect_status` (number), `expect_body` (text), `expect_header` (text:
##   `name: value`), `expect_kind` (text: the start of the kind of its error) and `expect_within` (number: it ended
##   within that many ms).
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
