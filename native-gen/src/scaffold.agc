## The files of a new native module (pure): its `.agc` with an `extern module` block, a C file with one body per
## function that fails the call until it is written, and the `[native.NAME]` entry of `agentica.toml`; or for a Rust
## module the crate `rust/`: `Cargo.toml`, `.gitignore` and `src/lib.rs` with one such method per function. The
## header and the Rust file are not here: they are made from the `.agc`, as for any other block.

import CHeader from "header"
import RustSide from "rust"

# The names a crate cannot have: Rust's keywords, the crates of Rust's own library, and the crate it depends on.
CRATES = Set.new(["test", "core", "std", "alloc", "proc_macro", "agentica_native"])
# The letters of the name of a native library in `agentica.toml` that are also a C identifier: one lowercase letter,
# then lowercase letters, digits and `_` (the manifest takes `-` too, which C does not).
FIRST = Set.new("abcdefghijklmnopqrstuvwxyz".split(""))
REST = Set.new("abcdefghijklmnopqrstuvwxyz0123456789_".split(""))
MAX_NAME = 64
# The names Windows keeps for devices: a library that builds is a file NAME.dll there.
DEVICES = Set.new([
  "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2",
  "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
])

## Why `name` cannot be a new module, or "": it is the `[native.NAME]` of `agentica.toml`, the library of the block
## and the start of its C names.
export def name_problem(name: String) -> String
  letters = name.split("")
  return "a module name has 1 to #{MAX_NAME} characters" if letters.empty? or letters.size > MAX_NAME

  if !FIRST.include?(letters[0]) or !letters.all? do |letter: String| REST.include?(letter) end
    return "a module name starts with a lowercase letter and holds only lowercase letters, digits and _"
  end

  return "a module name cannot be a device name of Windows (con, nul, com1 and the like)" if DEVICES.include?(name)

  ""
end

## Why `name` cannot be a new Rust module, or "": the rule of `name_problem`, and a name that cargo refuses for a crate.
export def rust_name_problem(name: String) -> String
  problem = name_problem(name)
  if problem.empty? and (RustSide.KEYWORDS.include?(name) or CRATES.include?(name))
    return "a Rust module name cannot be a Rust keyword or the name of a crate of Rust (fn, test, std and the like)"
  end

  # `NAME_native`, the module of the Rust file, must be snake case for rustc's lint.
  if problem.empty? and (name.end_with?("_") or name.include?("__"))
    return "a Rust module name does not end with _ or hold __, so NAME_native is snake case"
  end

  problem
end

## The `.agc` of the module `name`: the block, with one function to replace, and a `main` that calls it.
export def program(name: String) -> String
  block_program(
    [
      "## The native module #{name}: its functions are written in C, in native/#{name}.c, on the header",
      "## native/#{name}_native.h that native-gen makes from this block. Make the header again after a change to it.",
    ],
    name,
  )
end

## The `.agc` of the Rust module `name`: the block of `program`, its functions written in `rust/src/lib.rs`.
export def rust_program(name: String) -> String
  block_program(
    [
      "## The native module #{name}: its functions are written in Rust, in rust/src/lib.rs, on the file",
      "## rust/src/#{name}_native.rs that native-gen makes from this block. `cli.agc build #{name}.agc` makes",
      "## that file again, builds the crate and puts the library in native/.",
    ],
    name,
  )
end

## The `Cargo.toml` of the Rust module `name`, on the `agentica-native` crate that native-gen puts in `deps/`.
export def cargo_toml(name: String) -> String
  [
    "[package]",
    "name = #{name.inspect}",
    "version = \"0.1.0\"",
    "edition = \"2024\"",
    "rust-version = \"1.90\"",
    "publish = false",
    "",
    "[lib]",
    "crate-type = [\"cdylib\"]",
    "",
    "[dependencies]",
    "agentica-native = { path = \"../deps/native-gen/native/agentica-native\" }",
    "",
  ].join("\n")
end

## The `.gitignore` of the crate: what cargo makes.
export def gitignore() -> String = "target/\nCargo.lock\n"

## The `src/lib.rs` of the Rust module `name`: the method of the example function fails the call until it is written.
## The type that implements the trait is `Functions` whatever the name, so no name (`raise`, `result`) makes a type
## that clashes with an import or the prelude; and the crate is named `::agentica_native`, which only an extern crate
## can be, so the module `agentica_native` of the name `agentica` does not shadow it. No list of names is kept.
export def lib_rs(name: String) -> String
  trait_name = RustSide.trait_name(name)
  [
    "//! The Rust side of #{name}.agc, on the file `src/#{name}_native.rs` that native-gen makes from its block. Each",
    "//! function fails the call until it is written.",
    "",
    "#[rustfmt::skip]",
    "mod #{name}_native;",
    "",
    "use ::agentica_native::{Env, Raise};",
    "",
    "use crate::#{name}_native::{#{trait_name}, module};",
    "",
    "struct Functions;",
    "",
    "impl #{trait_name} for Functions {",
    "    fn add(_env: Env<'_>, _a: i64, _b: i64) -> Result<i64, Raise> {",
    "        Err(Raise::new(\"not written yet\"))",
    "    }",
    "}",
    "",
    "::agentica_native::export!(module::<Functions>());",
    "",
  ].join("\n")
end

## The C file of the module `name`, on its header: the body of each function fails the call until it is written.
export def source(name: String, names: CHeader.Prefix) -> String
  [
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
  [
    "",
    "# native/#{name}.c is written on #{header}, which native-gen makes from #{name}.agc. Make it again after a",
    "# change to the block, and check it in CI, from this folder:",
    "#   agentica deps/native-gen/cli.agc #{name}.agc --output #{header}",
    "#   agentica deps/native-gen/cli.agc #{name}.agc --output #{header} --check",
    "[native.#{name}]",
    "build = { sources = [\"native/#{name}.c\"] }",
    "",
  ].join("\n")
end

def block_program(doc: List[String], name: String) -> String
  (
    doc.concat([
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
    ])
      .join("\n")
  )
end
