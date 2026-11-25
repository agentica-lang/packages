## Writing: a field is quoted only when it has to be, and a row ends with CRLF as RFC 4180 asks.

import Scan from "scan"

## The rows as text. A field that holds the separator, a quote or a line break is quoted, with its quotes doubled; the
## only field of a row that is empty is quoted too, so the row is not read back as a blank line.
def encode(rows: List[List[String]], separator: String) -> Result[String]
  byte = try Scan.separator_byte(separator)
  lines: List[String] = []
  for row in rows
    cells = row.map { |field| cell(field, byte, row.size == 1) }
    lines = lines.push(cells.join(separator) + "\r\n")
  end

  ok(lines.join(""))
end

private

QUOTE = 34
LF = 10
CR = 13

def cell(field: String, separator: Int, alone: Bool) -> String
  return "\"\"" if field.empty? and alone
  return field if !needs_quotes(field.bytes, separator)

  "\"" + field.replace("\"", "\"\"") + "\""
end

def needs_quotes(bytes: Bytes, separator: Int) -> Bool
  for byte in bytes
    return true if byte == separator or byte == QUOTE or byte == LF or byte == CR
  end

  false
end
