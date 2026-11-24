import Prop from "pkg/prop/prop"
import Csv from "../csv"

private

SAMPLE = "a,\"b\r\nb\",c\r\n\"d\"\"e\",,f\nlast,\"\""
PIECES = ["a", "", " ", ",", "\"", "\n", "\r\n", "\r", "é", ";"]

def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

def head(text: String, size: Int) -> String = String.from_bytes(text.bytes.slice(0, size)).unwrap!

def tail(text: String, size: Int) -> String = String.from_bytes(text.bytes.slice(size, text.bytes.size - size)).unwrap!

# The reader gives the same rows however the text is cut in two.
def test_a_text_cut_at_any_byte_reads_as_the_whole_text() -> Result[Void]
  whole = try Csv.parse(SAMPLE)
  for cut in 0...(SAMPLE.bytes.size + 1)
    state = try Csv.reader()
    first = try Csv.feed(state, head(SAMPLE, cut))
    second = try Csv.feed(first.reader, tail(SAMPLE, cut))
    last = try Csv.finish(second.reader)
    try must(first.rows + second.rows + last == whole, "a cut at #{cut} read #{first.rows + second.rows + last}")
  end

  ok()
end

def test_a_reader_keeps_the_line_of_an_error_across_chunks() -> Result[Void]
  state = try Csv.reader()
  first = try Csv.feed(state, "a\r\nb,\"c\r\n")
  second = try Csv.feed(first.reader, "d")
  case Csv.finish(second.reader)
    ok(_) -> error("an unclosed quote was read")
    error(e) -> must(e.kind == "csv.malformed" and e.message.include?("line 2"), "gave #{e.kind}: #{e.message}")
  end
end

def field() -> Prop.Gen[String] = Prop.map(Prop.list(Prop.one_of(PIECES), 5), ->(parts) { parts.join("") })

def table() -> Prop.Gen[List[List[String]]] = Prop.list(Prop.non_empty_list(field(), 4), 6)

def written(rows: List[List[String]]) -> String = Csv.encode(rows).unwrap!

def test_rows_written_are_read_back() -> Result[Void]
  Prop.roundtrip(table(), &written, Prop.Config(runs: 100), ->(text) { Csv.parse(text) })
end

def test_any_text_is_read_or_refused_as_malformed() -> Result[Void]
  texts = Prop.map(Prop.list(Prop.one_of(PIECES), 12), ->(parts) { parts.join("") })
  Prop.check(texts, Prop.Config(runs: 200)) do |text|
    case Csv.parse(text)
      ok(_) -> ok()
      error(e) -> must(e.kind == "csv.malformed", "gave #{e.kind}")
    end
  end
end
