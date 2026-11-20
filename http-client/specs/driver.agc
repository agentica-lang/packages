## The program under test of the features: it holds the client, the peers it talks to and the requests in flight, and
## runs the requests that `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out.

import HTTP from "std/http"
import HttpClient from "../http_client"
import Protocol from "protocol"
import URI from "std/uri"
import {Call, Check, Expectation, How, Reads, Request, Setup} from "protocol"

private

# The peers are programs of their own, so that they share nothing with the client under test.
SERVER = "fixtures/server.agc"
RAW = "fixtures/raw_peer.agc"
PEER_START_MS = 60_000
WAIT_MS = 30_000
QUIET_MS = 500
# How long the resolver answers a name whose address is `hang`: longer than any scenario.
HANG_MS = 60_000
# A started request's task stays until it is cancelled or the driver ends, as a caller's task would.
LINGER_MS = 600_000

# The outcome of a request: its result, how long it took, and for a stream how long its first piece took. A stream
# reads as a response whose body is its pieces, and events as one whose body is `event:data` of each (a newline as
# `/`), joined by `|`.
struct Outcome
  result: Result[HttpClient.Response]
  elapsed: Int
  first: Int = 0
end

# A request in its task, which sends its outcome and then stays until `stop` closes.
struct Running
  task: Task[Void]
  outcome: Channel[Outcome]
end

struct Driver
  peers: Map[String, String]
  processes: Map[String, Process]
  seen: Map[String, Int]
  client: Optional[HttpClient.Client]
  running: Map[String, Running]
  outcomes: Map[String, Outcome]
  stop: Channel[Bool]
  asked: ATS[String, Int]
end

struct Handled
  driver: Driver
  reply: String
end

# What the body of `/json` decodes to.
struct Person
  name: String
  age: Int
end

# How a stream is read: to its end, only its first piece, or with `HttpClient.cancel` after the last piece or after the
# first one.
enum Reading
  Whole
  First
  Cancelled
  CancelledFirst
end

def main() -> Void
  stop: Channel[Bool] = Channel.new(1)
  asked: ATS[String, Int] = ATS.new()
  driver = Driver(
    peers: {},
    processes: {},
    seen: {},
    client: none,
    running: {},
    outcomes: {},
    stop: stop,
    asked: asked,
  )

  line = IO.gets
  while line.ok?
    handled = handle(driver, line.unwrap_or(""))
    driver = handled.driver
    puts(handled.reply.replace("\n", "\\n"))
    IO.flush()
    line = IO.gets
  end

  stop.close
end

def handle(driver: Driver, line: String) -> Handled
  case JSON.decode(line, Request)
    ok(req) -> run(driver, req)
    error(e) -> Handled(driver: driver, reply: "bad request: #{e.message}")
  end
end

def run(driver: Driver, req: Request) -> Handled
  case req
    Request.Server(name) -> start_peer(driver, name, SERVER, [])
    Request.TlsServer(name) -> start_peer(driver, name, SERVER, ["tls"])
    Request.Raw(script) ->
      start_peer(driver, script.name, RAW, script.text.split("\n").select { |line| not line.strip.empty? })
    Request.Client(setup) -> make_client(driver, setup)
    Request.Send(call) -> send(driver, call)
    Request.Start(call) -> started(driver, call)
    Request.Wait(name) -> waited(driver, name)
    Request.Cancel(name) ->
      case driver.running.get(name)
        some(running) -> Task.cancel(running.task)
        none -> nil
      end

      done(driver)
    Request.DeadPort(name) ->
      listener = TCP.listen("127.0.0.1", 0).unwrap!
      address = "http://127.0.0.1:#{TCP.local_port(listener)}"
      TCP.close_listener(listener)
      done(driver.with(peers: driver.peers.put(name, address)))
    Request.Read(reads) -> read_requests(driver, reads)
    Request.Asked(count) ->
      times = driver.asked.to_map.values.sum
      if times == count
        done(driver)
      else
        failed(driver, "the resolver was asked #{times} times")
      end

    Request.ReadOnly(reads) ->
      handled = read_requests(driver, reads)
      if handled.reply == Protocol.OK
        no_more(handled.driver, reads.name)
      else
        handled
      end

    Request.Sleep(ms) ->
      Task.sleep(ms)
      done(driver)
    Request.Close ->
      case driver.client
        some(client) -> HttpClient.close(client)
        none -> nil
      end

      done(driver)
    Request.Expect(expectation) -> expect(driver, expectation)
  end
