# pool

A generic pool of resources for Agentica: a fixed number of long-lived resources of any type (a database connection, an
HTTP connection, a worker), made once and lent to one caller at a time. Callers wait in line, a caller that crashes or
is cancelled never keeps its resource, the resource of a body that crashes or runs past its lease is checked in or
ended and replaced, and idle resources are checked on a health tick.

Add it in a project with an `agentica.toml`:

```sh
agentica add pool https://github.com/agentica-lang/packages --tag pool-0.1.0 --subdir pool
```

The docs, with the example and every option: <https://agentica-lang.github.io/packages/pool/>.
