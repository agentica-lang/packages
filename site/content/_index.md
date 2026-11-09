---
title: Agentica packages
---

Small packages for [Agentica](https://github.com/agentica-lang/agentica), one folder each in [agentica-lang/packages](https://github.com/agentica-lang/packages). Each package has its own `agentica.toml`, versions and docs.

Add one with its prefixed tag, `PACKAGE-X.Y.Z`, and its folder as `--subdir`, in a project with an `agentica.toml`:

```sh
agentica add prop https://github.com/agentica-lang/packages --tag prop-0.1.0 --subdir prop
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
prop = { git = "https://github.com/agentica-lang/packages", tag = "prop-0.1.0", subdir = "prop" }
```