end

def done(driver: Driver) -> Handled = Handled(driver: driver, reply: Protocol.OK)

def failed(driver: Driver, text: String) -> Handled = Handled(driver: driver, reply: text)

def start_peer(driver: Driver, name: String, program: String, script: List[String]) -> Handled
  agentica = System.env("HTTP_CLIENT_AGENTICA").unwrap_or("agentica")
  case Process.spawn(agentica, [program] + script)
    ok(peer) ->
      case Process.read_line(peer, PEER_START_MS)
        ok(line) ->
          address = "http://127.0.0.1:#{line.split(" ").last}"
          done(driver.with(peers: driver.peers.put(name, address), processes: driver.processes.put(name, peer)))
        error(e) -> failed(driver, "the peer did not start: #{e.message}")
      end

    error(e) -> failed(driver, "the peer did not start: #{e.message}")
  end
end

def make_client(driver: Driver, setup: Setup) -> Handled
  base = driver.peers.get(setup.name).unwrap_or("")
  settings: Map[String, Int] = {}
  headers: List[HTTP.Header] = []
  names: Map[String, List[String]] = {}
  tls: Optional[TLS.Context] = none
  params: List[URI.Pair] = []
  request_steps: List[Fn[HttpClient.Request, Result[HttpClient.Request]]] = []
  response_steps: List[Fn[HttpClient.Response, Result[HttpClient.Response]]] = []
  for row in setup.table.drop(1)
    if row[0] == "header"
      headers = headers.push(header(row[1]))
    elsif row[0] == "param"
      params = params.push(pair(row[1]))
    elsif row[0] == "basic"
      credentials = row[1].split(":")
      headers = headers.push(HttpClient.basic_auth(credentials[0], credentials[1]).unwrap!)
    elsif row[0] == "bearer"
      headers = headers.push(HttpClient.bearer_auth(row[1]))
    elsif row[0] == "request_step"
      added = header(row[1])
      request_steps = request_steps.push(->(request) { ok(request.with(headers: request.headers.push(added))) })
    elsif row[0] == "response_step"
      response_steps = response_steps.push(&error_status)
    elsif row[0] == "resolve"
      pair = row[1].split("=")
      names = names.put(pair[0], pair[1].split(","))
    elsif row[0] == "ca"
      tls = some(TLS.client_context(TLS.ClientOptions(ca_file: row[1])).unwrap!)
    else
      settings = settings.put(row[0], row[1].to_i!)
    end
  end

  resolver: Optional[Fn[String, Result[List[String]]]] = none
  if not names.empty?
    resolver = some(resolver_of(names, driver.asked))
  end

  made = HttpClient.new(
    base_url: base,
    headers: headers,
    params: params,
    connect_timeout_ms: settings.get("connect_timeout_ms").unwrap_or(10_000),
    read_timeout_ms: settings.get("read_timeout_ms").unwrap_or(30_000),
    body_idle_ms: settings.get("body_idle_ms"),
    timeout_ms: settings.get("timeout_ms").unwrap_or(60_000),
    max_body_bytes: settings.get("max_body_bytes").unwrap_or(16_777_216),
    max_retries: settings.get("max_retries").unwrap_or(0),
    retry_delay_ms: settings.get("retry_delay_ms").unwrap_or(10),
    max_retry_delay_ms: settings.get("max_retry_delay_ms").unwrap_or(30_000),
    max_redirects: settings.get("max_redirects").unwrap_or(10),
    decompress: settings.get("decompress").unwrap_or(1) == 1,
    request_steps: request_steps,
    response_steps: response_steps,
    pool_size: settings.get("pool_size").unwrap_or(10),
    pool_timeout_ms: settings.get("pool_timeout_ms").unwrap_or(5_000),
    idle_ms: settings.get("idle_ms").unwrap_or(30_000),
    resolver: resolver,
    dns_cache_ms: settings.get("dns_cache_ms").unwrap_or(10_000),
    public_only: settings.get("public_only").unwrap_or(0) == 1,
    tls: tls,
  )

  case made
    ok(client) -> done(driver.with(client: some(client)))
    error(e) -> failed(driver, "the client was not made: #{e.message}")
  end
end

# A resolver that knows only `names` and counts each question in `asked`. A name of `hang` never gets its answer.
def resolver_of(names: Map[String, List[String]], asked: ATS[String, Int]) -> Fn[String, Result[List[String]]]
  ->(host) { answer(names, asked, host) }
end

