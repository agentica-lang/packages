# dock

A TCP server for Agentica: an accept loop, one task per client that runs your handler, and the clean-up when a client
ends or its handler crashes. The socket is closed once, whichever way the handler ends, and a client never makes the
server wait.

Add it in a project with an `agentica.toml`:

```sh
agentica add dock https://github.com/agentica-lang/packages --tag dock-0.3.0-alpha.1 --subdir dock
```

The docs, with examples and the design: <https://agentica-lang.github.io/packages/dock/>.
