---
title: Doc examples fixture
---

`make doc-examples-test` runs tools/doc_examples.agc on this page and expects 2 passes, 1 fragment and 6 failures, one per
block or fence below.

A whole file that prints what its output block shows: it passes.

```agentica
def main() -> Void
  puts(1 + 2)
end
```

```output
3
```

A fragment is skipped.

```agentica {mode="fragment"}
puts(x)
```

Fails: the output is not the one shown.

```agc
def main() -> Void
  puts("got")
end
```

```output
expected
```

Fails: no running block takes this output block (a check-only block comes before it).

```agentica {mode="check"}
def main() -> Void
  puts("checked")
end
```

```output
checked
```

Fails: an unknown mode.

```agentica {mode="skip"}
def main() -> Void
end
```

Fails: an indented fence, and a `~~~` fence.

  ```agentica
  def main() -> Void
  end
  ```

~~~agentica
def main() -> Void
end
~~~

Fails: the last block is not closed.

```agentica
def main() -> Void
end