def answer(names: Map[String, List[String]], asked: ATS[String, Int], host: String) -> Result[List[String]]
  _ = asked.add(host, 1)
  case names.get(host)
    some(addresses) if addresses == ["hang"] ->
      Task.sleep(HANG_MS)
      ok([])
    some(addresses) -> ok(addresses)
    none -> error("network: host not found: #{host}", kind: "net.host_not_found")
  end
end

def error_status(response: HttpClient.Response) -> Result[HttpClient.Response]
  return error("status #{response.status}", kind: "status") if response.status >= 400

  ok(response)
end

def pair(text: String) -> URI.Pair
  parts = text.split("=")
  URI.Pair(name: parts[0], value: parts.drop(1).join("="))
end

def header(text: String) -> HTTP.Header
  parts = text.split(": ")
  HTTP.Header(name: parts[0], value: parts.drop(1).join(": "))
end

# Waits until the raw peer has printed its `number`th `request` line.
def read_requests(driver: Driver, reads: Reads) -> Handled
  peer = driver.processes.get(reads.name)
  return failed(driver, "no peer #{reads.name}") if not peer.some?

  seen = driver.seen.get(reads.name).unwrap_or(0)
  while seen < reads.count
    case Process.read_line(peer.unwrap!, WAIT_MS)
      ok(line) if line.start_with?("request ") -> seen = seen + 1
      ok(_) -> nil
      error(e) -> return failed(driver, "#{reads.name} read #{seen} requests: #{e.message}")
    end
  end

  done(driver.with(seen: driver.seen.put(reads.name, seen)))
end

# Checks that the raw peer reads no further request within a while.
def no_more(driver: Driver, name: String) -> Handled
  peer = driver.processes.get(name).unwrap!
  case Process.read_line(peer, QUIET_MS)
    ok(line) if line.start_with?("request ") -> failed(driver, "#{name} read one more: #{line}")
    _ -> done(driver)
  end
end

def send(driver: Driver, call: Call) -> Handled
  started_one = started(driver, call)
  return started_one if started_one.reply != Protocol.OK

  waited(started_one.driver, call.name)
end

def started(driver: Driver, call: Call) -> Handled
  case start_request(driver, call)
    ok(running) -> done(driver.with(running: driver.running.put(call.name, running)))
    error(e) -> failed(driver, e.message)
  end
end

def waited(driver: Driver, name: String) -> Handled
  case driver.running.get(name)
    some(running) ->
      case running.outcome.recv(WAIT_MS)
        ok(outcome) -> done(driver.with(outcomes: driver.outcomes.put(name, outcome)))
        error(_) -> failed(driver, "#{name} did not end")
      end

    none -> failed(driver, "no request #{name} runs")
  end
end

