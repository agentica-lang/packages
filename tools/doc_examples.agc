## Runs the `agentica` code blocks of the docs of each package, so an example that stops working fails CI.
##
## ```sh
## agentica tools/doc_examples.agc agentica prop native-gen
## ```
##
## The first argument is the agentica binary to run the examples with; the rest are package folders. Each block of
## PACKAGE/docs/*.md is written to PACKAGE/_doc_examples/ (removed at the end), with `"pkg/PACKAGE/` turned into
## `"../`, so it imports the package as a user does and resolves the package's own dependencies. A block with
## `def main` runs and must exit 0; when the next block (after blank lines only) is an `output` block, its stdout must
## be that text. Any other block is type-checked. `{mode="check"}` after the language only checks a block, and
## `{mode="fragment"}` skips one that is not a whole file. Exit 1 when an example fails, with one line per failure.

# The folder of each package that holds the examples while they run.
FOLDER = "_doc_examples"
FENCE = "```"
TIMEOUT_MS = 120_000

# One `agentica` block: where it starts, its text, how to run it, and the output it must print.
struct Example
  page: String
  line: Int
  text: String
  mode: String
  output: Optional[String]
end

# What a finished run gave.
struct Finished
  code: Int
  stdout: String
  stderr: String
end

def main() -> Void
  args = System.args()
  if args.size < 2
    IO.warn("usage: agentica tools/doc_examples.agc AGENTICA PACKAGE...")
    System.exit(2)
  end

  failures: List[String] = []
  total = 0
  skipped = 0
  for package in args.drop(1)
    examples = examples_of(package)
    total += examples.size
    skipped += examples.select do |example: Example| example.mode == "fragment" end.size
    failures = failures.concat(run_package(args[0], package, examples))
  end

  for failure in failures
    IO.warn(failure)
  end

  puts(
    "doc examples: #{total - skipped - failures.size} passed, #{failures.size} failed, #{skipped} fragments skipped",
  )

  if !failures.empty?
    System.exit(1)
  end
end

# The examples of the docs/*.md pages of `package`, in the order of the pages and of their lines.
def examples_of(package: String) -> List[Example]
  none_found: List[String] = []
  pages = Dir.list("#{package}/docs").unwrap_or(none_found).select do |name: String| name.end_with?(".md") end
  return pages.flat_map do |name: String|
    path = "#{package}/docs/#{name}"
    blocks(path, File.read_text(path).unwrap!)
  end
end

# The `agentica` blocks of the Markdown `text` of `page`, each with the `output` block that follows it.
def blocks(page: String, text: String) -> List[Example]
  lines = text.split("\n")
  found: List[Example] = []
  at = 0
  while at < lines.size
    line = lines[at]
    if !line.start_with?(FENCE)
      at += 1
      next
    end

    info = line.slice(FENCE.length, line.length - FENCE.length).strip
    close = closing(lines, at + 1)
    body = lines.drop(at + 1).take(close - at - 1).join("\n")
    if info.start_with?("agentica")
      found = found.push(
        Example(
          page: page,
          line: at + 1,
          text: "#{body}\n",
          mode: mode_of(info),
          output: output_after(lines, close + 1),
        ),
      )
    end

    at = close + 1
  end

  return found
end

# The index of the fence that closes the block opened before `from` (the end of the page when none does).
def closing(lines: List[String], from: Int) -> Int
  at = from
  while at < lines.size and lines[at].strip != FENCE
    at += 1
  end

  return at
end

# The text of an `output` block that starts at `from` after blank lines only.
def output_after(lines: List[String], from: Int) -> Optional[String]
  at = from
  while at < lines.size and lines[at].strip.empty?
    at += 1
  end

  if at >= lines.size or lines[at].strip != "#{FENCE}output"
    return none
  end

  close = closing(lines, at + 1)
  return some("#{lines.drop(at + 1).take(close - at - 1).join("\n")}\n")
end

# `run`, `check` or `fragment`, from the `{mode="..."}` of the info string; `run` by default.
def mode_of(info: String) -> String
  for mode in ["check", "fragment"]
    if info.include?("mode=\"#{mode}\"")
      return mode
    end
  end

  return "run"
end

# Runs the examples of `package` in its examples folder, removed at the end, and gives one line per failure.
def run_package(agentica: String, package: String, examples: List[Example]) -> List[String]
  folder = "#{package}/#{FOLDER}"
  made = Dir.mkdir(folder)
  if !made.ok?
    return ["#{package}: cannot make #{folder}: #{made.message}"]
  end

  failures: List[String] = []
  index = 0
  for example in examples
    index += 1
    if example.mode != "fragment"
      problem = run_one(agentica, package, folder, "example_#{index}.agc", example)
      if !problem.empty?
        failures = failures.push("#{example.page}:#{example.line}: #{problem}")
      end
    end
  end

  removed = Path.remove(folder)
  if !removed.ok?
    failures = failures.push("#{package}: cannot remove #{folder}: #{removed.message}")
  end

  return failures
end

# Why `example` fails, or "".
def run_one(agentica: String, package: String, folder: String, name: String, example: Example) -> String
  text = example.text.replace("\"pkg/#{package}/", "\"../")
  written = File.write_text("#{folder}/#{name}", text)
  if !written.ok?
    return "cannot write the example: #{written.message}"
  end

  runs = example.mode == "run" and (text.include?("\ndef main(") or text.start_with?("def main("))
  args = ["check", name]
  if runs
    args = [name]
  end

  done = captured(agentica, args, folder)
  if !done.ok?
    return done.message
  end

  result = done.unwrap!
  if result.code != 0
    return "exit #{result.code}: #{result.stderr.strip}"
  end

  case example.output
    some(expected) if runs and result.stdout != expected ->
      return "the output is not the one shown:\n--- expected\n#{expected}--- got\n#{result.stdout}"
    _ -> return ""
  end
end

def captured(command: String, args: List[String], dir: String) -> Result[Finished]
  p = try Process.spawn_captured(command, args, dir, TIMEOUT_MS)
  out = try Process.output(p, TIMEOUT_MS)
  code = try Process.wait(p, TIMEOUT_MS)
  Process.close(p)
  return ok(Finished(code: code, stdout: out.stdout, stderr: out.stderr))
end
