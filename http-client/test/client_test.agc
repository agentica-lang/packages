import HttpClient from "../http_client"

private

def kind(result: Result[HttpClient.Response]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def test_a_client_changed_with_with_is_checked_as_new_checks_it() -> Result[Void]
  client = try HttpClient.new()
  try Test.eq(kind(HttpClient.get(client.with(timeout_ms: 0), "http://127.0.0.1:9/")), "argument")
  try Test.eq(kind(HttpClient.get(client.with(read_timeout_ms: -1), "http://127.0.0.1:9/")), "argument")
  try Test.eq(kind(HttpClient.get(client.with(base_url: "ftp://example.com"), "/x")), "argument")
  HttpClient.close(client, 0)
  ok()
end

def made(result: Result[HttpClient.Client]) -> String
  case result
    ok(client) ->
      HttpClient.close(client, 0)
      "ok"
    error(e) -> e.kind
  end
end

def test_a_proxy_is_refused_with_a_resolver_or_public_only_and_the_dns_cache_is_bounded() -> Result[Void]
  try Test.eq(made(HttpClient.new(proxy: "http://127.0.0.1:9", public_only: true)), "argument")
  try Test.eq(made(HttpClient.new(proxy: "http://127.0.0.1:9", resolver: some(&nowhere))), "argument")
  try Test.eq(made(HttpClient.new(dns_cache_ms: -1)), "argument")
  try Test.eq(made(HttpClient.new(timeout_ms: 9_000_000_000_000_000_000)), "argument")
  try Test.eq(made(HttpClient.new(idle_ms: 9_000_000_000_000_000_000)), "argument")
  try Test.eq(made(HttpClient.new(pool_timeout_ms: 9_000_000_000_000_000_000)), "argument")
  Test.eq(made(HttpClient.new(proxy: "http://127.0.0.1:9")), "ok")
end

def nowhere(_host: String) -> Result[List[String]] = ok([])
