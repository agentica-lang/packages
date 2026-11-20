## One request on a link of the pool: on the link's idle connection or a new one, send, read the whole body, and leave
## the connection in the link when it can take the next request.
##
## A `HTTP.Connection` takes its timeouts from its options: `timeout_ms` for each `send_request` (the write and the
## head) and `read_timeout_ms` for each `read_body`. `sending` and `reading` give each call its own on a copy of the
## connection; the copy shares the socket and the state. The call that sends the request also reads the response head,
## so the client's `read_timeout_ms` covers the send too, and its `body_idle_ms` goes in the copy of each body read.

import H2 from "http2/connection"
import {Protocol} from "protocol"
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

## The head of a streamed response, and the channel of its body: `ok(piece)` for each piece as it comes, then one
## `error` if the body fails or is cut short, and the close at its end. The body holds one piece at a time, which the
## reader has `read_timeout_ms` to take, unless `relayed` is closed: the reader is then the relay of the events, which
## holds its own reader to that time. `relay_down` gets a value when that relay task ends, however it ends. `ended`
## closes once the task of the body gave its last piece or its error, so a cancel that finds it open has a read to
## interrupt.
struct Head
  status: Int
  headers: List[HTTP.Header]
  url: String
  body: Channel[Result[Bytes]]
  relayed: Channel[Bool]
  relay_down: Channel[Bool]
  ended: Channel[Bool]
end

## What reaches the caller of a try: the head of a streamed response, and the end of the task of the try.
enum Arrival
  Head(Head)
  Over
end

## How a call streams: `whole` says which responses are read whole all the same (given with their head only), the
## head of a streamed one goes to `arrivals`, and the body stops when `stopping` closes (the client closes).
struct Streaming
  whole: Fn[Response, Bool]
  arrivals: Channel[Arrival]
  stopping: Channel[Bool]
end

## What one request needs: where it goes, what it sends, and its limits. `read_timeout_ms` is the time of the send
## and of the head, and `body_idle_ms` the longest the body may stay silent (0 for none), cut to what is left of the
## deadline for a buffered one. `deadline` is the monotonic time at which `timeout_ms` of the whole request runs out;
## it does not bound the body of a streamed response.
struct Call
  method: String
  target: Url.Target
  headers: List[HTTP.Header]
  body: Bytes
  connect_timeout_ms: Int
  read_timeout_ms: Int
  body_idle_ms: Int
  deadline: Int
  max_body_bytes: Int
  streaming: Optional[Streaming]
end

## Runs the request on the link: on its idle connection, or on a new one. When std/http finds that the idle
## connection is closed before it writes a byte, the request goes once more on a new connection. A request that was
## never written leaves the connection in the link; any other failure ends it.
def run(link: Link.Link, call: Call) -> Result[Response]
  return run_h2(link, call) if link.protocol == Protocol.Http2
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

## Ends `channel` with `failed`, in the place kept free for it (a channel of 2 that is given one value at a time), and
## closes it.
def cut[T](channel: Channel[Result[T]], failed: Error) -> Void
  _ = channel.send(error(failed), 0)
  channel.close
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
# A year, past any deadline: a body with no idle limit is bounded by the whole request alone.
LONGEST_WAIT_MS = 31_536_000_000
# A streamed body holds one piece, and a place for the error that ends it; how often the pump looks whether the reader
# took the piece. (A close with a reason, agentica#1790, will make the place for the error needless.)
BODY_PLACES = 2
TAKE_POLL_MS = 5
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

def run_h2(link: Link.Link, call: Call) -> Result[Response]
  request = H2.Request(
    method: call.method,
    target: call.target,
    headers: call.headers,
    body: call.body,
    read_timeout_ms: call.read_timeout_ms,
    body_idle_ms: call.body_idle_ms,
    deadline: call.deadline,
    max_body_bytes: call.max_body_bytes,
  )

  response = try Link.submit(link, request, call.connect_timeout_ms)
  ok(Response(status: response.status, headers: response.headers, body: response.body, url: Url.to_s(call.target)))
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
      head = HTTP.send_request(sending(held, wait), call.method, call.target.target, call.body, call.headers)
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

    error(e) if HTTP.read_body(reading(held, wait), 1).ok? ->
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

