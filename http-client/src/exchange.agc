## One request on a link of the pool: on the link's idle connection or a new one, send, read the whole body, and leave
## the connection in the link when it can take the next request.
##
## Until Agentica 0.34.0 (agentica#1710) a `HTTP.Connection` has one timeout, `options.timeout_ms`, for each call on
## it. `waiting` gives each call its own on a copy of the connection; the copy shares the socket and the state. The
## call that sends the request also reads the response head, so `read_timeout_ms` covers the send too.

import HTTP from "std/http"
import Link from "link"
import {Held} from "link"
import Url from "url"

## A response: the status, the headers (names in lowercase), the whole body and the URL it came from.
struct Response
  status: Int
  headers: List[HTTP.Header]
  body: Bytes
  url: String
end

## A response whose body comes in pieces: `body` gives `ok(piece)` for each piece as it comes, or one `error` when the
## body fails, and closes at its end. The client waits `read_timeout_ms` for each piece, and as long for the reader to
## take it; closing `body` ends the request early, and its connection.
struct Stream
  status: Int
  headers: List[HTTP.Header]
  url: String
  body: Channel[Result[Bytes]]
end

## What reaches the caller of a try: the head of a streamed response, and the end of the task of the try.
enum Arrival
  Head(Stream)
  Over
end

## How a call streams: `whole` says which responses are read whole all the same (given with their head only), and
## the head of a streamed one goes to `arrivals`.
struct Streaming
  whole: Fn[Response, Bool]
  arrivals: Channel[Arrival]
end

## What one request needs: where it goes, what it sends, and its limits. `deadline` is the monotonic time at which
## `timeout_ms` of the whole request runs out; it does not bound the body of a streamed response.
struct Call
  method: String
  target: Url.Target
  headers: List[HTTP.Header]
  body: Bytes
  connect_timeout_ms: Int
  read_timeout_ms: Int
  deadline: Int
  max_body_bytes: Int
  streaming: Optional[Streaming]
end

## Runs the request on the link: on its idle connection, or on a new one. When std/http finds that the idle
## connection is closed before it writes a byte, the request goes once more on a new connection. A request that was
## never written leaves the connection in the link; any other failure ends it.
def run(link: Link.Link, call: Call) -> Result[Response]
  case Link.take(link)
    some(held) ->
      tried = attempt(link, held, call)
      case tried
        Attempt.Stale(_) -> fresh(link, call)
        _ -> outcome(tried)
      end

    none -> fresh(link, call)
  end
end

## An error of the request with its kind, below `http_client`.
def failure[T](text: String, kind: String, cause: Optional[Error] = none) -> Result[T]
  case cause
    some(e) -> error("http_client: #{text}: #{e.message}", kind: "http_client.#{kind}", cause: e)
    none -> error("http_client: #{text}", kind: "http_client.#{kind}")
  end
end

private

READ_BYTES = 65_536
# The pieces of a streamed body that wait for the reader.
PIECES = 16
NO_BYTES = "".bytes
# The longest `Keep-Alive: timeout=` that is taken as it is: a day.
MAX_KEEP_ALIVE_S = 86_400

struct Done
  response: Response
  reusable: Bool
  expires_at: Int
end

# How one try on a connection went: answered, refused before a byte was written (the connection is still good), sent
# on a connection that std/http had already closed (nothing was written either), or failed. The last three hold the
# error.
enum Attempt
  Answered(Done)
  Refused(Result[Response])
  Stale(Result[Response])
  Failed(Result[Response])
end

# How long the next wait may last, and which timeout ends it: the read timeout, or what is left of the whole request.
struct Wait
  ms: Int
  kind: String
end

def fresh(link: Link.Link, call: Call) -> Result[Response]
  held = try connect(link, call)
  tried = attempt(link, held, call)
  case tried
    Attempt.Stale(stale) ->
      case stale
        error(e) -> failure("the connection failed", "network", some(e))
        ok(response) -> ok(response)
      end

    _ -> outcome(tried)
  end
end

def outcome(tried: Attempt) -> Result[Response]
  case tried
    Attempt.Answered(done) -> ok(done.response)
    Attempt.Refused(failed) -> failed
    Attempt.Stale(failed) -> failed
    Attempt.Failed(failed) -> failed
  end
end

def connect(link: Link.Link, call: Call) -> Result[Held]
  wait = try next_wait(call, call.connect_timeout_ms, "timeout.connect")
  case Link.connect(link, wait.ms)
    ok(held) -> ok(held)
    error(e) if e.is_a?("http_client") -> error(e)
    error(e) if e.is_a?("net.timeout") -> failure("connecting to #{call.target.origin} timed out", wait.kind, some(e))
    error(e) -> failure("cannot connect to #{call.target.origin}", "network", some(e))
  end
end

# One try, which leaves the connection in the link (`park`) or ends it (`release`).
def attempt(link: Link.Link, held: Held, call: Call) -> Attempt
  tried = exchange(held, call)
  case tried
    Attempt.Answered(done) if done.reusable -> Link.park(link, held.with(expires_at: done.expires_at))
    Attempt.Refused(_) -> Link.park(link, held)
    _ -> Link.release(link)
  end

  tried
end

def exchange(held: Held, call: Call) -> Attempt
  case next_wait(call, call.read_timeout_ms, "timeout.read")
    ok(wait) ->
      head = HTTP.send_request(waiting(held, wait), call.method, call.target.target, call.body, call.headers)
      sent(held, call, wait, head)
    error(e) -> Attempt.Refused(error(e))
  end
end

