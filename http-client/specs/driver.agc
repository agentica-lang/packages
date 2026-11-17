## The program under test of the features: it holds the client, the peers it talks to and the requests in flight, and
## runs the requests that `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out.

import HTTP from "std/http"
import HttpClient from "../http_client"
import Protocol from "protocol"
import {Request} from "protocol"

private

# The peers are programs of their own, so that they share nothing with the client under test.
PEERS = {"server": "fixtures/server.agc", "tls_server": "fixtures/server.agc", "raw": "fixtures/raw_peer.agc"}
PEER_START_MS = 60_000
WAIT_MS = 30_000
QUIET_MS = 500
# A started request's task stays until it is cancelled or the driver ends, as a caller's task would.
LINGER_MS = 600_000

# The outcome of a request: its result and how long it took.
struct Outcome
  result: Result[HttpClient.Response]
  elapsed: Int
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
  case req.op
    "peer" -> start_peer(driver, req)
    "client" -> make_client(driver, req)
    "send" -> send(driver, req)
    "start" -> started(driver, req)
    "wait" -> waited(driver, req.name)
    "cancel" ->
      case driver.running.get(req.name)
        some(running) -> Task.cancel(running.task)
        none -> nil
      end

      done(driver)
    "dead_port" ->
      listener = TCP.listen("127.0.0.1", 0).unwrap!
      address = "http://127.0.0.1:#{TCP.local_port(listener)}"
      TCP.close_listener(listener)
      done(driver.with(peers: driver.peers.put(req.name, address)))
    "read" -> read_requests(driver, req)
    "asked" ->
      times = driver.asked.to_map.values.sum
      if times == req.number
        done(driver)
      else
        failed(driver, "the resolver was asked #{times} times")
      end

    "read_only" ->
      handled = read_requests(driver, req)
      if handled.reply == Protocol.OK
        no_more(handled.driver, req.name)
      else
        handled
      end

    "sleep" ->
      Task.sleep(req.number)
      done(driver)
    "close" ->
      case driver.client
        some(client) -> HttpClient.close(client)
        none -> nil
      end

      done(driver)
    _ -> expect(driver, req)
  end
end

def done(driver: Driver) -> Handled = Handled(driver: driver, reply: Protocol.OK)

def failed(driver: Driver, text: String) -> Handled = Handled(driver: driver, reply: text)

def start_peer(driver: Driver, req: Request) -> Handled
  program = PEERS.get(req.kind).unwrap_or("")
  script = req.text.split("\n").select { |line| not line.strip.empty? }
  if req.kind == "tls_server"
    script = ["tls"]
  end

  agentica = System.env("HTTP_CLIENT_AGENTICA").unwrap_or("agentica")
  case Process.spawn(agentica, [program] + script)
    ok(peer) ->
      case Process.read_line(peer, PEER_START_MS)
        ok(line) ->
          address = "http://127.0.0.1:#{line.split(" ").last}"
          done(
            driver.with(peers: driver.peers.put(req.name, address), processes: driver.processes.put(req.name, peer)),
          )
        error(e) -> failed(driver, "the peer did not start: #{e.message}")
      end

    error(e) -> failed(driver, "the peer did not start: #{e.message}")
  end
end

def make_client(driver: Driver, req: Request) -> Handled
  base = driver.peers.get(req.name).unwrap_or("")
  settings: Map[String, Int] = {}
  headers: List[HTTP.Header] = []
  names: Map[String, List[String]] = {}
  tls: Optional[TLS.Context] = none
  for row in req.table.drop(1)
    if row[0] == "header"
      headers = headers.push(header(row[1]))
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
    connect_timeout_ms: settings.get("connect_timeout_ms").unwrap_or(10_000),
    read_timeout_ms: settings.get("read_timeout_ms").unwrap_or(30_000),
    timeout_ms: settings.get("timeout_ms").unwrap_or(60_000),
    max_body_bytes: settings.get("max_body_bytes").unwrap_or(16_777_216),
    max_retries: settings.get("max_retries").unwrap_or(0),
    retry_delay_ms: settings.get("retry_delay_ms").unwrap_or(10),
    max_retry_delay_ms: settings.get("max_retry_delay_ms").unwrap_or(30_000),
    max_redirects: settings.get("max_redirects").unwrap_or(10),
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

