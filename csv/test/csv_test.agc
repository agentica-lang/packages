import Prop from "pkg/prop/prop"
import Csv from "../csv"

private

SAMPLE = "a,\"b\r\nb\",c\r\n\"d\"\"e\",,f\nlast,\"\""
ACCENTED = "é,\"✓\r\n✓\",ü\r\n\"\"\"é\",x"
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

def by_chars(text: String) -> List[String] = (0...text.length).map(->(index) { text.at(index) })

def read_chunks(chunks: List[String]) -> Result[List[List[String]]]
  state = try Csv.reader()
  rows: List[List[String]] = []
  for chunk in chunks
    fed = try Csv.feed(state, chunk)
    rows = rows + fed.rows
    state = fed.reader
  end

  last = try Csv.finish(state)
  ok(rows + last)
end

def test_a_text_fed_one_character_at_a_time_reads_as_the_whole_text() -> Result[Void]
  for text in [SAMPLE, ACCENTED, String.from_code(65279) + "a,b\r\nc"]
    whole = try Csv.parse(text)
    pieces = try read_chunks(by_chars(text))
    try must(pieces == whole, "#{text} read #{pieces}")
  end

  ok()
end

def test_a_row_finished_in_the_first_chunk_does_not_move_the_line_of_a_later_error() -> Result[Void]
  state = try Csv.reader()
  first = try Csv.feed(state, "a,\"x\r\ny\"\r\nb,\"c")
  try must(first.rows == [["a", "x\r\ny"]], "read #{first.rows}")
  case Csv.finish(first.reader)
    ok(_) -> error("an unclosed quote was read")
    error(e) -> must(e.message.include?("line 3"), e.message)
  end
end

def test_a_row_of_twenty_thousand_fields_is_read() -> Result[Void]
  rows = try Csv.parse(List.repeat("x", 20000).join(","))
  must(rows.size == 1 and rows[0].size == 20000, "read #{rows.size} rows")
end

def outcome(result: Result[List[List[String]]]) -> String
  case result
    ok(rows) -> "ok #{rows}"
    error(e) -> "#{e.kind} #{e.message}"
  end
end

def test_chunks_of_one_character_give_the_rows_or_the_error_of_the_whole_text() -> Result[Void]
  texts = Prop.map(Prop.list(Prop.one_of(PIECES), 12), ->(parts) { parts.join("") })
  Prop.check(texts, Prop.Config(runs: 200)) do |text|
    chunked = outcome(read_chunks(by_chars(text)))
    whole = outcome(Csv.parse(text))
    must(chunked == whole, "#{chunked} against #{whole}")
  end
end

def test_a_mark_after_an_empty_chunk_is_dropped_and_one_after_text_is_kept() -> Result[Void]
  mark = String.from_code(65279)
  dropped = try read_chunks(["", mark + "a,b"])
  kept = try read_chunks(["a,", mark + "b"])
  try must(dropped == [["a", "b"]], "read #{dropped}")
  must(kept == [["a", mark + "b"]], "read #{kept}")
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
