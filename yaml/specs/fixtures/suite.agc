## Runs the cases of the yaml-test-suite that `../fetch-suite.sh` unpacks. A case is a folder with an `in.yaml`
## (`ID`, or `ID/NN` for a case of several parts) and either `in.json` (the values of its documents, one JSON value
## after another) or `error` (the text must fail). The cases with neither, and the ones in `SKIPPED`, are out of the
## scope of the package. It prints each case that does not pass, then one line with the counts, and exits 1 when a case
## fails (2 when the suite is missing).
##
## ```sh
## agentica specs/fixtures/suite.agc .cache/yaml-test-suite-COMMIT
## ```

import YAML from "../../yaml"

def main() -> Void
  folder = System.args()[0]
  if not File.stat("#{folder}/229Q/in.yaml").ok?
    puts("the yaml-test-suite is missing in #{folder}: run `make install PACKAGES=yaml` in the repository")
    System.exit(2)
  end

  names = cases(folder)
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

# Out of scope: custom and local tags, and the YAML 1.1 types !!set, !!omap and !!binary.
SKIPPED = Set.new([
  "5TYM",
  "6CK3",
  "6WLZ",
  "7FWL",
  "9WXW",
  "C4HZ",
  "CC74",
  "CUP7",
  "M5C3",
  "P76L",
  "UGM3",
  "Z67P",
  "Z9M4",
  "2XXW",
  "J7PZ",
  "565N",
])

# The cases in scope, sorted: the folders with an answer (`in.json` or `error`) that SKIPPED does not name.
def cases(folder: String) -> List[String]
  found: List[String] = []
  none_found: List[String] = []
  for id in Dir.list(folder).unwrap_or(none_found).sort
    # The ids are capitals and digits; `name/` and `tags/` index them again by name and by tag.
    next if SKIPPED.include?(id) or id != id.upcase

    if File.stat("#{folder}/#{id}/in.yaml").ok?
      found = found.push(id)
    else
      for part in Dir.list("#{folder}/#{id}").unwrap_or(none_found).sort
        found = found.push("#{id}/#{part}")
      end
    end
  end

  found.select do |name| answered?("#{folder}/#{name}") end
end

def answered?(path: String) -> Bool
  File.stat("#{path}/in.yaml").ok? and (File.stat("#{path}/in.json").ok? or File.stat("#{path}/error").ok?)
end

# What is wrong with one case, or none when it passes.
def run_case(folder: String) -> Optional[String]
  text = File.read_text("#{folder}/in.yaml").unwrap!
  parsed = YAML.parse_all(text)
  if File.stat("#{folder}/error").ok?
    return case parsed
      ok(values) -> some("parsed an invalid text to #{values}")
      error(e) if e.kind == "yaml.parse" -> none
      error(e) -> some("failed with #{e.kind}, not yaml.parse: #{e.message}")
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

# Equal JSON values of one kind, where an integer equals a float of the same value (the suite writes `1.0` as `1`).
def same?(actual: JSON.Value, expected: JSON.Value) -> Bool
  return false if kind(actual) != kind(expected)

  case JSON.node(actual)
    JSON.Node.Int(_), JSON.Node.Float(_) -> JSON.float(actual).unwrap! == JSON.float(expected).unwrap!
    JSON.Node.Array(items) -> same_items?(items, JSON.list(expected).unwrap!)
    JSON.Node.Object(fields) -> same_fields?(fields, expected)
    _ -> actual == expected
  end
end

def kind(value: JSON.Value) -> String
  found = JSON.kind(value)
  return "number" if found == "int" or found == "float"

  found
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
