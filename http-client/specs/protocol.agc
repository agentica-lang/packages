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
##   a `ca` row a TLS context that trusts that CA file; `param` (`name=value`), `basic` (`user:password`) and `bearer`
##   rows give it params and an `authorization` header, a `request_step` row (`name: value`) a request step that adds
##   that header, and a `response_step` row (`error_status`) a response step that makes a 4xx or 5xx an error of the
##   kind `status`;
## - `send` and `start` (name: the request, kind: the method, text: the URL, where `{a}` is the address of the peer
##   `a` and `{a:port}` its port alone, body, json: JSON text, param: `name=value`, header: `name: value`) send a
##   request and wait for it, or let it run; `wait` (name) waits for one that runs, and `cancel` (name) cancels its
##   task, which stays after the request until then;
## - `stream`, `stream_first` and `stream_released` (name, kind: the method, text: the URL, header, and release: the
##   raw peer that `stream_released` asks to go on, with a request to `/release`, once the first piece came) stream a
##   response and read its pieces to the end, or close it after the first one, and `events` (name, text: the URL, header) reads the
##   server-sent events of a `GET`; `stream` and `events` wait `number` ms before they read and `pace` ms after each
##   piece or event, `events_closed` closes the events after `number` ms, `events_abandoned` (kind: `cancel` or
##   `crash`) reads them in a task that is cancelled after `number` ms or crashes after the first event, and
##   `events_twice` reads them with a second `events` call on the stream, after a first one; the outcome
##   is a response whose body is the pieces, or `event:data` of each event (a newline as `/`) joined by `|`;
## - `asked` (number) checks how many questions the resolver got in all;
## - `dead_port` (name) gives a peer name to a port where nobody listens, and `read` (name, number) waits until the
##   raw peer has read that many requests, and `read_only` also that it reads no other one;
## - `sleep` (number: ms) and `close` (the client);
## - the expectations, on a request's outcome: `expect_status` (number), `expect_body` (text), `expect_size` (number:
##   the bytes of the body), `expect_header` (text: `name: value`), `expect_url` (text, where `{a}` is the address of
##   `a`), `expect_decoded` (text: `name age` of the person that the JSON body decodes to, or the kind of the error),
##   `expect_kind` (text: the start of the kind of its error), `expect_within` (number: it ended within that many ms)
##   and `expect_after` (number: it took that many ms or more).
struct Request
  op: String
  name: String = ""
  kind: String = ""
  text: String = ""
  body: String = ""
  header: String = ""
  pace: Int = 0
  json: String = ""
  param: String = ""
  release: String = ""
  number: Int = 0
  table: List[List[String]] = []
end
