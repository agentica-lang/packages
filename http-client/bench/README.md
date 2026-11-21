# HTTP/1.1 and HTTP/2 load comparison

Run from the repository root with Node.js 20 or later and the package's Agentica version.

```sh
make install PACKAGES=http-client
export AGENTICA="$(tools/agentica-for.sh http-client)"
node http-client/bench/http2_load.mjs
node http-client/bench/http2_load.mjs 1000 48 5 3
```

The arguments are requests per case, client concurrency, server delay in milliseconds, and rounds. They default to 1,000, 48, 0, and 3. The delay is applied per request after reading the body, so it models work that the server can overlap.

Each round runs three cases with the same Agentica client and Node.js workload. HTTP/1.1 and cleartext HTTP/2 each get one socket, then HTTP/1.1 also runs with up to 16 sockets. HTTP/2 advertises 16 streams per session. Each case uses a fresh localhost server and client, and the starting case rotates across rounds. Retries are disabled.

The workload mixes small GETs, GETs with 96 KiB responses, and POSTs that echo 96 KiB uploads. It checks response status and bytes, upload bytes, unique request IDs, sockets used, and peak in-flight requests. The results report total request time, throughput, and p95 request latency including time waiting for the pool. Each value in the summary is based on the median across rounds.

## Inference-style workload

```sh
node http-client/bench/http2_load.mjs infer
node http-client/bench/http2_load.mjs infer 240 160 20 80 3 30 2
```

The arguments after `infer` are requests per case, client concurrency, minimum and maximum server delay in milliseconds, rounds, HTTP/1.1 pool size, and HTTP/2 pool size. The values shown are the defaults.

This workload follows the aiosonic inference benchmark. Both protocols use the same Node.js TLS server configuration with ALPN, a small GET response, and a different synthetic delay for each request. The delay is derived from the request ID, so both cases replay the same delays. The client verifies the fixture certificate and the server checks the negotiated HTTP version for every request. HTTP/2 allows up to 100 streams per connection in this profile.

The default pool comparison allows HTTP/1.1 up to 30 TCP connections and HTTP/2 up to two. Each round prints the number actually opened, along with the peak number of requests in flight. Pass `2 2` for the last two arguments to compare equal pool sizes. The simulated work is local and the reported ratios apply to this workload.
