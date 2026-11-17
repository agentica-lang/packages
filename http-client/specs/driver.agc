## The program under test of the features: it holds the client, the peers it talks to and the requests in flight, and
## runs the requests that `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out.

import HTTP from "std/http"
import HttpClient from "../http_client"
import Protocol from "protocol"
import {Request} from "protocol"

private

PEER = "fixtures/peer.py"
PEER_START_MS = 10_000
WAIT_MS = 30_000

# The outcome of a request: its result and how long it took.
struct Outcome
  result: Result[HttpClient.Response]
  elapsed: Int
end

struct Driver
  peers: Map[String, String]
  processes: List[Process]
  client: Optional[HttpClient.Client]
  running: Map[String, Task[Outcome]]
  outcomes: Map[String, Outcome]
end

struct Handled
  driver: Driver
  reply: String
end

def main() -> Void
  driver = Driver(peers: {}, processes: [], client: none, running: {}, outcomes: {})
  line = IO.gets
  while line.ok?
    handled = handle(driver, line.unwrap_or(""))
    driver = handled.driver
    puts(handled.reply.replace("\n", "\\n"))
    IO.flush()
    line = IO.gets
  end
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
  args = [PEER]
  if req.number > 0
    args = args.push(req.number.to_s)
  end

  case Process.spawn("python3", args)
    ok(peer) ->
      case Process.read_line(peer, PEER_START_MS)
        ok(line) ->
          address = "http://127.0.0.1:#{line.split(" ").last}"
          done(driver.with(peers: driver.peers.put(req.name, address), processes: driver.processes.push(peer)))
        error(e) -> failed(driver, "the peer did not start: #{e.message}")
      end

    error(e) -> failed(driver, "the peer did not start: #{e.message}")
  end
end

def make_client(driver: Driver, req: Request) -> Handled
  base = driver.peers.get(req.name).unwrap_or("")
  settings: Map[String, Int] = {}
  headers: List[HTTP.Header] = []
  for row in req.table.drop(1)
    if row[0] == "header"
      headers = headers.push(header(row[1]))
    else
      settings = settings.put(row[0], row[1].to_i!)
    end
  end

  made = HttpClient.new(
    base_url: base,
    headers: headers,
    connect_timeout_ms: settings.get("connect_timeout_ms").unwrap_or(10_000),
    read_timeout_ms: settings.get("read_timeout_ms").unwrap_or(30_000),
    timeout_ms: settings.get("timeout_ms").unwrap_or(60_000),
    max_body_bytes: settings.get("max_body_bytes").unwrap_or(16_777_216),
    pool_size: settings.get("pool_size").unwrap_or(10),
    pool_timeout_ms: settings.get("pool_timeout_ms").unwrap_or(5_000),
    idle_ms: settings.get("idle_ms").unwrap_or(30_000),
  )

  case made
    ok(client) -> done(driver.with(client: some(client)))
    error(e) -> failed(driver, "the client was not made: #{e.message}")
  end
end

def header(text: String) -> HTTP.Header
  parts = text.split(": ")
  HTTP.Header(name: parts[0], value: parts.drop(1).join(": "))
end

def send(driver: Driver, req: Request) -> Handled
  case start_request(driver, req)
    ok(task) -> done(driver.with(outcomes: driver.outcomes.put(req.name, Task.await(task))))
    error(e) -> failed(driver, e.message)
  end
end

def started(driver: Driver, req: Request) -> Handled
  case start_request(driver, req)
    ok(task) -> done(driver.with(running: driver.running.put(req.name, task)))
    error(e) -> failed(driver, e.message)
  end
end

def waited(driver: Driver, name: String) -> Handled
  case driver.running.get(name)
    some(task) ->
      case Task.await(task, WAIT_MS)
        Await.Done(outcome) -> done(driver.with(outcomes: driver.outcomes.put(name, outcome)))
        Await.TimedOut -> failed(driver, "#{name} did not end")
      end

    none -> failed(driver, "no request #{name} runs")
  end
end

def start_request(driver: Driver, req: Request) -> Result[Task[Outcome]]
  client = try driver.client.to_result("no client")
  url = req.text
  for name in driver.peers.keys
    url = url.replace("{#{name}}", driver.peers.get(name).unwrap_or(""))
  end

  headers: List[HTTP.Header] = []
  if not req.header.empty?
    headers = [header(req.header)]
  end

  ok(
    Task.spawn do
      began = Time.monotonic_ms()
      result = HttpClient.request(client, req.kind, url, req.body.bytes, headers)
      Outcome(result: result, elapsed: Time.monotonic_ms() - began)
    end,
  )
end

def expect(driver: Driver, req: Request) -> Handled
  case driver.outcomes.get(req.name)
    some(outcome) -> Handled(driver: driver, reply: check(req, outcome))
    none -> failed(driver, "no outcome for #{req.name}")
  end
end

def check(req: Request, outcome: Outcome) -> String
  if req.op == "expect_within"
    return Protocol.OK if outcome.elapsed < req.number

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
    _ ->
      text = String.from_bytes(response.body).unwrap_or("<binary>")
      "#{req.name}: #{response.status} #{response.headers} #{text}"
  end
end

def has_header?(response: HttpClient.Response, wanted: HTTP.Header) -> Bool
  HTTP.header_values(response.headers, wanted.name).include?(wanted.value)
end