def start_request(driver: Driver, call: Call) -> Result[Running]
  client = try driver.client.to_result("no client")
  url = addressed(driver, call.url)

  headers: List[HTTP.Header] = []
  if not call.header.empty?
    headers = [header(call.header)]
  end

  params: List[URI.Pair] = []
  if not call.param.empty?
    params = [pair(call.param)]
  end

  body: Optional[Bytes] = none
  if not call.body.empty?
    body = some(call.body.bytes)
  end

  json: Optional[JSON.Value] = none
  if not call.json.empty?
    json = some(try JSON.parse(call.json))
  end

  outcome: Channel[Outcome] = Channel.new(1)
  stop = driver.stop
  task = Task.spawn do
    began = Time.monotonic_ms()
    done = Outcome(result: error("no request"), elapsed: 0)
    case call.how
      How.Stream ->
        streamed = HttpClient.stream(client, call.method, url, headers: headers)
        pause(call.wait_ms)
        done = read_stream(streamed, began, Reading.Whole, call.pace_ms, "")
      How.StreamFirst ->
        done = read_stream(HttpClient.stream(client, call.method, url, headers: headers), began, Reading.First, 0, "")
      How.StreamCancel ->
        streamed = HttpClient.stream(client, call.method, url, headers: headers)
        pause(call.wait_ms)
        done = read_stream(streamed, began, Reading.Cancelled, 0, "")
      How.StreamCancelFirst ->
        streamed = HttpClient.stream(client, call.method, url, headers: headers)
        done = read_stream(streamed, began, Reading.CancelledFirst, 0, "")
      How.StreamReleased ->
        released = HttpClient.stream(client, call.method, url, headers: headers)
        done = read_stream(released, began, Reading.Whole, 0, addressed(driver, "{#{call.release}}/release"))
      How.Events ->
        events = HttpClient.get_events(client, url, headers: headers)
        pause(call.wait_ms)
        done = read_events(events, began, call.pace_ms)
      How.EventsAbandoned ->
        result: Result[HttpClient.Response] = error("no stream")
        case HttpClient.stream(client, "GET", url, headers: headers)
          ok(streamed) ->
            crash = call.crash
            reader: Task[Result[Void]] = Task.spawn do abandoned(streamed, crash) end
            if not crash
              pause(call.wait_ms)
              Task.cancel(reader)
            end

            _ = Task.await(reader, WAIT_MS)
            result = ok(HttpClient.Response(status: 200, headers: [], body: "".bytes, url: url))
          error(e) -> result = error(e)
        end

        done = Outcome(result: result, elapsed: 0)
      How.EventsTwice ->
        case HttpClient.stream(client, "GET", url, headers: headers)
          ok(streamed) ->
            first = HttpClient.events(streamed)
            done = read_events(ok(HttpClient.events(streamed)), began, 0)
            first.close
          error(e) -> done = Outcome(result: error(e), elapsed: 0)
        end

      How.EventsClosed ->
        result: Result[HttpClient.Response] = error("no events")
        case HttpClient.get_events(client, url, headers: headers)
          ok(events) ->
            Task.sleep(call.wait_ms)
            events.close
            result = ok(HttpClient.Response(status: 200, headers: [], body: "".bytes, url: url))
          error(e) -> result = error(e)
        end

        done = Outcome(result: result, elapsed: 0)
      How.Plain ->
        result = HttpClient.request(client, call.method, url, body: body, json: json, params: params, headers: headers)
        done = Outcome(result: result, elapsed: Time.monotonic_ms() - began)
    end

    _ = outcome.send(done.with(elapsed: Time.monotonic_ms() - began), 0)
    _ = stop.recv(LINGER_MS)
  end

  ok(Running(task: task, outcome: outcome))
end

# Reads the pieces of the stream as `how` says: to its end, or only its first one before it closes the body, or with
# `HttpClient.cancel` after the last piece or after the first one.
def read_stream(
  streamed: Result[HttpClient.Stream],
  began: Int,
  how: Reading,
  pace_ms: Int,
  release_url: String,
) -> Outcome
  case streamed
    ok(stream) ->
      pieces: List[Bytes] = []
      first = 0
      next_piece = stream.body.recv(WAIT_MS)
      while next_piece.ok?
        case next_piece.unwrap!
          ok(piece) -> pieces = pieces.push(piece)
          error(e) -> return Outcome(result: error(e), elapsed: 0)
        end

        if first == 0
          first = Time.monotonic_ms() - began
          if not release_url.empty?
            _ = HTTP.get_response(release_url)
          end
        end

        pause(pace_ms)

        if how == Reading.First
          stream.body.close
          break
        end

        if how == Reading.CancelledFirst and pieces.size == 1
          HttpClient.cancel(stream)
        end

        next_piece = stream.body.recv(WAIT_MS)
      end

      if how == Reading.Cancelled
        HttpClient.cancel(stream)
      end

      response = HttpClient.Response(
        status: stream.status,
        headers: stream.headers,
        body: Bytes.concat(pieces),
        url: stream.url,
      )

      Outcome(result: ok(response), elapsed: 0, first: first)
    error(e) -> Outcome(result: error(e), elapsed: 0)
  end
end

# Reads one event in a task of its own, then crashes, or waits to be cancelled: either way the relay of the events ends
# with this task.
def abandoned(stream: HttpClient.Stream, crash: Bool) -> Result[Void]
  events = HttpClient.events(stream)
  _ = events.recv(WAIT_MS)
  if crash
    _ = "not a number".to_i!
  end

  Task.sleep(LINGER_MS)
  ok()
end

# Waits `ms`, or not at all: even a sleep of 0 hands the turn to the other tasks.
def pause(ms: Int) -> Void
  if ms > 0
    Task.sleep(ms)
  end
end

def read_events(events: Result[Channel[Result[HttpClient.Event]]], began: Int, pace_ms: Int) -> Outcome
  case events
    ok(channel) ->
      seen: List[String] = []
      first = 0
      next_event = channel.recv(WAIT_MS)
      while next_event.ok?
        case next_event.unwrap!
          ok(event) -> seen = seen.push("#{event.event}:#{event.data.replace("\n", "/")}")
          error(e) -> return Outcome(result: error(e), elapsed: 0)
        end

        if first == 0
          first = Time.monotonic_ms() - began
        end

        pause(pace_ms)

        next_event = channel.recv(WAIT_MS)
      end

      response = HttpClient.Response(status: 200, headers: [], body: seen.join("|").bytes, url: "")
      Outcome(result: ok(response), elapsed: 0, first: first)
    error(e) -> Outcome(result: error(e), elapsed: 0)
  end
