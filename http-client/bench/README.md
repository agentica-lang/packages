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