# A resolver that knows only `names` and counts each question in `asked`.
def resolver_of(names: Map[String, List[String]], asked: ATS[String, Int]) -> Fn[String, Result[List[String]]]
  ->(host) { answer(names, asked, host) }
end

def answer(names: Map[String, List[String]], asked: ATS[String, Int], host: String) -> Result[List[String]]
  _ = asked.add(host, 1)
  case names.get(host)
    some(addresses) -> ok(addresses)
    none -> error("network: host not found: #{host}", kind: "net.host_not_found")
  end
end

def header(text: String) -> HTTP.Header
  parts = text.split(": ")
  HTTP.Header(name: parts[0], value: parts.drop(1).join(": "))
end

# Waits until the raw peer has printed its `number`th `request` line.
def read_requests(driver: Driver, req: Request) -> Handled
  peer = driver.processes.get(req.name)
  return failed(driver, "no peer #{req.name}") if not peer.some?

  seen = driver.seen.get(req.name).unwrap_or(0)
  while seen < req.number
    case Process.read_line(peer.unwrap!, WAIT_MS)
      ok(line) if line.start_with?("request ") -> seen = seen + 1
      ok(_) -> nil
      error(e) -> return failed(driver, "#{req.name} read #{seen} requests: #{e.message}")
    end
  end

  done(driver.with(seen: driver.seen.put(req.name, seen)))
end

# Checks that the raw peer reads no further request within a while.
def no_more(driver: Driver, name: String) -> Handled
  peer = driver.processes.get(name).unwrap!
  case Process.read_line(peer, QUIET_MS)
    ok(line) if line.start_with?("request ") -> failed(driver, "#{name} read one more: #{line}")
    _ -> done(driver)
  end
end

def send(driver: Driver, req: Request) -> Handled
  started_one = started(driver, req)
  return started_one if started_one.reply != Protocol.OK

  waited(started_one.driver, req.name)
end

def started(driver: Driver, req: Request) -> Handled
  case start_request(driver, req)
    ok(running) -> done(driver.with(running: driver.running.put(req.name, running)))
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

def start_request(driver: Driver, req: Request) -> Result[Running]
  client = try driver.client.to_result("no client")
  url = addressed(driver, req.text)

  headers: List[HTTP.Header] = []
  if not req.header.empty?
    headers = [header(req.header)]
  end

  outcome: Channel[Outcome] = Channel.new(1)
  stop = driver.stop
  task = Task.spawn do
    began = Time.monotonic_ms()
    result = HttpClient.request(client, req.kind, url, req.body.bytes, headers)
    _ = outcome.send(Outcome(result: result, elapsed: Time.monotonic_ms() - began), 0)
    _ = stop.recv(LINGER_MS)
  end

  ok(Running(task: task, outcome: outcome))
end

def expect(driver: Driver, req: Request) -> Handled
  case driver.outcomes.get(req.name)
    some(outcome) -> Handled(driver: driver, reply: check(req.with(text: addressed(driver, req.text)), outcome))
    none -> failed(driver, "no outcome for #{req.name}")
  end
end

def check(req: Request, outcome: Outcome) -> String
  if req.op == "expect_within"
    return Protocol.OK if outcome.elapsed < req.number

    return "#{req.name} took #{outcome.elapsed} ms"
  end

  if req.op == "expect_after"
    return Protocol.OK if outcome.elapsed >= req.number

    return "#{req.name} took #{outcome.elapsed} ms"
  end

  case outcome.result
    ok(response) -> check_response(req, response)
    error(e) if req.op == "expect_kind" and e.kind.start_with?(req.text) -> Protocol.OK
    error(e) -> "#{req.name} failed: #{e.kind} #{e.message}"
  end
end

def check_response(req: Request, response: HttpClient.Response) -> String
  case req.op
    "expect_status" if response.status == req.number -> Protocol.OK
    "expect_body" if String.from_bytes(response.body).unwrap_or("") == req.text -> Protocol.OK
    "expect_header" if has_header?(response, header(req.text)) -> Protocol.OK
    "expect_url" if response.url == req.text -> Protocol.OK
    _ ->
      text = String.from_bytes(response.body).unwrap_or("<binary>")
      "#{req.name}: #{response.status} #{response.url} #{response.headers} #{text}"
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
