import BDD from "std/bdd"
import H2Peer from "fixtures/h2_peer"
import HttpClient from "../http_client"

def flow(ctx: BDD.Context, _args: List[String]) -> BDD.Context = checked(ctx, flow_check())

def tls(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  result = tls_check(true)
  case result
    ok(_) -> checked(ctx, tls_check(false))
    error(_) -> checked(ctx, result)
  end
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
  second = try HttpClient.post(client, "/second", body: some(("u" * 70_000).bytes))
  if (
    second.status != 200 or
    second.headers.size != 1 or
    second.headers[0].value != "one" or
    second.body != ("d" * 70_000).bytes
  )
    return error("unexpected second response")
  end

  third = try HttpClient.get(client, "/third")
  return error("unexpected third response") if third.status != 204
  ok()
end

def tls_check(h2: Bool) -> Result[Void]
  alpn = "h2"
  if not h2
    alpn = "http/1.1"
  end

  server = try TLS.server_context(
    TLS.ServerOptions(
      cert_file: "specs/fixtures/tls/server.pem",
      key_file: "specs/fixtures/tls/server.key",
      alpn: [alpn],
    ),
  )

  listener = try TLS.listen("127.0.0.1", 0, server)
  peer = Task.spawn do H2Peer.serve_tls(listener, h2) end
  result = tls_request(TCP.local_port(listener), alpn, h2)
  await_peer(listener, peer, result)
end

def tls_request(port: Int, alpn: String, h2: Bool) -> Result[Void]
  context = try TLS.client_context(TLS.ClientOptions(ca_file: "specs/fixtures/tls/ca.pem", alpn: [alpn]))
  client = try HttpClient.new(
    base_url: "https://api.test:#{port}",
    protocol: HttpClient.Protocol.Http2,
    tls: some(context),
    resolver: some(->(_host) { ok(["127.0.0.1"]) }),
    max_retries: 0,
    timeout_ms: 6_000,
  )

  result = HttpClient.get(client, "/tls")
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
