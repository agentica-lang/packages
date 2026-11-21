## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver holds the client, the peers and the requests in flight: a step program cannot keep tasks between its
## steps. It answers every request with one line: `ok`, or the reason the request or the expectation failed.

## The reply that means the request worked.
OK = "ok"

## The script of a raw peer (`fixtures/raw_peer.agc`), one answer for each line, for the peer `name`.
struct Script
  name: String
  text: String
end

## The client that `HttpClient.new` makes for the base URL of the peer `name`: `table` has a header row, then a setting
## and a value per row. The client has `max_retries` 0 and `retry_delay_ms` 10 unless a row sets them, so that only the
## scenarios of retries retry. A `resolve` row (`name=address,address`, or `name=hang` for one it never answers) gives
## it a resolver that knows those names and counts its questions, a `ca` row a TLS context that trusts that CA file;
## `param` (`name=value`), `basic` (`user:password`) and `bearer` rows give it params and an `authorization` header, a
## `request_step` row (`name: value`) a request step that adds that header, and a `response_step` row (`error_status`)
## a response step that makes a 4xx or 5xx an error of the kind `status`.
struct Setup
  name: String
  table: List[List[String]]
end

## What a call does with the response: `Plain` sends a request and keeps the response; `Stream` streams it and reads its
## pieces to the end, `StreamFirst` closes it after the first piece, `StreamCancel` cancels it after the last piece,
## `StreamCancelFirst` after the first one, and `StreamReleased` asks the raw peer `release` to go on, with a request
## to `/release`, once the first piece came; `Events` reads the server-sent events of a `GET`,
## `EventsClosed` closes them after `wait_ms`, `EventsAbandoned` reads them in a task that is cancelled after `wait_ms`
## (or, with `crash`, crashes after the first event), and `EventsTwice` reads them with a second `events` call on the
## stream, after a first one. The outcome is a response whose body is the pieces, or `event:data` of each event (a
## newline as `/`) joined by `|`.
enum How
  Plain
  Stream
  StreamFirst
  StreamCancel
  StreamCancelFirst
  StreamReleased
  Events
  EventsClosed
  EventsAbandoned
  EventsTwice
end

## A request of the client, kept under `name`: `method` and `url` (where `{a}` is the address of the peer `a` and
## `{a:port}` its port alone), a `body`, a `header` (`name: value`), `json` text or a `param` (`name=value`) for a plain
## call, `wait_ms` before a stream or events are read, and `pace_ms` after each piece or event.
struct Call
  name: String
  method: String = ""
  url: String
  how: How = How.Plain
  body: String = ""
  header: String = ""
  json: String = ""
  param: String = ""
  release: String = ""
  wait_ms: Int = 0
  pace_ms: Int = 0
  crash: Bool = false
end

## A raw peer `name` that must have read `count` requests (`ReadOnly`: and no other).
struct Reads
  name: String
  count: Int
end

## What a request's outcome must be: a status, a body (`Body`), its size in bytes, a header (`name: value`), the URL it
## ended at (where `{a}` is the address of `a`), what the JSON body decodes to (`name age` of the person, or the kind of
## the error), the start of the kind of its error, that it ended within that many ms, or took that many ms or more.
enum Check
  Status(Int)
  Body(String)
  Size(Int)
  Header(String)
  Url(String)
  Decoded(String)
  Kind(String)
  Within(Int)
  After(Int)
end

## The expectation `check` on the outcome of the request `name`.
struct Expectation
  name: String
  check: Check
end

## A request, one for each thing a step asks of the driver: a peer (`Server`: the server of `fixtures/server.agc`,
## `TlsServer`: the same over HTTPS, `Raw`) or a client; a call that is sent and waited for (`Send`) or let to run
## (`Start`, then `Wait` for the name of one that runs, or `Cancel` its task, which stays after the request until then);
## `Asked` (how many questions the resolver got in all), `DeadPort` (gives a peer name to a port where nobody listens),
## `Read` and `ReadOnly`, `Sleep` (ms) and `Close` (the client); and the expectations.
enum Request
  Server(String)
  TlsServer(String)
  Raw(Script)
  Client(Setup)
  Send(Call)
  Start(Call)
  Wait(String)
  Cancel(String)
  DeadPort(String)
  Read(Reads)
  ReadOnly(Reads)
  Asked(Int)
  Sleep(Int)
  Close
  Expect(Expectation)
end
