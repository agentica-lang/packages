## Parses 20,000 lines where each `:` could start a key but does not (a URL, a comment), and prints how long it took
## against a bound: the parse is linear in the text, so it takes well under a second.

import YAML from "../../yaml"

LINES = 20_000
BOUND_MS = 3_000

def main() -> Void
  lines: List[String] = []
  for i in 0...LINES
    lines = lines.push("- http://example.com/#{i} # see: #{i}")
  end

  text = lines.join("\n")
  started = Time.monotonic_ms()
  parsed = YAML.parse(text)
  elapsed = Time.monotonic_ms() - started
  case parsed
    ok(_) if elapsed < BOUND_MS -> puts("parsed #{LINES} lines in under #{BOUND_MS} ms")
    ok(_) -> puts("parsed #{LINES} lines in #{elapsed} ms")
    error(e) -> puts(e.message)
  end
end
