---
title: csv
description: Reads and writes CSV (RFC 4180) in pure Agentica. Rows as lists or maps, a chosen separator, a reader that takes the text in chunks, and an error with its line for a malformed text.
---

`csv` reads and writes [CSV](https://www.rfc-editor.org/rfc/rfc4180). It is pure Agentica and does no I/O: give it the text, or the chunks of a large file, and it gives the rows.

A field may be quoted, and then it may hold the separator, line breaks and quotes written twice. A row ends with LF or CRLF (a lone CR is data), and a text that ends with a line break has no extra row. A blank line is a row of one empty field. Rows may have different widths, except when they are read as maps.

## Install

Needs Agentica 0.37.0. Once the first release is tagged, add it to a project with an `agentica.toml`:

```sh
agentica add csv https://github.com/agentica-lang/packages --tag csv-0.1.0 --subdir csv
```

The dependency entry is:

```toml
csv = { git = "https://github.com/agentica-lang/packages", tag = "csv-0.1.0", subdir = "csv" }
```

The releases and their notes are in the [changelog](https://github.com/agentica-lang/packages/blob/main/csv/CHANGELOG.md).

## Errors

- `csv.malformed`: the text is not CSV. The message names the line: a quote that is never closed (the line where it opened), text after a closing quote, a quote inside a field that did not start with one, text that is not UTF-8, and, for maps, a row of another width than the header or a header that names a column twice.
- `csv.invalid`: the separator is not one printable ASCII character or a tab, or it is a quote.

## Example

```agentica
import Csv from "pkg/csv/csv"

def main() -> Void
  rows = Csv.parse("name,city\r\nann,\"Paris, FR\"\r\nbob,Lima\r\n").unwrap!
  for row in rows
    IO.puts("#{row.size}: #{row[1]}")
  end
end
```

```output
2: city
2: Paris, FR
2: Lima
```

## API

### `Csv.parse(text: String, separator: String = ",") -> Result[List[List[String]]]`

The rows of the text, each a list of fields. A `separator` of `;` or a tab reads those files. A malformed text is a `csv.malformed` error with its line.

```agentica
import Csv from "pkg/csv/csv"

def main() -> Void
  case Csv.parse("a,\"b\r\nc")
    ok(rows) -> IO.puts("#{rows.size} rows")
    error(e) -> IO.puts("#{e.kind}: #{e.message}")
  end

  IO.puts("#{Csv.parse("1;2\n3;4", ";").unwrap!}")
end
```

```output
csv.malformed: csv: the quote opened at line 1 is never closed
[["1", "2"], ["3", "4"]]
```

### `Csv.parse_maps(text: String, separator: String = ",") -> Result[List[Map[String, String]]]`

The rows after the first as maps from the names in the first row. A row of another width than the header, or a name that appears twice in it, is a `csv.malformed` error. A text with no rows gives an empty list.

```agentica
import Csv from "pkg/csv/csv"

def main() -> Void
  for row in Csv.parse_maps("name,city\r\nann,Paris\r\nbob,Lima\r\n").unwrap!
    IO.puts("#{row.get("name").unwrap_or("")} lives in #{row.get("city").unwrap_or("")}")
  end
end
```

```output
ann lives in Paris
bob lives in Lima
```

### `Csv.encode(rows: List[List[String]], separator: String = ",") -> Result[String]`

The rows as text, each ending with CRLF. A field is quoted only when it holds the separator, a quote, a CR or a LF, and a row of one empty field is written as `""` so that it is not read back as a blank line. Only a bad separator is an error.

```agentica
import Csv from "pkg/csv/csv"

def main() -> Void
  text = Csv.encode([["name", "note"], ["ann", "say \"hi\""]]).unwrap!
  IO.puts(text.replace("\r\n", "|"))
end
```

```output
name,note|ann,"say ""hi"""|
```

### `Csv.encode_maps(header: List[String], rows: List[Map[String, String]], separator: String = ",") -> Result[String]`

The header, then each map read in the order of the header: a name the map lacks is an empty field, and a key the header does not name is left out.

```agentica
import Csv from "pkg/csv/csv"

def main() -> Void
  text = Csv.encode_maps(["name", "age"], [{"name": "ann", "age": "31"}, {"name": "bob"}]).unwrap!
  IO.puts(text.replace("\r\n", "|"))
end
```

```output
name,age|ann,31|bob,|
```

### `Csv.reader(separator: String = ",") -> Result[Reader]`, `Csv.feed(reader: Reader, chunk: String) -> Result[Feed]`, `Csv.finish(reader: Reader) -> Result[List[List[String]]]`

A reader for a text that comes in pieces, such as the chunks of a large file, so that the whole file is never in memory. `feed` returns the rows that the chunk finishes and the reader to use for the next chunk (a row, or a quoted field, may stop in the middle of a chunk). `finish` returns the last row, which may have no line break. A chunk is a whole `String`, so cut the text where a character ends. The rows are the same as `parse` gives, and an error names the line counted from the start of the text.

```agentica
import Csv from "pkg/csv/csv"

def main() -> Void
  state = Csv.reader().unwrap!
  first = Csv.feed(state, "a,b\r\nc,\"d,").unwrap!
  second = Csv.feed(first.reader, "e\"\r\nf,g").unwrap!
  last = Csv.finish(second.reader).unwrap!
  IO.puts("#{first.rows.size} then #{second.rows.size} then #{last.size}")
  IO.puts("#{second.rows[0][1]}")
end
```

```output
1 then 1 then 1
d,e
```
