---
title: Agentica packages
---

Small packages for [Agentica](https://github.com/agentica-lang/agentica), one folder each in [agentica-lang/packages](https://github.com/agentica-lang/packages). Each package has its own `agentica.toml`, versions and docs.

Install one with `subdir` and its prefixed tag, `PACKAGE-X.Y.Z`:

```toml
[dependencies]
prop = { git = "https://github.com/agentica-lang/packages", tag = "prop-0.1.0", subdir = "prop" }
```
