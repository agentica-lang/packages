# packages

Small Agentica packages, one folder each. A folder is a package with its own `agentica.toml`; install one with `subdir` and its prefixed tag:

```toml
[dependencies]
cache = { git = "https://github.com/agentica-lang/packages", tag = "cache-0.1.0", subdir = "cache" }
```

| Package | What it is |
|---|---|
| `cache` (planned) | Cache strategies (CLOCK, sampled LRU, TinyLFU) behind the `Cache` facade of `std/cache` |

Rules for contributors and agents: `AGENTS.md` (to come with the first package).
