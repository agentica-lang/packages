## The steps of the features: a step sets the text and the options, `the text is parsed` runs `YAML.parse` (or
## `YAML.parse_all`) in the scenario's process and keeps the outcome and the steps it took, and the `Then` steps check
## the value, or the kind of the error and where it points. In a text, `→` stands for a tab.

import BDD from "std/bdd"
import YAML from "../yaml"

def main() -> Void
  BDD.run([
    BDD.step("the YAML text:", &the_text),
    BDD.step("the YAML text {string}", &the_quoted_text),
    BDD.step("a text of {int} nested flow sequences", &nested_flow),
    BDD.step("a text of {int} nested block sequences", &nested_block),
    BDD.step("a text of {int} nested block mappings", &nested_mappings),
    BDD.step("an alias bomb of {int} levels", &alias_bomb),
    BDD.step("a text of {int} bytes", &text_of_size),
    BDD.step("a mapping of {int} entries", &big_mapping),
    BDD.step("the options allow a depth of {int}", &allows_depth),
    BDD.step("the options allow {int} alias nodes", &allows_alias_nodes),
    BDD.step("the options allow {int} bytes", &allows_bytes),
    BDD.step("the text is parsed", &parses),
    BDD.step("the stream is parsed", &parses_stream),
    BDD.step("it parses", &it_parses),
    BDD.step("the value is:", &value_is),
    BDD.step("the documents are:", &documents_are),
    BDD.step("the value has {int} entries", &value_has_entries),
    BDD.step("it fails with {string} at line {int}, column {int}", &fails_at),
    BDD.step("it fails with {string}", &fails_with),
    BDD.step("the parse took fewer than {int} steps", &took_fewer_steps),
  ])
end

private

TEXT = "text"
OPTIONS = "options"
OUTCOME = "outcome"

# What a parse gave, kept between steps: the value (an array of the documents for a stream) or the error.
struct Outcome
  parsed: Bool
  # The JSON text of the value.
  value: String
  kind: String = ""
  line: String = ""
  column: String = ""
  message: String = ""
  steps: Int
end

def the_text(ctx: BDD.Context, _args: List[String]) -> BDD.Context = keep_text(ctx, BDD.doc_string(ctx))

def the_quoted_text(ctx: BDD.Context, args: List[String]) -> BDD.Context = keep_text(ctx, args[0])

def keep_text(ctx: BDD.Context, text: String) -> BDD.Context = BDD.set(ctx, TEXT, JSON.from(text.replace("→", "\t")))

def nested_flow(ctx: BDD.Context, args: List[String]) -> BDD.Context
  levels = args[0].to_i!
  BDD.set(ctx, TEXT, JSON.from("[" * levels + "]" * levels))
end

def nested_block(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, TEXT, JSON.from("- " * args[0].to_i! + "leaf"))
end