end

def expect(driver: Driver, expectation: Expectation) -> Handled
  case driver.outcomes.get(expectation.name)
    some(outcome) -> Handled(driver: driver, reply: check(driver, expectation, outcome))
    none -> failed(driver, "no outcome for #{expectation.name}")
  end
end

def check(driver: Driver, expectation: Expectation, outcome: Outcome) -> String
  name = expectation.name
  wanted = expectation.check
  case wanted
    Check.Within(ms) -> timed(name, outcome.elapsed < ms, outcome)
    Check.After(ms) -> timed(name, outcome.elapsed >= ms, outcome)
    Check.Status(_) -> check_result(driver, name, wanted, outcome.result)
    Check.Body(_) -> check_result(driver, name, wanted, outcome.result)
    Check.Size(_) -> check_result(driver, name, wanted, outcome.result)
    Check.Header(_) -> check_result(driver, name, wanted, outcome.result)
    Check.Url(_) -> check_result(driver, name, wanted, outcome.result)
    Check.Decoded(_) -> check_result(driver, name, wanted, outcome.result)
    Check.Kind(_) -> check_result(driver, name, wanted, outcome.result)
  end
end

def timed(name: String, fits: Bool, outcome: Outcome) -> String
  return Protocol.OK if fits

  "#{name} took #{outcome.elapsed} ms"
end

# A check of what the request gave: a response is looked at by `holds?`, and an error is only what `Kind` expects.
def check_result(driver: Driver, name: String, wanted: Check, result: Result[HttpClient.Response]) -> String
  case result
    ok(response) -> check_response(driver, name, wanted, response)
    error(e) -> check_error(name, wanted, e)
  end
end

def check_error(name: String, wanted: Check, e: Error) -> String
  return Protocol.OK if kind_matches?(wanted, e)

  "#{name} failed: #{e.kind} #{e.message}"
end

def check_response(driver: Driver, name: String, wanted: Check, response: HttpClient.Response) -> String
  return Protocol.OK if holds?(driver, wanted, response)

  text = String.from_bytes(response.body).unwrap_or("<binary>")
  "#{name}: #{response.status} #{response.url} #{response.headers} #{text}"
end

# Only `Kind` can be met by an error: its kind starts with the text.
def kind_matches?(wanted: Check, e: Error) -> Bool
  case wanted
    Check.Kind(start) -> e.kind.start_with?(start)
    Check.Status(_) -> false
    Check.Body(_) -> false
    Check.Size(_) -> false
    Check.Header(_) -> false
    Check.Url(_) -> false
    Check.Decoded(_) -> false
    Check.Within(_) -> false
    Check.After(_) -> false
  end
end

# What a response must be for the check; `Kind`, `Within` and `After` are not about a response.
def holds?(driver: Driver, wanted: Check, response: HttpClient.Response) -> Bool
  case wanted
    Check.Status(status) -> response.status == status
    Check.Body(text) -> String.from_bytes(response.body).unwrap_or("") == addressed(driver, text)
    Check.Header(text) -> has_header?(response, header(addressed(driver, text)))
    Check.Url(text) -> response.url == addressed(driver, text)
    Check.Size(size) -> response.body.size == size
    Check.Decoded(text) -> decoded(response) == addressed(driver, text)
    Check.Kind(_) -> false
    Check.Within(_) -> false
    Check.After(_) -> false
  end
end

def decoded(response: HttpClient.Response) -> String
  case HttpClient.decode(response, Person.codec)
    ok(person) -> "#{person.name} #{person.age}"
    error(e) -> e.kind
  end
end

def has_header?(response: HttpClient.Response, wanted: HTTP.Header) -> Bool
  HTTP.header_values(response.headers, wanted.name).include?(wanted.value)
end

# `text` with `{name}` replaced by the address of the peer `name`.
def addressed(driver: Driver, text: String) -> String
  done_text = text
  for name in driver.peers.keys
    address = driver.peers.get(name).unwrap_or("")
    done_text = done_text.replace("{#{name}}", address).replace("{#{name}:port}", address.split(":").last)
  end

  done_text
end
