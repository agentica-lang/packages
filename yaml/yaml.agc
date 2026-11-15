## YAML 1.2 to JSON: `YAML.parse` reads one document, `YAML.parse_all` a stream of them, into `JSON.Value`s that
## `JSON.decode` turns into records. It reads the core schema only, so a document never builds anything but data:
## any tag other than the core ones is an error, and so are a key that is not a string and a key given twice.
##
## A failure is an error of kind `yaml.parse`, or `yaml.limit` when the text passes a limit of `YAML.Options`; its
## message starts with the line and the column, which are also in `details`.

import Composer from "src/composer"
import Parser from "src/parser"
import Source from "src/source"
import Types from "src/types"

export Types.Options

## The value of the one document of `text`: null for a text with no document, an error for one with more.
def parse(text: String, options: Types.Options = Types.Options()) -> Result[JSON.Value]
  src = try source(text, options)
  Source.located(src, one(src))
end

## The values of the documents of `text`, in order.
def parse_all(text: String, options: Types.Options = Types.Options()) -> Result[List[JSON.Value]]
  src = try source(text, options)
  Source.located(src, all(src))
end

private

# Each level of nesting takes a few calls of the parser, and calls nest 10,000 deep at most.
MAX_DEPTH = 1000
NUL = String.from_code(0)

def one(src: Source.Source) -> Result[JSON.Value]
  documents = try Parser.stream(src)
  return Source.fail(src, documents[1].pos, "a second document: YAML.parse_all reads a stream") if documents.size > 1

  values = try Composer.documents(src, nodes(documents))
  return ok(JSON.null()) if values.empty?

  ok(values[0])
end

def all(src: Source.Source) -> Result[List[JSON.Value]]
  documents = try Parser.stream(src)
  Composer.documents(src, nodes(documents))
end

def source(text: String, options: Types.Options) -> Result[Source.Source]
  if options.max_depth < 1 or options.max_depth > MAX_DEPTH
    return error("max_depth must be 1 to #{MAX_DEPTH}, not #{options.max_depth}", kind: "argument")
  end

  size = text.bytesize
  if size > options.max_bytes
    empty = Source.from_text("", options)
    too_big: Result[Source.Source] = Source.over_limit(
      empty,
      0,
      "the text has #{size} bytes, over #{options.max_bytes}",
    )

    return Source.located(empty, too_big)
  end

  src = Source.from_text(text, options)
  # A NUL marks the end of the bytes for the parser, and YAML does not allow it.
  if text.include?(NUL)
    nul: Result[Source.Source] = Source.fail(src, Source.find_byte(src, 0), "a NUL character")
    return Source.located(src, nul)
  end

  ok(src)
end

def nodes(documents: List[Parser.Document]) -> List[Types.Node] = documents.map do |document| document.node end
