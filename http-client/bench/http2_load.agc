import HttpClient from "../http_client"

private

def main() -> Void
  args = System.args()
  protocol = HttpClient.Protocol.Http1
  if args[3] == "h2"
    protocol = HttpClient.Protocol.Http2
  end

  client = HttpClient.new(
    base_url: args[0],
    protocol: protocol,
    pool_size: args[4].to_i!,
    pool_timeout_ms: 10_000,
    timeout_ms: 15_000,
    max_retries: 0,
  ).unwrap!

  count = args[1].to_i!
  concurrency = args[2].to_i!
  chunk = "x" * 98_304
  start = Time.monotonic_ms()
  results = Task.map((0...count).to_a, concurrency, 60_000) do |id| exchange(client, id, chunk) end

  elapsed = Time.monotonic_ms() - start
  HttpClient.close(client)

  latencies: List[Int] = []
  failures = 0
  for result in results
    case result
      ok(elapsed_ms) -> latencies = latencies.push(elapsed_ms)
      error(e) ->
        if failures < 5
          IO.warn("#{e.kind}: #{e.message}")
        end

        failures += 1
    end
  end

  if failures > 0
    IO.warn("#{count - failures}/#{count} responses validated")
    System.exit(1)
  end

  p95 = latencies.sort()[(count * 95 - 1) / 100]
  puts("#{elapsed} #{p95}")
end

def exchange(client: HttpClient.Client, id: Int, chunk: String) -> Result[Int]
  path = "/#{id}"
  expected = "#{id}:".bytes
  if id % 3 != 0
    expected = "#{id}:#{chunk}".bytes
  end

  start = Time.monotonic_ms()
  response = try fetch(client, id, path, expected)
  elapsed = Time.monotonic_ms() - start
  if response.status != 200 or response.body != expected
    return error(
      "request #{id}: expected 200 and #{expected.size} bytes, got #{response.status} and #{response.body.size} bytes",
    )
  end

  ok(elapsed)
end

def fetch(client: HttpClient.Client, id: Int, path: String, body: Bytes) -> Result[HttpClient.Response]
  return HttpClient.post(client, path, body: some(body)) if id % 3 == 2
  HttpClient.get(client, path)
end
