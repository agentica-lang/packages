## The files of a new native module (pure): its `.agc` with an `extern module` block, a C file with one body per
## function that fails the call until it is written, and the `[native.NAME]` entry of `agentica.toml`. The header is
## not here: it is made from the `.agc`, as for any other block.

import CHeader from "header"

## The `.agc` of the module `name`: the block, with one function to replace, and a `main` that calls it.
export def program(name: String) -> String
  return [
    "## The native module #{name}: its functions are written in C, in native/#{name}.c, on the header",
    "## native/#{name}_native.h that native-gen makes from this block. Make the header again after a change to it.",
    "",
    "extern module #{name.inspect}",
    "  ## An example to replace: the sum of `a` and `b`.",
    "  def add(a: Int, b: Int) -> Int",
    "end",
    "",
    "def main() -> Void",
    "  puts(add(1, 2))",
    "end",
    "",
  ].join("\n")
end

## The C file of the module `name`, on its header: the body of each function fails the call until it is written.
export def source(name: String, names: CHeader.Prefix) -> String
  return [
    "/* The C side of #{name}.agc, on the header that native-gen makes from it. Each function fails the call until",
    "   it is written. */",
    "#define #{names.upper}_NATIVE_IMPLEMENTATION",
    "#include \"#{names.lower}_native.h\"",
    "",
    "an_term #{names.lower}_add(an_env *env, int64_t a, int64_t b) {",
    "  (void)a;",
    "  (void)b;",
    "  return an_raise(env, \"not written yet\");",
    "}",
    "",
    "#{names.upper}_NATIVE_MODULE(NULL)",
    "",
  ].join("\n")
end

## The `[native.NAME]` entry of `agentica.toml`, with the commands that make and check the header.
export def entry(name: String, names: CHeader.Prefix) -> String
  header = "native/#{names.lower}_native.h"
  return [
    "",
    "# native/#{name}.c is written on #{header}, which native-gen makes from #{name}.agc. Make it again after a",
    "# change to the block, and check it in CI:",
    "#   agentica deps/native-gen/cli.agc #{name}.agc --output #{header}",
    "#   agentica deps/native-gen/cli.agc #{name}.agc --output #{header} --check",
    "[native.#{name}]",
    "build = { sources = [\"native/#{name}.c\"] }",
    "",
  ].join("\n")
end
