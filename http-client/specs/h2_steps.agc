import BDD from "std/bdd"
import H2Peer from "fixtures/h2_peer"
import HttpClient from "../http_client"
import HTTP from "std/http"

def flow(ctx: BDD.Context, _args: List[String]) -> BDD.Context = checked(ctx, flow_check())

def tls(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  result = tls_check(true)
  case result
    ok(_) -> checked(ctx, tls_check(false))
    error(_) -> checked(ctx, result)
  end
end

def startup(ctx: BDD.Context, _args: List[String]) -> BDD.Context = checked(ctx, startup_check())

def alternate(ctx: BDD.Context, _args: List[String]) -> BDD.Context = checked(ctx, alternate_check())

def early(ctx: BDD.Context, _args: List[String]) -> BDD.Context = checked(ctx, early_check())

def deadlines(ctx: BDD.Context, _args: List[String]) -> BDD.Context = checked(ctx, check_deadlines())

def closing(ctx: BDD.Context, _args: List[String]) -> BDD.Context = checked(ctx, close_checks())

private

def checked(ctx: BDD.Context, result: Result[Void]) -> BDD.Context
  case result
    ok(_) -> BDD.assert(ctx, true, "")
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def flow_check() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  pinged: Channel[Bool] = Channel.new(1)
  peer = Task.spawn do H2Peer.serve(listener, pinged) end
  result = requests(TCP.local_port(listener), pinged)
  await_peer(listener, peer, result)
end

def requests(port: Int, pinged: Channel[Bool]) -> Result[Void]
  client = try HttpClient.new(
    base_url: "http://127.0.0.1:#{port}",
    protocol: HttpClient.Protocol.Http2,
    pool_size: 1,
    max_retries: 0,
    timeout_ms: 6_000,
  )

  result = sequence(client, pinged)
  HttpClient.close(client, 0)
  result
end

def sequence(client: HttpClient.Client, pinged: Channel[Bool]) -> Result[Void]
  first = try HttpClient.get(client, "/first")
  if first.status != 200 or first.headers.size != 1 or first.headers[0].value != "one"
    return error("unexpected first response")
  end

  _ = try pinged.recv(5_000)
  invalid = HttpClient.get(client, "/invalid", headers: [HTTP.Header(name: "x-test", value: " untrimmed")])
  case invalid
    error(e) if e.is_a?("argument") -> nil
    _ -> return error("expected argument error before sending the request")
  end

  malformed = HttpClient.get(client, "/invalid path")
  case malformed
    error(e) if e.is_a?("argument") -> nil
    _ -> return error("expected argument error for malformed path")
  end

  second = try HttpClient.post(client, "/second", body: some(("u" * 70_000).bytes))
  if (
    second.status != 200 or
    second.headers.size != 1 or
    second.headers[0].value != "one" or
    second.body != ("d" * 70_000).bytes
  )
    return error("unexpected second response")
  end

  third = try HttpClient.request(client, "head", "/third", headers: [HTTP.Header(name: "X-Parity", value: "café")])
  return error("unexpected third response") if third.status != 200 or third.body != "extension".bytes
  return error("expected Latin-1 response header") if third.headers.size != 1 or third.headers[0].value != "café"
  ok()
end

def tls_check(h2: Bool) -> Result[Void]
  alpn = "h2"
  if not h2
    alpn = "http/1.1"
  end

  server = try server_context(alpn)
  listener = try TLS.listen("127.0.0.1", 0, server)
  peer = Task.spawn do H2Peer.serve_tls(listener, h2) end
  result = tls_request(TCP.local_port(listener), [alpn], h2, ["127.0.0.1"])
  await_peer(listener, peer, result)
end

def server_context(alpn: String) -> Result[TLS.Context]
  TLS.server_context(
    TLS.ServerOptions(
      cert_file: "specs/fixtures/tls/server.pem",
      key_file: "specs/fixtures/tls/server.key",
      alpn: [alpn],
    ),
  )
end

def tls_request(port: Int, alpn: List[String], h2: Bool, addresses: List[String]) -> Result[Void]
  context = try TLS.client_context(TLS.ClientOptions(ca_file: "specs/fixtures/tls/ca.pem", alpn: alpn))
  client = try HttpClient.new(
    base_url: "https://api.test:#{port}",
    protocol: HttpClient.Protocol.Http2,
    tls: some(context),
    resolver: some(->(_host) { ok(addresses) }),
    max_retries: 0,
    timeout_ms: 6_000,
  )

  result = HttpClient.post(client, "/tls")
  HttpClient.close(client, 0)
  case result
    ok(response) if h2 and response.status == 200 -> ok()
    error(e) if not h2 and e.is_a?("http_client.http2.alpn") -> ok()
    error(e) -> error(e)
    ok(_) -> error("unexpected ALPN outcome")
  end
end

def await_peer(listener: TCP.Listener, peer: Task[Result[Void]], result: Result[Void]) -> Result[Void]
  TCP.close_listener(listener)
  case Task.await(peer, 2_000)
    Await.Done(outcome) ->
      try outcome
      result
    _ ->
      Task.cancel(peer)
      _ = Task.await(peer, 1_000)
      try result
      error("HTTP/2 peer did not finish")
  end
end

def startup_check() -> Result[Void]
  invalid = OpenSSL.Digest.hexdecode("000200000001").unwrap!
  goaway = OpenSSL.Digest.hexdecode("0000080700000000007fffffff00000000").unwrap!
  try refused(invalid, "".bytes, "http_client.http2.protocol")
  refused("".bytes, goaway, "http_client.network")
end

def refused(settings: Bytes, following: Bytes, kind: String) -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  peer = Task.spawn do H2Peer.refuse_start(listener, settings, following) end
  result = refused_request(TCP.local_port(listener), kind)
  await_peer(listener, peer, result)
end

def refused_request(port: Int, kind: String) -> Result[Void]
  client = try HttpClient.new(
    base_url: "http://127.0.0.1:#{port}",
    protocol: HttpClient.Protocol.Http2,
    max_retries: 0,
  )

  result = HttpClient.get(client, "/")
  HttpClient.close(client, 0)
  case result
    error(e) if e.is_a?(kind) -> ok()
    error(e) -> error(e)
    ok(_) -> error("startup should refuse the request")
  end
end

def alternate_check() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  peer = Task.spawn do H2Peer.failover(listener) end
  result = alternate_request(TCP.local_port(listener))
  await_peer(listener, peer, result)
end

def alternate_request(port: Int) -> Result[Void]
  client = try HttpClient.new(
    base_url: "http://api.test:#{port}",
    protocol: HttpClient.Protocol.Http2,
    connect_timeout_ms: 1_000,
    max_retries: 0,
    resolver: some(->(_host) { ok(["127.0.0.1", "127.0.0.1"]) }),
  )

  result = HttpClient.get(client, "/")
  HttpClient.close(client, 0)
  response = try result
  return error("expected the second connection to succeed") if response.status != 200
  ok()
end

def early_check() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  peer = Task.spawn do H2Peer.early_post(listener) end
  result = early_request(TCP.local_port(listener))
  await_peer(listener, peer, result)
end

def early_request(port: Int) -> Result[Void]
  client = try HttpClient.new(
    base_url: "http://127.0.0.1:#{port}",
    protocol: HttpClient.Protocol.Http2,
    max_retries: 0,
  )

  result = HttpClient.post(client, "/early", body: some(("u" * 80_000).bytes))
  HttpClient.close(client, 0)
  response = try result
  return error("incomplete early response") if response.status != 413 or response.body != ("r" * 32_768 + "tail").bytes

  ok()
end

def check_deadlines() -> Result[Void]
  try deadline_check(true, 200, "http_client.timeout.connect")
  try deadline_check(false, 200, "http_client.timeout.read")
  try deadline_check(true, 2_000, "http_client.timeout.request")
  deadline_check(false, 2_000, "http_client.timeout.request")
end

def deadline_check(settings: Bool, phase_ms: Int, kind: String) -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  peer = Task.spawn do H2Peer.stalled(listener, settings) end
  result = timeout_request(TCP.local_port(listener), phase_ms, kind)
  await_peer(listener, peer, result)
end

def timeout_request(port: Int, phase_ms: Int, kind: String) -> Result[Void]
  client = try HttpClient.new(
    base_url: "http://127.0.0.1:#{port}",
    protocol: HttpClient.Protocol.Http2,
    connect_timeout_ms: phase_ms,
    read_timeout_ms: phase_ms,
    timeout_ms: 750,
    max_retries: 0,
  )

  result = HttpClient.get(client, "/")
  HttpClient.close(client, 0)
  case result
    error(e) if e.is_a?(kind) -> ok()
    error(e) -> error("expected #{kind}, got #{e.kind}: #{e.message}")
    ok(_) -> error("expected a timeout")
  end
end

def closing_check() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  started: Channel[Bool] = Channel.new(1)
  peer = Task.spawn do H2Peer.wait_for_close(listener, started) end
  result = close_active(TCP.local_port(listener), started)
  await_peer(listener, peer, result)
end

def close_active(port: Int, started: Channel[Bool]) -> Result[Void]
  client = try HttpClient.new(
    base_url: "http://127.0.0.1:#{port}",
    protocol: HttpClient.Protocol.Http2,
    timeout_ms: 30_000,
    max_retries: 0,
  )

  request = Task.spawn do HttpClient.get(client, "/") end
  began = started.recv(2_000)
  HttpClient.close(client, 0)
  try began
  case Task.await(request, 500)
    Await.Done(error(e)) if e.is_a?("http_client.closed") -> ok()
    Await.Done(error(e)) -> error(e)
    Await.Done(ok(_)) -> error("expected closed request")
    Await.TimedOut ->
      Task.cancel(request)
      _ = Task.await(request)
      error("request did not finish after close")
  end
end

def close_checks() -> Result[Void]
  try closing_check()
  listener = try TCP.listen("127.0.0.1", 0)
  release: Channel[Bool] = Channel.new(1)
  peer = Task.spawn do H2Peer.idle_until_close(listener, release) end
  result = close_idle(TCP.local_port(listener))
  _ = release.send(true, 0)
  await_peer(listener, peer, result)
end

def close_idle(port: Int) -> Result[Void]
  before = Task.pending_count()
  client = try HttpClient.new(
    base_url: "http://127.0.0.1:#{port}",
    protocol: HttpClient.Protocol.Http2,
    max_retries: 0,
  )

  result = HttpClient.get(client, "/")
  HttpClient.close(client, 0)
  _ = try result
  return error("HTTP/2 close left tasks running") if Task.pending_count() != before
  ok()
end
