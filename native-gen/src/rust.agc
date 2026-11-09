## The Rust side of one `extern module` block (pure), on the `agentica-native` crate: a Rust type with its codecs for
## each struct and enum, a trait with one method per function for the module to implement, and `module`, the tables
## that `agentica_native::export!` gives the VM. Every signature, shape and mode comes from `std/analysis` as it is.
##
## A field or payload whose type leads back to the type that holds it (a recursive type) stays a term, in a newtype
## named after its type (`TreeTerm<'a>`); a type that holds a term, itself or in a type it embeds, borrows the call
## (`Tree<'a>`), and a method that takes or gives one names the call's lifetime `'a`.

import Analysis from "std/analysis"
import Names from "names"
import Types from "types"

# The Rust type of each scalar type of a signature.
SCALARS = {"Int": "i64", "Float": "f64", "Bool": "bool", "String": "String", "Bytes": "Vec<u8>", "Void": "()"}
# The words a Rust name cannot be (strict and reserved keywords of the 2024 edition), and `env`, the first parameter of
# every method. Such a name gets a trailing `_`, as in the C header.
export KEYWORDS = Set.new([
  "abstract", "as", "async", "await", "become", "box", "break", "const", "continue", "crate", "do", "dyn", "else",
  "enum", "extern", "false", "final", "fn", "for", "gen", "if", "impl", "in", "let", "loop", "macro", "match", "mod",
  "move", "mut", "override", "priv", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true",
  "try", "type", "typeof", "unsafe", "unsized", "use", "virtual", "where", "while", "yield", "env",
])
# The names the file takes from the crate and from the prelude, which a type of the block cannot be.
IMPORTS = [
  "DecodeError", "Decoder", "Encoder", "Env", "Mode", "Module", "Raise", "ResourceArc", "Term", "sys", "types",
]
PRELUDE = ["Option", "Result", "String", "Vec", "Send", "Sync", "Some", "None", "Ok", "Err"]

# The types of a block and what the Rust side needs of them: the row of each struct and enum, the resources, the
# types each one names in its fields or payloads, and those that borrow the call.
struct Plan
  types: List[Analysis.NativeType]
  rows: Map[String, Int]
  resources: Set[String]
  edges: Map[String, List[String]]
  borrowing: Set[String]
end

## The Rust file of `block`, declared in the file `source`, whose trait is `trait_name`. An error starts with its code:
## `[NATIVE-GEN-NAME]` when two of its names map to one Rust name, `[NATIVE-GEN-UNKNOWN]` for a mode, kind or API
## version that this version does not know.
export def render(block: Analysis.NativeBlock, trait_name: String, source: String) -> Result[String]
  if block.api_major != 1
    return error("[NATIVE-GEN-UNKNOWN] the block needs version #{block.api_major} of the native API")
  end

  try Names.validate(block, "Rust name", &rust_name)
  for type in block.types
    # `Self` is a keyword of Rust that no type or variant can be named.
    variants = type.members.select do |member: Analysis.NativeMember| type.kind == "enum" and member.name == "Self" end
    if type.name == "Self" or !variants.empty?
      return error("[NATIVE-GEN-NAME] #{type.name} is or has a variant named Self, a keyword of Rust")
    end
  end

  plan = plan_of(block)
  try Names.distinct(global_names(block, plan, trait_name), "Rust name")
  methods = block.functions.map do |function: Analysis.NativeFunction|
    Names.Named(c: rust_name(function.name), source: function.name)
  end

  try Names.distinct(methods, "Rust name")

  lines = joined([
    opening(block, source),
    block.types.flat_map do |type: Analysis.NativeType| type_lines(plan, type) end,
    term_lines(plan),
    trait_lines(block, plan, trait_name),
    block.functions.flat_map do |function: Analysis.NativeFunction| wrapper(function, trait_name) end,
    module_lines(block, trait_name),
  ])

  return ok("#{lines.join("\n")}\n")
end

## The name of the trait of the prefix `lower`: `stats` is `StatsNative`, `my_db` is `MyDbNative`.
export def trait_name(lower: String) -> String
  parts = lower.split("_").select do |part: String| !part.empty? end
  words = parts.map do |part: String| "#{part.slice(0, 1).upcase}#{part.slice(1, part.length - 1)}" end
  return "#{words.join("")}Native"
end

# A name of the block as a Rust name: `empty?` is `empty_p`, and a keyword or `env` gets a trailing `_`.
def rust_name(name: String) -> String
  id = Names.identifier(name)
  if KEYWORDS.include?(id)
    return "#{id}_"
  end

  return id
