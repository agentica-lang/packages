## One request on a link of the pool: connect when the link is empty, send, read the whole body, and leave the
## connection in the link when it can take the next request.
##
## Until Agentica 0.34.0 (agentica#1710) a `HTTP.Connection` has one timeout, `options.timeout_ms`, for each call on
## it. `waiting` gives each call its own on a copy of the connection; the copy shares the socket and the state.

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

## What one request needs: where it goes, what it sends, and its limits. `deadline` is the monotonic time at which
## `timeout_ms` of the whole request runs out.
struct Call
  method: String
  target: Url.Target
  headers: List[HTTP.Header]
  body: Bytes
  connect_timeout_ms: Int
  read_timeout_ms: Int
  deadline: Int
  max_body_bytes: Int
  options: HTTP.ClientOptions
end

## Runs the request on the link. Any failure after the connection was made ends that connection, so the link is left
## empty, never with a connection in an unknown state.
def run(link: Link.Link, call: Call) -> Result[Response]
  held = try connection(link, call)
  case exchange(held, call)
    ok(done) ->
      if done.reusable
        Link.keep(link, held.with(expires_at: done.expires_at))
      else
        Link.release(link, held)
      end

      ok(done.response)
    error(e) ->
      Link.release(link, held)
      error(e)
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
NO_BYTES = "".bytes

struct Done
  response: Response
  reusable: Bool
  expires_at: Int
end

# How long the next wait may last, and which timeout ends it: the read timeout, or what is left of the whole request.
struct Wait
  ms: Int
  kind: String
end

def connection(link: Link.Link, call: Call) -> Result[Held]
  case Link.take(link)
    some(held) -> ok(held)
    none -> connect(link, call)
  end
end

def connect(link: Link.Link, call: Call) -> Result[Held]
  wait = try next_wait(call, call.connect_timeout_ms, "timeout.connect")
  case HTTP.start(call.target.origin, call.options.with(timeout_ms: wait.ms))
    ok(conn) -> ok(Link.hold(link, conn))
    error(e) if e.is_a?("net.timeout") -> failure("connecting to #{call.target.origin} timed out", wait.kind, some(e))
    error(e) -> failure("cannot connect to #{call.target.origin}", "network", some(e))
  end
end

def exchange(held: Held, call: Call) -> Result[Done]
  wait = try next_wait(call, call.read_timeout_ms, "timeout.read")
  sent = HTTP.send_request(waiting(held, wait), call.method, call.target.target, call.body, call.headers)
  head = try read_failure(sent, wait, "the response did not come")
  body = try read_all(held, call)
  connection_close = HTTP.header_values(head.headers, "connection").any? { |value| value.downcase.include?("close") }
  ok(
    Done(
      response: Response(status: head.status, headers: head.headers, body: body, url: Url.to_s(call.target)),
      reusable: not connection_close,
      expires_at: keep_alive_end(head.headers),
    ),
  )
end

def read_all(held: Held, call: Call) -> Result[Bytes]
  pieces: List[Bytes] = []
  total = 0
  while true
    wait = try next_wait(call, call.read_timeout_ms, "timeout.read")
    piece = try read_failure(HTTP.read_body(waiting(held, wait), READ_BYTES), wait, "the body did not come")
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

def read_failure[T](result: Result[T], wait: Wait, text: String) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) if e.is_a?("net.timeout") -> failure("#{text} within #{wait.ms} ms", wait.kind, some(e))
    error(e) -> failure("the connection failed", "network", some(e))
  end
end

# `Keep-Alive: timeout=N` says how long the server keeps an idle connection: past that (less a second, for the trip)
# the link ends it rather than send on a socket that may be closing.
def keep_alive_end(headers: List[HTTP.Header]) -> Int
  for value in HTTP.header_values(headers, "keep-alive")
    for part in value.split(",")
      pair = part.strip.split("=")
      if pair.size == 2 and pair[0].strip.downcase == "timeout"
        case pair[1].strip.to_i
          ok(seconds) if seconds >= 0 -> return Time.monotonic_ms() + [seconds * 1000 - 1000, 0].max.unwrap!
          _ -> nil
        end
      end
    end
  end

  0
end
