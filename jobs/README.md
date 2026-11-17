# jobs

Produce and consume jobs, with the backend swappable: a contract with leases, retries and dead jobs. A job that was
enqueued runs until it is acked or dead (at least once, so handlers must be idempotent).

Add it in a project with an `agentica.toml`:

```sh
agentica add jobs https://github.com/agentica-lang/packages --tag jobs-0.1.0 --subdir jobs
```

The docs: <https://www.agentica-lang.com/packages/jobs/>.