# Whether a failed `send_request` wrote anything: std/http refuses a request it cannot encode (a bad method, target or
# header), and one on a connection it closed after the last body, before it writes a byte, and leaves the connection
# as it was, so `read_body` finds no response to read. After a failure past the first byte (a close after a
# `100 Continue` is an `http.closed` too) the connection is over and `read_body` fails.
def sent(held: Held, call: Call, wait: Wait, head: Result[HTTP.ResponseHead]) -> Attempt
  case head
    ok(started) ->
      case answered(held, call, started)
        ok(done) -> Attempt.Answered(done)
        error(e) -> Attempt.Failed(error(e))
      end

    error(e) if HTTP.read_body(held.conn, 1).ok? ->
      return Attempt.Stale(error(e)) if e.is_a?("http.closed")

      Attempt.Refused(error("http_client: #{e.message}", kind: "argument", cause: e))
    error(e) -> Attempt.Failed(read_failure(e, wait, "the response did not come"))
  end
end

def answered(held: Held, call: Call, head: HTTP.ResponseHead) -> Result[Done]
  response = Response(status: head.status, headers: head.headers, body: NO_BYTES, url: Url.to_s(call.target))
  case call.streaming
    some(streaming) if not streaming.whole.call(response) -> try streamed(held, call, response, streaming)
    _ -> response = response.with(body: try read_all(held, call))
  end

  ok(Done(response: response, reusable: reusable?(call.method, head), expires_at: keep_alive_end(head.headers)))
end

# Gives the head to the caller, then each piece of the body to the reader, until its end.
def streamed(held: Held, call: Call, response: Response, streaming: Streaming) -> Result[Void]
  body: Channel[Result[Bytes]] = Channel.new(PIECES)
  head = Stream(status: response.status, headers: response.headers, url: response.url, body: body)
  _ = streaming.arrivals.send(Arrival.Head(head), 0)
  pumped = pump(held, call, body)
  body.close
  pumped
end

def pump(held: Held, call: Call, body: Channel[Result[Bytes]]) -> Result[Void]
  piece = try next_piece(held, call, body)
  while not piece.empty?
    return failure("the reader closed the body", "network") if not body.send(ok(piece), call.read_timeout_ms).ok?

    piece = try next_piece(held, call, body)
  end

  ok()
end

# The next piece of a streamed body, empty at its end. A failure goes to the reader too.
def next_piece(held: Held, call: Call, body: Channel[Result[Bytes]]) -> Result[Bytes]
  wait = Wait(ms: call.read_timeout_ms, kind: "timeout.read")
  case HTTP.read_body(waiting(held, wait), READ_BYTES)
    ok(piece) -> ok(piece)
    error(e) ->
      failed: Result[Bytes] = read_failure(e, wait, "the body did not come")
      _ = body.send(failed, call.read_timeout_ms)
      failed
  end
end

# A connection can take the next request when the server did not close it and the body had a known end: a length,
# chunks, or no body at all. A body that ends when the server closes leaves the connection closed.
def reusable?(method: String, head: HTTP.ResponseHead) -> Bool
  return false if says?(head, "connection", "close")
  return true if method == "HEAD" or head.status == 204 or head.status == 304

  says?(head, "transfer-encoding", "chunked") or not HTTP.header_values(head.headers, "content-length").empty?
end

def says?(head: HTTP.ResponseHead, name: String, word: String) -> Bool
  HTTP.header_values(head.headers, name).any? { |value| value.downcase.include?(word) }
end

def read_all(held: Held, call: Call) -> Result[Bytes]
  pieces: List[Bytes] = []
  total = 0
  while true
    wait = try next_wait(call, call.read_timeout_ms, "timeout.read")
    piece = NO_BYTES
    case HTTP.read_body(waiting(held, wait), READ_BYTES)
      ok(read) -> piece = read
      error(e) -> return read_failure(e, wait, "the body did not come")
    end

    break if piece.empty?

    total = total + piece.size
    if total > call.max_body_bytes
      return failure("the body is over max_body_bytes (#{call.max_body_bytes})", "too_large")
    end

    pieces = pieces.push(piece)
  end

  ok(Bytes.concat(pieces))
end

def waiting(held: Held, wait: Wait) -> HTTP.Connection
  held.conn.with(options: held.conn.options.with(timeout_ms: wait.ms))
end

# The wait of the next call: `limit_ms`, or less when the whole request has less left.
def next_wait(call: Call, limit_ms: Int, kind: String) -> Result[Wait]
  left = call.deadline - Time.monotonic_ms()
  return failure("the request timed out", "timeout.request") if left < 1
  return ok(Wait(ms: left, kind: "timeout.request")) if left < limit_ms

  ok(Wait(ms: limit_ms, kind: kind))
end

def read_failure[T](e: Error, wait: Wait, text: String) -> Result[T]
  return failure("#{text} within #{wait.ms} ms", wait.kind, some(e)) if e.is_a?("net.timeout")

  failure("the connection failed", "network", some(e))
end

# `Keep-Alive: timeout=N` says how long the server keeps an idle connection: past that (less a second, for the trip)
# the link ends it rather than send on a socket that may be closing. A timeout over a day counts as a day.
def keep_alive_end(headers: List[HTTP.Header]) -> Int
  for value in HTTP.header_values(headers, "keep-alive")
    for part in value.split(",")
      pair = part.strip.split("=")
      if pair.size == 2 and pair[0].strip.downcase == "timeout"
        case pair[1].strip.to_i
          ok(seconds) if seconds >= 0 ->
            kept_ms = [seconds, MAX_KEEP_ALIVE_S].min.unwrap! * 1000 - 1000
            return Time.monotonic_ms() + [kept_ms, 0].max.unwrap!
          _ -> nil
        end
      end
    end
  end

  0
end
