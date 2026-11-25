## The programs a release runs: `agentica`, `cp`, `chmod`, `mkdir`, `tar` and `uname`, with no shell between.

import Errors from "errors"

## Runs `command` in `dir` and gives its standard output; a program that exits with another code than 0 is a
## `release.failed` error with its standard error.
def run(command: String, args: List[String], dir: String) -> Result[String]
  child = try Process.spawn_captured(command, args, Process.Options(chdir: dir, timeout_ms: RUN_MS))
  out = Process.output(child, RUN_MS)
  code = Process.wait(child, RUN_MS)
  Process.close(child)
  done = try out
  status = try code
  return Errors.failed("#{command} #{args.join(" ")} exited with #{status}: #{done.stderr.strip}") if status != 0

  ok(done.stdout)
end

## The `agentica` that PATH finds, as an absolute path.
def find_agentica() -> Result[String]
  found = run("sh", ["-c", "command -v agentica"], ".")
  return Errors.invalid("no agentica on PATH; pass --agentica FILE") if !found.ok?

  ok(found.unwrap!.strip)
end

private

RUN_MS = 600_000