end

# Every name the file declares or imports at its top level, with the name of the block it comes from.
def global_names(block: Analysis.NativeBlock, plan: Plan, trait: String) -> List[Names.Named]
  named = IMPORTS.map do |name: String| Names.Named(c: name, source: "the import #{name}") end
  named = named.concat(PRELUDE.map do |name: String| Names.Named(c: name, source: "the Rust prelude's #{name}") end)
  named = named.push(Names.Named(c: trait, source: "the trait of the module"))
  named = named.push(Names.Named(c: "module", source: "the tables of the module"))
  for type in block.types
    named = named.push(Names.Named(c: type.name, source: type.name))
  end

  for name in term_types(plan)
    named = named.push(Names.Named(c: "#{name}Term", source: "the term of #{name}"))
  end

  for function in block.functions
    named = named.push(
      Names.Named(c: "native_#{Names.identifier(function.name)}", source: "the wrapper of #{function.name}"),
    )
  end

  return named
end

def plan_of(block: Analysis.NativeBlock) -> Plan
  rows: Map[String, Int] = {}
  at = 0
  for type in block.types
    rows = rows.put(type.name, at)
    at += 1
  end

  edges: Map[String, List[String]] = {}
  for type in block.types
    found: List[String] = []
    for member in type.members
      for text in member.types
        found = found.concat(leaves(Types.parse(text)).select do |name: String| rows.has_key?(name) end)
      end
    end

    edges = edges.put(type.name, found)
  end

  resources = Set.new(block.resources.map do |resource: Analysis.NativeResource| resource.name end)
  plan = Plan(types: block.types, rows: rows, resources: resources, edges: edges, borrowing: Set.new([]))
  # A type borrows the call when a field or payload holds a term or a type that borrows: grown until it stops.
  grown = true
  while grown
    grown = false
    for type in block.types
      if !plan.borrowing.include?(type.name) and holds_borrow?(plan, type)
        plan = Plan(
          types: plan.types,
          rows: rows,
          resources: resources,
          edges: edges,
          borrowing: plan.borrowing.add(type.name),
        )

        grown = true
      end
    end
  end

  return plan
end

def holds_borrow?(plan: Plan, type: Analysis.NativeType) -> Bool
  for member in type.members
    for text in member.types
      for name in leaves(Types.parse(text))
        if term?(plan, type.name, name) or plan.borrowing.include?(name)
          return true
        end
      end
    end
  end

  return false
end

# The names a type is made of: `Map[String, List[Point]]` is String and Point.
def leaves(type: Types.Type) -> List[String]
  case type
    Types.Type.Named(name) -> return [name]
    Types.Type.ListOf(item) -> return leaves(item)
    Types.Type.MapOf(key, value) -> return leaves(key).concat(leaves(value))
    Types.Type.OptionalOf(item) -> return leaves(item)
    Types.Type.ResultOf(item) -> return leaves(item)
  end
end

# Whether `name` in a field or payload of `owner` stays a term: it leads back to `owner`. Never in a parameter or
# result (`owner` "").
def term?(plan: Plan, owner: String, name: String) -> Bool
  if owner.empty? or !plan.rows.has_key?(name)
    return false
  end

  seen: Set[String] = Set.new([])
  pending = [name]
  while !pending.empty?
    at = pending[pending.size - 1]
    pending = pending.take(pending.size - 1)
    if at == owner
      return true
    end

    if !seen.include?(at)
      seen = seen.add(at)
      pending = pending.concat(plan.edges.get(at, []))
    end
  end

  return false
end

# The types that stay a term in some field or payload, in the order of the block.
def term_types(plan: Plan) -> List[String]
  found: Set[String] = Set.new([])
  for type in plan.types
    for name in plan.edges.get(type.name, [])
      if term?(plan, type.name, name)
        found = found.add(name)
      end
    end
  end

  return plan.types.map do |type: Analysis.NativeType| type.name end.select do |name: String| found.include?(name) end
end

