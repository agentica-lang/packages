## Event names and patterns: dotted words of lowercase letters, digits and `_`, from one to four, and `"*"` as a
## pattern for every event.

import Regex from "std/regex"
import Types from "types"

## The pattern that matches every event.
ALL = "*"
MAX_SEGMENTS = 4
# What `Actor.start` takes as a queue.
MAX_CAPACITY = 1_048_576

## The patterns that match an event: its name, each of its prefixes at a dot, and `"*"`. A pattern has at most
## `MAX_SEGMENTS` words, so the words after them match nothing, and a long name costs no more than a short one.
def matching_patterns(name: String) -> List[String]
  parts = name.split(".").take(MAX_SEGMENTS)
  prefixes = (1..parts.size).to_a.map(->(count) { parts.take(count).join(".") })
  prefixes.push(ALL)
end

## The reason a handler cannot be attached with this id, patterns and options, if any.
def check_attach(id: String, patterns: List[String], options: Types.Options) -> Result[Void]
  return error("telemetry error: the id of a handler cannot be empty", kind: "argument") if id == ""
  return error("telemetry error: a handler needs at least one pattern", kind: "argument") if patterns.empty?

  for pattern in patterns
    try check_pattern(pattern)
  end

  if options.capacity < 1 or options.capacity > MAX_CAPACITY
    return error(
      "telemetry error: capacity must be from 1 to #{MAX_CAPACITY}, got #{options.capacity}",
      kind: "argument",
    )
  end

  ok()
end

private

SEGMENT = /^[a-z][a-z0-9_]*$/

def check_pattern(pattern: String) -> Result[Void]
  return ok() if pattern == ALL

  parts = pattern.split(".")
  if parts.size > MAX_SEGMENTS or not parts.all?(->(part) { Regex.match?(part, SEGMENT) })
    return error(
      "telemetry error: #{pattern} is not a name: 1 to #{MAX_SEGMENTS} words of a-z, 0-9 and _ joined by dots, or *",
      kind: "argument",
    )
  end

  ok()
end
