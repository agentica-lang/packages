# prop

Property-based testing for Agentica: state a law, check it on many generated inputs, and get the smallest input that
breaks it, with the seed that replays the run. Pure Agentica; it runs inside `agentica test`.

Add it in a project with an `agentica.toml`:

```sh
agentica add prop https://github.com/agentica-lang/packages --tag prop-0.3.0 --subdir prop
```

The docs, with examples, the install and the changelog: <https://agentica-lang.github.io/packages/prop/>.
