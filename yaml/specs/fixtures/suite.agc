## Runs the cases of a copy of the yaml-test-suite: each folder with an `in.yaml` is a case, and holds `in.yaml` and either `in.json` (the values of its
## documents, one JSON value after another) or `error` (the text must fail). It prints each case that does not pass,
## then one line with the counts, and exits 1 when a case fails.
##
## ```sh
## agentica specs/fixtures/suite.agc specs/fixtures/yaml-test-suite
## ```

import YAML from "../../yaml"

def main() -> Void
  args = System.args()
  folder = "yaml-test-suite"
  if not args.empty?
    folder = args[0]
  end

  names = Dir.list(folder).unwrap!.sort.select do |name| File.stat("#{folder}/#{name}/in.yaml").ok? end
  failures: List[String] = []
  for name in names
    failure = run_case("#{folder}/#{name}")
    case failure
      some(message) -> failures = failures.push("#{name}: #{message}")
      none -> nil
    end
  end

  for failure in failures
    puts(failure)
  end

  puts("yaml-test-suite: #{names.size - failures.size} passed, #{failures.size} failed")
  if not failures.empty?
    System.exit(1)
  end
end

private

# What is wrong with one case, or none when it passes.
def run_case(folder: String) -> Optional[String]
  text = File.read_text("#{folder}/in.yaml").unwrap!
  parsed = YAML.parse_all(text)
  if File.stat("#{folder}/error").ok?
    return case parsed
      ok(values) -> some("parsed an invalid text to #{values}")
      error(_) -> none
    end
  end

  expected = json_values(File.read_text("#{folder}/in.json").unwrap!)
  case parsed
    ok(values) if values.size == expected.size and all_same?(values, expected) -> none
    ok(values) -> some("got #{values}, expected #{expected}")
    error(e) -> some(e.message)
  end
end

# The values of a file of JSON values one after another: each ends at the first line where the text so far parses.
def json_values(text: String) -> List[JSON.Value]
  values: List[JSON.Value] = []
  pending = ""
  for line in text.split("\n")
    pending = "#{pending}#{line}\n"
    case JSON.parse(pending)
      ok(value) ->
        values = values.push(value)
        pending = ""
      error(_) -> nil
    end
  end

  values
end

def all_same?(actual: List[JSON.Value], expected: List[JSON.Value]) -> Bool
  for i in 0...actual.size
    return false if not same?(actual[i], expected[i])
  end

  true
end

# Equal JSON values, where an integer equals a float of the same value (the suite writes `1.0` as `1`).
def same?(actual: JSON.Value, expected: JSON.Value) -> Bool
  case JSON.node(actual)
    JSON.Node.Int(_), JSON.Node.Float(_) -> number(actual) == number(expected)
    JSON.Node.Array(items) -> same_items?(items, JSON.list(expected).unwrap_or([]))
    JSON.Node.Object(fields) -> same_fields?(fields, expected)
    _ -> JSON.encode(actual) == JSON.encode(expected)
  end
end

def number(value: JSON.Value) -> Float
  case JSON.node(value)
    JSON.Node.Int(n) -> n.to_f
    JSON.Node.Float(x) -> x
    _ -> -0.5
  end
end

def same_items?(actual: List[JSON.Value], expected: List[JSON.Value]) -> Bool
  actual.size == expected.size and all_same?(actual, expected)
end

def same_fields?(actual: Map[String, JSON.Value], expected: JSON.Value) -> Bool
  case JSON.node(expected)
    JSON.Node.Object(fields) ->
      fields.size == actual.size and actual.keys.all?(->(key) { same_field?(actual, fields, key) })
    _ -> false
  end
end

def same_field?(actual: Map[String, JSON.Value], expected: Map[String, JSON.Value], key: String) -> Bool
  expected.key?(key) and same?(actual[key], expected[key])
end