# The Rust type of the canonical type `type` in a field or payload of `owner` ("" for a parameter or result), with
# `own` the path of the trait's associated types (`Self`).
def rust_type(plan: Plan, owner: String, type: Types.Type, own: String) -> String
  case type
    Types.Type.Named(name) ->
      if SCALARS.has_key?(name)
        return SCALARS[name]
      end

      if plan.resources.include?(name)
        return "ResourceArc<#{own}::#{name}>"
      end

      if term?(plan, owner, name)
        return "#{name}Term<'a>"
      end

      if plan.borrowing.include?(name)
        return "#{name}<'a>"
      end

      return name
    Types.Type.ListOf(item) -> return "Vec<#{rust_type(plan, owner, item, own)}>"
    Types.Type.MapOf(key, value) ->
      return "Vec<(#{rust_type(plan, owner, key, own)}, #{rust_type(plan, owner, value, own)})>"
    Types.Type.OptionalOf(item) -> return "Option<#{rust_type(plan, owner, item, own)}>"
    Types.Type.ResultOf(item) -> return "Result<#{rust_type(plan, owner, item, own)}, String>"
  end
end

def opening(block: Analysis.NativeBlock, source: String) -> List[String]
  return [
    "// The Rust side of `extern module #{block.library.inspect}` in #{source}, made by native-gen.",
    "// Do not edit it: change the .agc and make it again.",
    "",
    "#[allow(unused_imports)]",
    "use ::agentica_native::{#{IMPORTS.join(", ")}};",
  ]
end

# The type `name` with its lifetime when it borrows the call.
def generic(plan: Plan, name: String) -> String
  if plan.borrowing.include?(name)
    return "#{name}<'a>"
  end

  return name
end

def type_lines(plan: Plan, type: Analysis.NativeType) -> List[String]
  name = type.name
  row = plan.rows[name]
  derives = "Clone, Debug, PartialEq"
  # The lints that the names and types of the .agc, which the author chose, may trip.
  allowed = "clippy::type_complexity, clippy::upper_case_acronyms"
  if type.kind == "enum"
    allowed = "#{allowed}, clippy::large_enum_variant, clippy::enum_variant_names"
  end

  impl_decode = "impl<'a> Decoder<'a> for #{name}"
  impl_encode = "impl Encoder for #{name}"
  if plan.borrowing.include?(name)
    # A term has no ==.
    derives = "Clone, Debug"
    impl_decode = "impl<'a> Decoder<'a> for #{name}<'a>"
    impl_encode = "impl Encoder for #{name}<'_>"
  end

  lines = ["", "#[derive(#{derives})]", "#[allow(#{allowed})]"]
  decode: List[String] = []
  encode: List[String] = []
  if type.kind == "struct"
    lines = lines.push("pub struct #{generic(plan, name)} {")
    decode = ["        Ok(#{name} {"]
    if type.members.empty?
      # A struct of no fields reads nothing of its term.
      decode = ["        let _ = term;", "        Ok(#{name} {"]
    end

    parts: List[String] = []
    at = 0
    for member in type.members
      field = rust_name(member.name)
      lines = lines.push("    pub #{field}: #{rust_type(plan, name, Types.parse(member.types[0]), "Self")},")
      decode = decode.push(
        "            #{field}: term.decode_field::<Self, _>(#{row}, #{at}, #{member.name.inspect})?,",
      )

      parts = parts.push("self.#{field}.encode(env)")
      at += 1
    end

    decode = decode.push("        })")
    encode = ["        env.make_struct(#{row}, &[#{parts.join(", ")}])"]
  else
    lines = lines.push("pub enum #{generic(plan, name)} {")
    decode = ["        match term.get_variant(#{row}) {"]
    encode = ["        match self {"]
    at = 0
    for member in type.members
      payload = member.types.map do |text: String| rust_type(plan, name, Types.parse(text), "Self") end
      binds: List[String] = []
      reads: List[String] = []
      k = 0
      for _text in member.types
        binds = binds.push("p#{k}")
        reads = reads.push("term.decode_payload::<Self, _>(#{row}, #{member.name.inspect}, #{k})?")
        k += 1
      end

      if member.types.empty?
        lines = lines.push("    #{member.name},")
        decode = decode.push("            Some(#{at}) => Ok(#{name}::#{member.name}),")
        encode = encode.push("            #{name}::#{member.name} => env.make_enum(#{row}, #{at}, &[]),")
      else
        made = binds.map do |bind: String| "#{bind}.encode(env)" end
        lines = lines.push("    #{member.name}(#{payload.join(", ")}),")
        decode = decode.push("            Some(#{at}) => Ok(#{name}::#{member.name}(#{reads.join(", ")})),")
        made_enum = "env.make_enum(#{row}, #{at}, &[#{made.join(", ")}])"
        encode = encode.push("            #{name}::#{member.name}(#{binds.join(", ")}) => #{made_enum},")
      end

      at += 1
    end

    decode = decode.concat(["            _ => Err(DecodeError::expected::<Self>()),", "        }"])
    encode = encode.push("        }")
  end

  return joined([
    lines,
    ["}", "", "#{impl_decode} {"],
    type_name(name),
    ["", "    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {"],
    decode,
    ["    }", "}", "", "#{impl_encode} {", "    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {"],
    encode,
    ["    }", "}"],
  ])
