## The rules for a name, a version and a path of a release, shared by the config and by `inspect`. They do no I/O.

import Errors from "errors"

## A name or a version goes into a folder name and a script: letters, digits, `.`, `_` and `-`, not starting with `.`
## or `-`.
def word(label: String, text: String, help: String) -> Result[Void]
  return Errors.invalid("#{label} is empty: #{help}") if text.empty?

  allowed = text.bytes.to_a.all? { |byte| plain_byte?(byte) }
  if !allowed or text.start_with?(".") or text.start_with?("-")
    return Errors.invalid(
      "#{label} #{text.inspect} must be letters, digits, '.', '_' and '-', and not start with '.' or '-'",
    )
  end

  ok()
end

## A path below a folder: relative, with no empty, `.` or `..` part.
def inside(label: String, path: String) -> Result[Void]
  odd = path.split("/").any? { |part| part == ".." or part == "." or part.empty? }
  if path.empty? or path.start_with?("/") or odd
    return Errors.invalid("#{label} #{path.inspect} must be a path inside the project")
  end

  ok()
end

private

def plain_byte?(byte: Int) -> Bool
  (
    (byte >= 48 and byte <= 57) or
    (byte >= 65 and byte <= 90) or
    (byte >= 97 and byte <= 122) or
    byte == 46 or
    byte == 45 or
    byte == 95
  )
end
