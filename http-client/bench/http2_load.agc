import HttpClient from "../http_client"

private

def main() -> Void
  args = System.args()
  client = HttpClient.new(
    base_url: args[0],
    protocol: HttpClient.Protocol.Http2,
    pool_size: 1,
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

  failures = 0
  for result in results
    case result
      ok(_) -> nil
      error(e) ->
        if failures < 5
          IO.warn("#{e.kind}: #{e.message}")
        end

        failures += 1
    end
  end

  puts("#{count - failures}/#{count} responses validated in #{elapsed} ms (#{concurrency} client tasks)")
  if failures > 0
    System.exit(1)
  end
end

def exchange(client: HttpClient.Client, id: Int, chunk: String) -> Result[Void]
  path = "/#{id}"
  expected = "#{id}:".bytes
  if id % 3 != 0
    expected = "#{id}:#{chunk}".bytes
  end

  response = try fetch(client, id, path, expected)
  if response.status != 200 or response.body != expected
    return error(
      "request #{id}: expected 200 and #{expected.size} bytes, got #{response.status} and #{response.body.size} bytes",
    )
  end

  ok()
end

def fetch(client: HttpClient.Client, id: Int, path: String, body: Bytes) -> Result[HttpClient.Response]
  return HttpClient.post(client, path, body: some(body)) if id % 3 == 2
  HttpClient.get(client, path)
end