end

def type_name(name: String) -> List[String]
  return ["    fn type_name() -> String {", "        #{rust_string(name)}.to_string()", "    }"]
end

# The newtype of each type that stays a term: its decode checks that the term is one of its type.
def term_lines(plan: Plan) -> List[String]
  lines: List[String] = []
  kinds: Map[String, String] = {}
  for type in plan.types
    kinds = kinds.put(type.name, type.kind)
  end

  for name in term_types(plan)
    row = plan.rows[name]
    # A struct here has a field, the one that leads back to it.
    check = "term.get_variant(#{row}).is_some()"
    if kinds[name] == "struct"
      check = "term.get_field(#{row}, 0).is_some()"
    end

    lines = joined([
      lines,
      [
        "",
        "/// A #{name} that stays a term, as it leads back to the type that holds it: read it with",
        "/// `.0.decode()`. A dirty call cannot read one that it made.",
        "#[derive(Clone, Copy, Debug)]",
        "pub struct #{name}Term<'a>(pub Term<'a>);",
        "",
        "impl<'a> Decoder<'a> for #{name}Term<'a> {",
      ],
      type_name(name),
      [
        "",
        "    fn decode(term: Term<'a>) -> Result<Self, DecodeError> {",
        "        if #{check} { Ok(#{name}Term(term)) } else { Err(DecodeError::expected::<Self>()) }",
        "    }",
        "}",
        "",
        "impl Encoder for #{name}Term<'_> {",
        "    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {",
        "        self.0.encode(env)",
        "    }",
        "}",
      ],
    ])
  end

  return lines
end

# Whether the parameters or the result of `function` borrow the call.
def borrows?(plan: Plan, function: Analysis.NativeFunction) -> Bool
  texts = function.parameters.map do |param: Analysis.NativeParameter| param.type end.push(function.result)
  return texts.any? do |text: String|
    leaves(Types.parse(text)).any? do |name: String| plan.borrowing.include?(name) end
  end
end

def trait_lines(block: Analysis.NativeBlock, plan: Plan, trait: String) -> List[String]
  lines = [
    "",
    "/// The functions of `extern module #{block.library.inspect}`, which the module implements. A method fails",
    "/// its call with `Err(Raise)`; an Agentica `Result` is the value inside `Ok`.",
    "#[allow(clippy::type_complexity, clippy::too_many_arguments, clippy::needless_lifetimes)]",
    "pub trait #{trait} {",
  ]

  for resource in block.resources
    lines = joined([lines, doc_lines("    ", resource.doc), ["    type #{resource.name}: Send + Sync + 'static;"]])
  end

  for function in block.functions
    life = "'_"
    generics = ""
    if borrows?(plan, function)
      life = "'a"
      generics = "<'a>"
    end

    params = ["env: Env<#{life}>"].concat(
      function.parameters.map do |param: Analysis.NativeParameter|
        "#{rust_name(param.name)}: #{rust_type(plan, "", Types.parse(param.type), "Self")}"
      end,
    )

    result = rust_type(plan, "", Types.parse(function.result), "Self")
    signature = "fn #{rust_name(function.name)}#{generics}(#{params.join(", ")}) -> Result<#{result}, Raise>;"
    lines = joined([lines, doc_lines("    ", function.doc), ["    #{signature}"]])
  end

  return lines.push("}")
end

# The C function of the table for `function`: decodes the arguments, calls the method, and encodes its value.
def wrapper(function: Analysis.NativeFunction, trait: String) -> List[String]
  args: List[String] = ["env"]
  at = 0
  for _param in function.parameters
    args = args.push("args.decode(#{at})?")
    at += 1
  end

  id = Names.identifier(function.name)
  # A function of no parameters reads no argument.
  bound = "args"
  if function.parameters.empty?
    bound = "_args"
  end

  return [
    "",
    "unsafe extern \"C\" fn native_#{id}<I: #{trait}>(",
    "    env: *mut sys::an_env,",
    "    argc: core::ffi::c_int,",
    "    argv: *const sys::an_term,",
    ") -> sys::an_term {",
    "    // SAFETY: the VM calls it through the table of `module`, with its own env and arguments, in the",
    "    // row's mode.",
    "    unsafe {",
    "        ::agentica_native::call(env, argc, argv, #{mode_of(function)}, types(), |env, #{bound}| {",
    "            Ok(I::#{rust_name(function.name)}(#{args.join(", ")})?.encode(env))",
    "        })",
    "    }",
    "}",
  ]
