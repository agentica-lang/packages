## CSV (RFC 4180) in pure Agentica: the rows of a text as lists or as maps, the rows of a table as text, and a reader that
## takes the text in chunks. Quoted fields may hold the separator, quotes (doubled) and line breaks. A row ends with LF or
## CRLF, and a text that ends with a line break has no extra row. A malformed text is a `csv.malformed` error that names
## its line, and a bad argument is `csv.invalid`.

import Errors from "src/errors"
import Rows from "src/reader"
import Writer from "src/writer"

export Rows.Reader
export Rows.Feed

## The rows of `text`, each a list of fields. Rows may have different widths, and a blank line is a row of one empty field.
def parse(text: String, separator: String = ",") -> Result[List[List[String]]] = Rows.parse(text, separator)

## The rows of `text` as maps from the names in its first row. A row of another width than the header, or a name that
## appears twice in it, is a `csv.malformed` error.
def parse_maps(text: String, separator: String = ",") -> Result[List[Map[String, String]]]
  rows = try Rows.parse(text, separator)
  return ok([]) if rows.empty?

  header = rows[0]
  try distinct(header)
  out: List[Map[String, String]] = []
  for index in 1...rows.size
    row = rows[index]
    if row.size != header.size
      return Errors.malformed("row #{index + 1} has #{row.size} fields, the header #{header.size}")
    end

    entry: Map[String, String] = {}
    for column in 0...header.size
      entry = entry.put(header[column], row[column])
    end

    out = out.push(entry)
  end

  ok(out)
end

## The rows as text, each ending with CRLF. A field is quoted only when it has to be.
def encode(rows: List[List[String]], separator: String = ",") -> Result[String] = Writer.encode(rows, separator)

## The header, then the rows as maps read in the order of the header; a name a row lacks is an empty field and a key the
## header does not name is left out.
def encode_maps(header: List[String], rows: List[Map[String, String]], separator: String = ",") -> Result[String]
  table: List[List[String]] = [header]
  for entry in rows
    table = table.push(header.map { |name| entry.get(name).unwrap_or("") })
  end

  Writer.encode(table, separator)
end

## A reader for text that comes in pieces, such as the chunks of a large file. Give each piece to `feed`, which returns the
## rows it finished and the reader for the next piece, and call `finish` after the last one.
def reader(separator: String = ",") -> Result[Rows.Reader] = Rows.new(separator)

def feed(state: Rows.Reader, chunk: String) -> Result[Rows.Feed] = Rows.feed(state, chunk)

def finish(state: Rows.Reader) -> Result[List[List[String]]] = Rows.finish(state)

private

def distinct(header: List[String]) -> Result[Void]
  seen: Map[String, Bool] = {}
  for name in header
    return Errors.malformed("the header names #{name} twice") if seen.has_key?(name)

    seen = seen.put(name, true)
  end

  ok()
end
