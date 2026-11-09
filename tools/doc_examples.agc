## Runs the `agentica` code blocks of the docs of each package, so an example that stops working fails CI.
##
## ```sh
## agentica tools/doc_examples.agc agentica prop native-gen
## ```
##
## The first argument is the agentica binary to run the examples with (a name on PATH, or a path); the rest are package
## folders. Each block of PACKAGE/docs/*.md whose fence is ```` ```agentica ```` or ```` ```agc ```` is written to
## PACKAGE/_doc_examples/ (removed at the end), with `"pkg/PACKAGE/` turned into `"../`, so it imports the package as a
## user does and resolves the package's own dependencies.
##
## - A block with `def main` runs and must exit 0. When the next block (after blank lines only) is an ```` ```output ````
##   block, its stdout must be that text. A ```` ```text ```` block is never compared.
## - Any other block is type-checked. `{mode="check"}` after the language only checks a block (a server, say), and
##   `{mode="fragment"}` skips one that is not a whole file. `{mode="run"}` is the default; any other info is an error.
## - An `output` block that no running block takes, an unclosed fence, and a fence that names agentica but is not read
##   (indented, `~~~`, four backticks) are errors too.
##
## Exit 1 when an example fails, with one line per failure.

# The folder of each package that holds the examples while they run.
FOLDER = "_doc_examples"
FENCE = "```"
TIMEOUT_MS = 30_000
MODES = ["run", "check", "fragment"]

# One `agentica` block: where it starts, its text, how to run it, and the output it must print.
struct Example
  page: String
  line: Int
  text: String
  mode: String
  output: Optional[String]
end

# The examples of a page and the problems of its fences.
struct Parsed
  examples: List[Example]
  problems: List[String]
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

  agentica = binary(args[0])
  failures: List[String] = []
  passed = 0
  skipped = 0
  for package in args.drop(1)
    parsed = examples_of(package)
    fragments = parsed.examples.select do |example: Example| example.mode == "fragment" end.size
    failed = run_package(agentica, package, parsed.examples)
    skipped += fragments
    passed += parsed.examples.size - fragments - failed.size
    failures = failures.concat(parsed.problems).concat(failed)
  end

  for failure in failures
    IO.warn(failure)
  end

  puts("doc examples: #{passed} passed, #{failures.size} failed, #{skipped} fragments skipped")

  if !failures.empty?
    System.exit(1)
  end
end

# A path made absolute, since each example runs in its package's folder; a bare name is looked up on PATH.
def binary(name: String) -> String
  if !name.include?("/")
    return name
  end

  return Path.resolve(name).unwrap_or(name)
end

# The examples of the docs/*.md pages of `package`, in the order of the pages and of their lines.
def examples_of(package: String) -> Parsed
  none_found: List[String] = []
  pages = Dir.list("#{package}/docs").unwrap_or(none_found).select do |name: String| name.end_with?(".md") end
  examples: List[Example] = []
  problems: List[String] = []
  for name in pages
    path = "#{package}/docs/#{name}"
    parsed = blocks(path, File.read_text(path).unwrap!)
    examples = examples.concat(parsed.examples)
    problems = problems.concat(parsed.problems)
  end

  return Parsed(examples: examples, problems: problems)
end

