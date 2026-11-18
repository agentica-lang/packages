## The conventions of `docs/conventions.md` as a check, for the tests of a library that emits events: collect what the
## library emits (with a handler that keeps the events) and give each event to `check`, so `jobs`, `pool` and
## `http-client` agree on names, units and keys without reading each other.
##
## Errors have a kind: `conformance.name`, `conformance.measurement` and `conformance.metadata`.

import Names from "src/names"
import Types from "src/types"

## Checks one event, and gives the first problem as an error.
## - The name is one to four dotted words of `a-z`, digits and `_`.
## - A measurement key says its unit: `count` or `size`, a name that ends in `_ns`, `_bytes` or `_total` (a total of a
##   snapshot) for `ints`, `ratio` or a name that ends in `_ratio` for `floats`; a key is in one map only.
## - `duration_ns` is for the events that end with `.stop` or `.error`.
## - A metadata key is a `snake_case` word.
def check(event: Types.Event) -> Result[Void]
  try check_name(event.name)
  try check_ints(event)
  try check_floats(event)
  check_metadata(event)
end

private

MAX_WORDS = 4
INT_UNITS = ["_ns", "_bytes", "_total"]
INT_WORDS = ["count", "size"]
ENDS = ["stop", "error"]

def problem[T](kind: String, event: Types.Event, text: String) -> Result[T]
  error("conformance: the event #{event.name}: #{text}", kind: "conformance.#{kind}")
end

def check_name(name: String) -> Result[Void]
  words = name.split(".")
  if words.size > MAX_WORDS or not words.all?(->(word) { Names.word?(word) })
    return error(
      "conformance: #{name} is not a name of 1 to #{MAX_WORDS} words of a-z, 0-9 and _",
      kind: "conformance.name",
    )
  end

  ok()
end

def check_ints(event: Types.Event) -> Result[Void]
  for key in event.ints.keys()
    return problem("measurement", event, "#{key} is not a word of a-z, 0-9 and _") if not Names.word?(key)
    if not int_unit?(key)
      return problem("measurement", event, "#{key} says no unit: count, size, _ns, _bytes or _total")
    end

    if key == "duration_ns" and not ends?(event)
      return problem("measurement", event, "duration_ns is for .stop and .error")
    end
  end

  ok()
end

def int_unit?(key: String) -> Bool = INT_WORDS.include?(key) or INT_UNITS.any?(->(unit) { key.end_with?(unit) })

def ends?(event: Types.Event) -> Bool = ENDS.include?(event.name.split(".").last)

def check_floats(event: Types.Event) -> Result[Void]
  for key in event.floats.keys()
    return problem("measurement", event, "#{key} is not a word of a-z, 0-9 and _") if not Names.word?(key)
    return problem("measurement", event, "#{key} must be ratio or end in _ratio, as a float") if not ratio?(key)
  end

  ok()
end

def ratio?(key: String) -> Bool = key == "ratio" or key.end_with?("_ratio")

def check_metadata(event: Types.Event) -> Result[Void]
  for key in event.metadata.keys()
    return problem("metadata", event, "the key #{key} is not a snake_case word") if not Names.word?(key)
  end

  ok()
end
