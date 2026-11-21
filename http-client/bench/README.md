# Local HTTP/2 load test

Run from the repository root with Node.js and the package's Agentica version.

```sh
make install PACKAGES=http-client
AGENTICA="$(tools/agentica-for.sh http-client)" node http-client/bench/http2_load.mjs
```

The optional arguments are the number of requests and the client concurrency, defaulting to 1,000 and 48. The server listens on an ephemeral loopback port and advertises a limit of 16 streams. The client uses one cleartext HTTP/2 connection and disables retries.

The workload mixes small GETs, GETs with 96 KiB responses, and POSTs that echo 96 KiB uploads. It checks response status and bytes, upload bytes, unique request IDs, connection reuse, and the peak number of simultaneous streams. The command exits with an error if any of those checks fail.
