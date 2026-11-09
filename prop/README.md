# prop

Property-based testing for Agentica: state a law, check it on many generated inputs, and get the smallest input that
breaks it, with the seed that replays the run. Pure Agentica; it runs inside `agentica test`.

```ruby
import Prop from "pkg/prop/prop"

def main() -> Void
  ints = Prop.list(Prop.int(-100, 100))
  result = Prop.check(ints, Prop.Config(seed: some(1234))) do |xs|
    Prop.eq(xs.reverse, xs)
  end

  puts(result.message)
end
```

```text
falsified after 1 run, shrunk to [0,-1], seed 1234: expected [0,-1], got [-1,0]
```

Needs Agentica 0.25.0 or later. Add it with the prefixed tag of the release, in a project with an `agentica.toml`:

```sh
agentica add prop https://github.com/agentica-lang/packages --tag prop-0.1.0 --subdir prop
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
prop = { git = "https://github.com/agentica-lang/packages", tag = "prop-0.1.0", subdir = "prop" }
```

The docs, with an example for every function, the shrinking, the exhaustive check and a guide for agents:
<https://agentica-lang.github.io/packages/prop/>.
