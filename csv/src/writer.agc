## Writing: a field is quoted only when it has to be, and a row ends with CRLF as RFC 4180 asks.

import Scan from "scan"

## The rows as text. A field that holds the separator, a quote or a line break is quoted, with its quotes doubled; the
## only field of a row that is empty is quoted too, so the row is not read back as a blank line.
def encode(rows: List[List[String]], separator: String) -> Result[String]
  _ = try Scan.separator_byte(separator)
  ok(rows.map { |row| line(row, separator) }.join(""))
end

private

QUOTE = "\""

# A row with no quote, CR or LF, and as many fields after a split at the separator as before, has nothing to quote.
def line(row: List[String], separator: String) -> String
  return "\r\n" if row.empty?

  joined = row.join(separator)
  if !joined.include?(QUOTE) and !joined.include?("\n") and !joined.include?("\r")
    if joined.split(separator).size == row.size
      return "\"\"\r\n" if joined.empty?

      return joined + "\r\n"
    end
  end

  row.map { |field| cell(field, separator, row.size == 1) }.join(separator) + "\r\n"
end

def cell(field: String, separator: String, alone: Bool) -> String
  return "\"\"" if field.empty? and alone
  return field if !needs_quotes(field, separator)

  QUOTE + field.replace(QUOTE, "\"\"") + QUOTE
end

def needs_quotes(field: String, separator: String) -> Bool
  field.include?(separator) or field.include?(QUOTE) or field.include?("\n") or field.include?("\r")
end