# Gives the head to the caller, then each piece of the body to the reader, until its end. A failure, of the body or
# of the reader, ends the channel with its error.
def streamed(held: Held, call: Call, response: Response, streaming: Streaming) -> Result[Void]
  body: Channel[Result[Bytes]] = Channel.new(BODY_PLACES)
  relayed: Channel[Bool] = Channel.new(1)
  relay_down: Channel[Bool] = Channel.new(1)
  ended: Channel[Bool] = Channel.new(1)
  head = Head(
    status: response.status,
    headers: response.headers,
    url: response.url,
    body: body,
    relayed: relayed,
    relay_down: relay_down,
    ended: ended,
  )

  _ = streaming.arrivals.send(Arrival.Head(head), 0)
  # `ended` closes before the body, and before anything that waits, so that a cancel that sees it open cancels a task
  # that is still reading, and never one that is only putting the connection back in the pool.
  case pump(held, call, head, streaming.stopping)
    ok(_) ->
      ended.close
      body.close
      ok()
    error(e) ->
      ended.close
      cut(body, e)
      error(e)
  end
end

def pump(held: Held, call: Call, head: Head, stopping: Channel[Bool]) -> Result[Void]
  given_at = 0
  piece = try next_piece(held, call, stopping)
  while not piece.empty?
    handed = try hand(head, piece, given_at, call.read_timeout_ms, stopping)
    given_at = handed
    piece = try next_piece(held, call, stopping)
  end

  ok()
end

# Gives `piece` once the reader took the last one, given at `given_at`, and says when. A reader that took nothing for
# `wait_ms` is an `http_client.timeout.read` error, and a closed body or client an `http_client.closed` one. A relay
# that ended without closing the body (its task was cancelled, or crashed) counts as a closed body.
def hand(head: Head, piece: Bytes, given_at: Int, wait_ms: Int, stopping: Channel[Bool]) -> Result[Int]
  while not head.body.empty? and not head.body.closed? and not stopping.closed? and head.relay_down.empty?
    if not head.relayed.closed? and Time.monotonic_ms() - given_at >= wait_ms
      return failure("the reader took no piece for #{wait_ms} ms", "timeout.read")
    end

    Task.sleep(TAKE_POLL_MS)
  end

  return failure("the reader closed the stream", "closed") if head.body.closed?
  return failure("the reader of the events ended", "closed") if not head.relay_down.empty?
  return failure("the client is closed", "closed") if stopping.closed?

  case head.body.send(ok(piece), 0)
    ok(_) -> ok(Time.monotonic_ms())
    error(e) -> failure("the reader closed the stream", "closed", some(e))
  end
end

# The next piece of a streamed body, empty at its end. A read that fails once the client closed is that close. The
# whole request does not bound it, and its idle limit of 0 is no limit at all (std/http reads a 0 timeout as none).
def next_piece(held: Held, call: Call, stopping: Channel[Bool]) -> Result[Bytes]
  wait = Wait(ms: call.body_idle_ms, kind: "timeout.read")
  case HTTP.read_body(reading(held, wait), READ_BYTES)
    ok(piece) -> ok(piece)
    error(e) if stopping.closed? -> failure("the client is closed", "closed", some(e))
    error(e) -> read_failure(e, wait, "the body did not come")
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
    wait = try body_wait(call)
    piece = NO_BYTES
    case HTTP.read_body(reading(held, wait), READ_BYTES)
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

def sending(held: Held, wait: Wait) -> HTTP.Connection
  held.conn.with(options: held.conn.options.with(timeout_ms: wait.ms))
end

def reading(held: Held, wait: Wait) -> HTTP.Connection
  held.conn.with(options: held.conn.options.with(read_timeout_ms: wait.ms))
end

# The wait of the next call: `limit_ms`, or less when the whole request has less left.
def next_wait(call: Call, limit_ms: Int, kind: String) -> Result[Wait]
  left = call.deadline - Time.monotonic_ms()
  return failure("the request timed out", "timeout.request") if left < 1
  return ok(Wait(ms: left, kind: "timeout.request")) if left < limit_ms

  ok(Wait(ms: limit_ms, kind: kind))
end

# The wait of the next read of a buffered body: its idle limit, or the rest of the whole request when it has none.
def body_wait(call: Call) -> Result[Wait]
  return next_wait(call, call.body_idle_ms, "timeout.read") if call.body_idle_ms > 0

  next_wait(call, LONGEST_WAIT_MS, "timeout.read")
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
