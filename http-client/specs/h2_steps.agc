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

def multiplex(ctx: BDD.Context, _args: List[String]) -> BDD.Context = checked(ctx, multiplex_check())

def cancelled(ctx: BDD.Context, _args: List[String]) -> BDD.Context = checked(ctx, cancelled_check())

def shared(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  checked(ctx, peer_check(&H2Peer.shared_window, &shared_calls))
end

def broken(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  checked(ctx, peer_check(&H2Peer.broken, &broken_calls))
end

def surplus(ctx: BDD.Context, _args: List[String]) -> BDD.Context = checked(ctx, surplus_check())

def malformed(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  checked(ctx, peer_check(&H2Peer.malformed, &malformed_calls))
end

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
  finished = Task.await(peer, 2_000)
  TCP.close_listener(listener)
  case finished
    Await.Done(outcome) ->
      try result
      outcome
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
    pool_size: 1,
    pool_timeout_ms: 100,
    max_retries: 0,
  )

  request = Task.spawn do HttpClient.get(client, "/") end
  began = started.recv(2_000)
  queued_timeout = expired_queue(client)
  waiting = Task.spawn do HttpClient.get(client, "/queued") end
  HttpClient.close(client, 0)
  try began
  try queued_timeout
  try closed_request(waiting)
  closed_request(request)
end

def expired_queue(client: HttpClient.Client) -> Result[Void]
  case HttpClient.get(client, "/pool-timeout")
    error(e) if e.is_a?("http_client.timeout.pool") -> ok()
    error(e) -> error(e)
    ok(_) -> error("expected a pool timeout while the only stream was occupied")
  end
end

def closed_request(request: Task[Result[HttpClient.Response]]) -> Result[Void]
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

def multiplex_check() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  started: Channel[Bool] = Channel.new(1)
  finished: Channel[Bool] = Channel.new(1)
  peer = Task.spawn do H2Peer.multiplex(listener, started, finished) end
  client = try HttpClient.new(
    base_url: "http://127.0.0.1:#{TCP.local_port(listener)}",
    protocol: HttpClient.Protocol.Http2,
    pool_size: 1,
    max_retries: 0,
  )

  result = concurrent_calls(client, started, finished)
  HttpClient.close(client, 0)
  await_peer(listener, peer, result)
end

def concurrent_calls(client: HttpClient.Client, started: Channel[Bool], finished: Channel[Bool]) -> Result[Void]
  upload = Task.spawn do HttpClient.post(client, "/blocked", body: some("upload".bytes)) end
  _ = try started.recv(2_000)
  fast = try HttpClient.get(client, "/fast")
  return error("wrong response to concurrent GET") if fast.status != 200 or fast.body != "fast".bytes

  try finished.send(true, 0)
  slow = try Task.await(upload)
  if slow.status != 200 or slow.body != "slow".bytes or slow.headers.size != 1 or slow.headers[0].value != "one"
    return error("wrong POST response or shared HPACK state")
  end

  ok()
end

def cancelled_check() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  waiting: Channel[Bool] = Channel.new(1)
  peer = Task.spawn do H2Peer.cancelled(listener, waiting) end
  client = try HttpClient.new(
    base_url: "http://127.0.0.1:#{TCP.local_port(listener)}",
    protocol: HttpClient.Protocol.Http2,
    pool_size: 1,
    max_retries: 0,
    timeout_ms: 3_000,
  )

  result = cancelled_calls(client, waiting)
  HttpClient.close(client, 0)
  await_peer(listener, peer, result)
end

def cancelled_calls(client: HttpClient.Client, waiting: Channel[Bool]) -> Result[Void]
  shorter = client.with(read_timeout_ms: 500)
  first = Task.spawn do HttpClient.get(shorter, "/cancelled") end
  _ = try waiting.recv(2_000)
  queued = try HttpClient.get(client, "/queued")
  case Task.await(first)
    error(e) if e.is_a?("http_client.timeout.read") -> nil
    _ -> return error("first request did not get its read timeout")
  end

  if queued.status != 200 or queued.headers.size != 1 or queued.headers[0].value != "one"
    return error("the second stream did not use the HPACK entry from the cancelled stream")
  end

  ok()
end

def peer_check(
  serve: Fn[TCP.Listener, Channel[Bool], Result[Void]],
  calls: Fn[HttpClient.Client, Channel[Bool], Result[Void]],
) -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  started: Channel[Bool] = Channel.new(1)
  peer = Task.spawn do serve.call(listener, started) end
  client = try HttpClient.new(
    base_url: "http://127.0.0.1:#{TCP.local_port(listener)}",
    pool_size: 1,
    protocol: HttpClient.Protocol.Http2,
    max_retries: 0,
    timeout_ms: 5_000,
  )

  result = calls.call(client, started)
  HttpClient.close(client, 0)
  await_peer(listener, peer, result)
end

def shared_calls(client: HttpClient.Client, started: Channel[Bool]) -> Result[Void]
  body = some(("u" * 35_000).bytes)
  first = Task.spawn do HttpClient.post(client, "/one", body: body) end
  _ = try started.recv(2_000)
  second = try HttpClient.post(client, "/two", body: body)
  first_response = try Task.await(first)
  return error("either upload failed") if first_response.status != 200 or second.status != 200
  replacement = try HttpClient.get(client, "/after-goaway")
  return error("expected a new session after goaway") if replacement.status != 200
  ok()
end

def broken_calls(client: HttpClient.Client, started: Channel[Bool]) -> Result[Void]
  first = Task.spawn do HttpClient.get(client, "/one") end
  _ = try started.recv(2_000)
  second = HttpClient.get(client, "/two")
  try lost(second)
  try lost(Task.await(first))
  replacement = try HttpClient.get(client, "/replacement")
  return error("replacement session failed") if replacement.status != 200
  ok()
end

def lost(result: Result[HttpClient.Response]) -> Result[Void]
  case result
    error(e) if e.is_a?("http_client.network") -> ok()
    _ -> error("expected the failed session to settle the request")
  end
end

def surplus_check() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  started: Channel[Bool] = Channel.new(1)
  peer = Task.spawn do H2Peer.surplus(listener, started) end
  client = try HttpClient.new(
    base_url: "http://127.0.0.1:#{TCP.local_port(listener)}",
    pool_size: 2,
    protocol: HttpClient.Protocol.Http2,
    max_retries: 0,
    timeout_ms: 3_000,
    idle_ms: 100,
  )

  result = surplus_calls(client, started)
  HttpClient.close(client, 0)
  await_peer(listener, peer, result)
end

def surplus_calls(client: HttpClient.Client, started: Channel[Bool]) -> Result[Void]
  busy = Task.spawn do HttpClient.get(client, "/busy") end
  _ = try started.recv(2_000)
  spare = try HttpClient.get(client, "/spare")
  first = try Task.await(busy)
  return error("idle retirement affected the busy session") if spare.status != 200 or first.status != 200
  ok()
end

def malformed_calls(client: HttpClient.Client, started: Channel[Bool]) -> Result[Void]
  first = Task.spawn do HttpClient.get(client, "/bad-length") end
  _ = try started.recv(2_000)
  good = try HttpClient.get(client, "/good")
  case Task.await(first)
    error(e) if e.is_a?("http_client.http2.protocol") -> nil
    _ -> return error("expected a content-length error")
  end

  if good.status != 200 or good.headers.size != 1 or good.headers[0].value != "one"
    return error("the malformed response affected another stream or lost HPACK state")
  end

  ok()
end