def nested_mappings(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines: List[String] = []
  for level in 0...args[0].to_i!
    lines = lines.push("#{" " * level}key:")
  end

  BDD.set(ctx, TEXT, JSON.from(lines.join("\n")))
end

# Each level is a list of nine aliases of the level before: 9 to the power of the levels nodes in a few lines.
def alias_bomb(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = ["l0: &l0 [lol, lol, lol, lol, lol, lol, lol, lol, lol]"]
  for level in 1..args[0].to_i!
    aliases = List.repeat("*l#{level - 1}", 9).join(", ")
    lines = lines.push("l#{level}: &l#{level} [#{aliases}]")
  end

  BDD.set(ctx, TEXT, JSON.from(lines.join("\n")))
end

def text_of_size(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, TEXT, JSON.from("a" * args[0].to_i!))
end

def big_mapping(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines: List[String] = []
  for i in 0...args[0].to_i!
    lines = lines.push("key#{i}: {name: \"item #{i}\", tags: [a, b], count: #{i}}")
  end

  BDD.set(ctx, TEXT, JSON.from(lines.join("\n")))
end

def options(ctx: BDD.Context) -> YAML.Options
  case BDD.get(ctx, OPTIONS)
    ok(value) -> JSON.decode(value, YAML.Options).unwrap!
    error(_) -> YAML.Options()
  end
end

def allows_depth(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, OPTIONS, JSON.from(options(ctx).with(max_depth: args[0].to_i!)))
end

def allows_alias_nodes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, OPTIONS, JSON.from(options(ctx).with(max_alias_nodes: args[0].to_i!)))
end

def allows_bytes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  BDD.set(ctx, OPTIONS, JSON.from(options(ctx).with(max_bytes: args[0].to_i!)))
end

def parses(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  text = JSON.string(BDD.get(ctx, TEXT).unwrap!).unwrap!
  given = options(ctx)
  before = System.Profile.steps()
  parsed = YAML.parse(text, given)
  keep(ctx, parsed, System.Profile.steps() - before)
end

def parses_stream(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  text = JSON.string(BDD.get(ctx, TEXT).unwrap!).unwrap!
  given = options(ctx)
  before = System.Profile.steps()
  parsed = YAML.parse_all(text, given)
  steps = System.Profile.steps() - before
  case parsed
    ok(values) -> keep(ctx, ok(JSON.array(values)), steps)
    error(e) -> keep(ctx, error(e), steps)
  end
end

def keep(ctx: BDD.Context, parsed: Result[JSON.Value], steps: Int) -> BDD.Context
  outcome = case parsed
    ok(value) -> Outcome(parsed: true, value: JSON.encode(value), steps: steps)
    error(e) ->
      Outcome(
        parsed: false,
        value: "",
        kind: e.kind,
        line: e.details.get("line", ""),
        column: e.details.get("column", ""),
        message: e.message,
        steps: steps,
      )
  end

  BDD.set(ctx, OUTCOME, JSON.from(outcome))
end

def outcome(ctx: BDD.Context) -> Outcome = JSON.decode(BDD.get(ctx, OUTCOME).unwrap!, Outcome).unwrap!

def it_parses(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  got = outcome(ctx)
  BDD.assert(ctx, got.parsed, "the parse failed: #{got.message}")
end

def value_is(ctx: BDD.Context, _args: List[String]) -> BDD.Context = same_value(ctx, BDD.doc_string(ctx))

def documents_are(ctx: BDD.Context, _args: List[String]) -> BDD.Context = same_value(ctx, BDD.doc_string(ctx))

# The value and the expected JSON compare as canonical text (sorted keys), so `1` is not `1.0`.
def same_value(ctx: BDD.Context, expected: String) -> BDD.Context
  got = outcome(ctx)
  checked = BDD.assert(ctx, got.parsed, "the parse failed: #{got.message}")
  BDD.assert(
    checked,
    got.value == JSON.encode(JSON.parse(expected).unwrap!),
    "expected #{JSON.encode(JSON.parse(expected).unwrap!)}, got #{got.value}",
  )
end

def value_has_entries(ctx: BDD.Context, args: List[String]) -> BDD.Context
  got = outcome(ctx)
  size = case JSON.node(JSON.parse(got.value).unwrap_or(JSON.null()))
    JSON.Node.Object(fields) -> fields.size
    _ -> -1
  end

  BDD.assert(ctx, size == args[0].to_i!, "expected #{args[0]} entries, got #{size}: #{got.message}")
end

def fails_at(ctx: BDD.Context, args: List[String]) -> BDD.Context
  got = outcome(ctx)
  where = "#{got.line}:#{got.column}"
  checked = BDD.assert(ctx, not got.parsed, "expected an error, got #{got.value}")
  BDD.assert(
    checked,
    got.kind == args[0] and where == "#{args[1]}:#{args[2]}",
    "expected #{args[0]} at #{args[1]}:#{args[2]}, got #{got.kind} at #{where}: #{got.message}",
  )
end

def fails_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  got = outcome(ctx)
  checked = BDD.assert(ctx, not got.parsed, "expected an error, got #{got.value}")
  BDD.assert(checked, got.kind == args[0], "expected #{args[0]}, got #{got.kind}: #{got.message}")
end

def took_fewer_steps(ctx: BDD.Context, args: List[String]) -> BDD.Context
  used = outcome(ctx).steps
  BDD.assert(ctx, used < args[0].to_i!, "the parse took #{used} steps")
end