# The `agentica` blocks of the Markdown `text` of `page`, each with the `output` block that follows it, and the
# problems of its fences.
def blocks(page: String, text: String) -> Parsed
  lines = text.split("\n")
  found: List[Example] = []
  problems: List[String] = []
  at = 0
  while at < lines.size
    line = lines[at]
    where = "#{page}:#{at + 1}"
    if !line.start_with?(FENCE) or line.start_with?("#{FENCE}`")
      if hidden_fence?(line)
        problems = problems.push("#{where}: this fence names agentica but is not read; open it with ```")
      end

      at += 1
      next
    end

    close = closing(lines, at + 1)
    if close >= lines.size
      return Parsed(examples: found, problems: problems.push("#{where}: the block is not closed"))
    end

    info = rest(line, FENCE)
    language = first_word(info)
    next_at = close + 1
    if language == "output"
      problems = problems.push("#{where}: no running agentica block comes right before this output block")
    elsif language == "agentica" or language == "agc"
      body = "#{lines.drop(at + 1).take(close - at - 1).join("\n")}\n"
      mode = mode_of(rest(info, language))
      if mode.ok?
        output: Optional[String] = none
        start = after_blanks(lines, close + 1)
        runs = mode.unwrap! == "run" and (body.start_with?("def main(") or body.include?("\ndef main("))
        if runs and start < lines.size and lines[start] == "#{FENCE}output"
          end_at = closing(lines, start + 1)
          if end_at < lines.size
            output = some("#{lines.drop(start + 1).take(end_at - start - 1).join("\n")}\n")
            next_at = end_at + 1
          end
        end

        found = found.push(Example(page: page, line: at + 1, text: body, mode: mode.unwrap!, output: output))
      else
        problems = problems.push("#{where}: #{mode.message}")
      end
    end

    at = next_at
  end

  return Parsed(examples: found, problems: problems)
end

# The index of the fence that closes the block opened before `from` (the size of `lines` when none does).
def closing(lines: List[String], from: Int) -> Int
  at = from
  while at < lines.size and lines[at].strip != FENCE
    at += 1
  end

  return at
end

# The index of the first line from `from` on that is not blank.
def after_blanks(lines: List[String], from: Int) -> Int
  at = from
  while at < lines.size and lines[at].strip.empty?
    at += 1
  end

  return at
end

# A fence a reader may take for an agentica block that this tool would not read: indented, `~~~` or four backticks.
def hidden_fence?(line: String) -> Bool
  text = line.strip
  fenced = text.start_with?(FENCE) or text.start_with?("~~~")
  return fenced and (text.include?("agentica") or text.include?("agc"))
end

# `text` after its first `prefix.length` characters, stripped.
def rest(text: String, prefix: String) -> String
  return text.slice(prefix.length, text.length - prefix.length).strip
end

# The language of a fence info string: the text before the first space or `{`.
def first_word(info: String) -> String
  word = info
  for stop in [" ", "{"]
    case word.index_of(stop)
      some(at) -> word = word.slice(0, at)
      none -> word = word
    end
  end

  return word
end

# `run` (with nothing after the language), or the mode of an exact `{mode="..."}`.
def mode_of(info: String) -> Result[String]
  if info.empty?
    return ok("run")
  end

  for mode in MODES
    if info == "{mode=\"#{mode}\"}"
      return ok(mode)
    end
  end

  return error("unknown fence info #{info.inspect}; write {mode=\"run\"}, {mode=\"check\"} or {mode=\"fragment\"}")
end

# Runs the examples of `package` in its examples folder, removed at the end, and gives one line per failure.
def run_package(agentica: String, package: String, examples: List[Example]) -> List[String]
  folder = "#{package}/#{FOLDER}"
  # A run that was killed leaves the folder behind; whether it was there does not matter.
  _ = Path.remove(folder)
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

  runs = example.mode == "run" and (text.start_with?("def main(") or text.include?("\ndef main("))
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
    some(expected) if result.stdout != expected ->
      return "the output is not the one shown:\n--- expected\n#{expected}--- got\n#{result.stdout}"
    _ -> return ""
  end
end

# Runs `command` in `dir` to the end; the process is closed on every path.
def captured(command: String, args: List[String], dir: String) -> Result[Finished]
  p = try Process.spawn_captured(command, args, dir, TIMEOUT_MS)
  finished = finish(p)
  Process.close(p)
  return finished
end

# The output and the exit code of `p`.
def finish(p: Process) -> Result[Finished]
  out = try Process.output(p, TIMEOUT_MS)
  code = try Process.wait(p, TIMEOUT_MS)
  return ok(Finished(code: code, stdout: out.stdout, stderr: out.stderr))
end