end

# The mode of the row of `function`: `def` is short, `compute def` dirty.
def mode_of(function: Analysis.NativeFunction) -> String
  if function.mode == "dirty"
    return "Mode::Dirty"
  end

  return "Mode::Short"
end

def module_lines(block: Analysis.NativeBlock, trait: String) -> List[String]
  lines = [
    "",
    "/// The tables of the module: `agentica_native::export!(module::<Impl>());` with `Impl` the type that implements",
    "/// `#{trait}`.",
    "pub fn module<I: #{trait}>() -> Module {",
    "    Module::new(#{rust_string(block.library)})",
  ]

  for function in block.functions
    name = rust_string(function.name)
    signature = rust_string(function.signature)
    id = Names.identifier(function.name)
    lines = lines.push("        .function(#{name}, #{signature}, native_#{id}::<I>, #{mode_of(function)})")
  end

  for type in block.types
    lines = lines.push("        .#{type.kind}_type(#{rust_string(type.name)}, #{rust_string(type.shape)})")
  end

  for resource in block.resources
    lines = lines.push("        .resource::<I::#{resource.name}>(#{rust_string(resource.name)})")
  end

  return lines.push("}")
end

# `doc` as `///` lines at `indent`. A code block that rustdoc would run as Rust is marked text: a fence of 3 or more
# ` or ~ with nothing after it, and lines indented to column 4 after a blank line (not in a list item), which get a
# fence of their own.
def doc_lines(indent: String, doc: String) -> List[String]
  if doc.empty?
    return []
  end

  lines: List[String] = []
  # The opening run of the open fenced block ("" outside one), whether an indented block is open, whether the line
  # before was blank, and whether the last line with text was a list item or its continuation.
  fence = ""
  indented = false
  blank = true
  listed = false
  for line in doc.replace("\r", "").split("\n")
    trimmed = line.trim
    text = line
    deep = !trimmed.empty? and column(line) >= 4
    if fence.empty? and !indented and deep and blank and !listed
      lines = lines.push("#{indent}/// ```text")
      indented = true
    elsif indented and !deep and !trimmed.empty?
      lines = lines.push("#{indent}/// ```")
      indented = false
    end

    run = fence_run(trimmed)
    if !indented and fence.empty? and run.length >= 3
      if trimmed == run
        text = line.replace(run, "#{run}text")
      end

      fence = run
    elsif !fence.empty? and trimmed == run and run.start_with?(fence.slice(0, 1)) and run.length >= fence.length
      fence = ""
    elsif fence.empty? and !indented and !trimmed.empty?
      listed = list_item?(trimmed) or (listed and deep)
    end

    if text.empty?
      lines = lines.push("#{indent}///")
    else
      lines = lines.push("#{indent}/// #{text}")
    end

    blank = trimmed.empty?
  end

  if indented
    lines = lines.push("#{indent}/// ```")
  end

  return lines
end

# The column where the text of `line` starts, a tab moving to the next multiple of 4.
def column(line: String) -> Int
  at = 0
  for c in line.split("")
    if c == " "
      at += 1
    elsif c == "\t"
      at = (at / 4 + 1) * 4
    else
      return at
    end
  end

  return at
end

# The run of ` or ~ that `text` starts with ("" for none).
def fence_run(text: String) -> String
  if !text.start_with?("`") and !text.start_with?("~")
    return ""
  end

  mark = text.slice(0, 1)
  length = 0
  for c in text.split("")
    if c != mark
      return text.slice(0, length)
    end

    length += 1
  end

  return text
end

# Whether `text` starts a Markdown list item: `- `, `* `, `+ ` or `N. `.
def list_item?(text: String) -> Bool
  if text.start_with?("- ") or text.start_with?("* ") or text.start_with?("+ ")
    return true
  end

  digits = 0
  for c in text.split("")
    if c.code < 48 or c.code > 57
      return digits > 0 and text.slice(digits, 2) == ". "
    end

    digits += 1
  end

  return false
end

# `text` as a Rust string literal.
def rust_string(text: String) -> String
  return "\"#{text.replace("\\", "\\\\").replace("\"", "\\\"")}\""
end

def joined(parts: List[List[String]]) -> List[String]
  return parts.flat_map do |part: List[String]| part end
end
