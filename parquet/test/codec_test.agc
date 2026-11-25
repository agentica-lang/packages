import Compression from "../src/codec"
import Header from "../src/header"
import Pages from "../src/pages"
import Plain from "../src/plain"

private

MALFORMED = "parquet.malformed"
UNCOMPRESSED = 0
SNAPPY = 1
GZIP = 2

def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

def refused[T](result: Result[T], kind: String) -> Result[Void]
  case result
    ok(_) -> error("a bad page was read")
    error(e) -> must(e.kind == kind, "gave kind #{e.kind}")
  end
end

def test_an_empty_body_is_empty_under_every_codec() -> Result[Void]
  plain = try Compression.expand(UNCOMPRESSED, "".bytes, 0)
  snappy = try Compression.expand(SNAPPY, "".bytes, 0)
  gzip = try Compression.expand(GZIP, "".bytes, 0)
  must(plain.size == 0 and snappy.size == 0 and gzip.size == 0, "a body was not empty")
end

def test_an_empty_gzip_stream_is_an_empty_page_and_other_bytes_are_not() -> Result[Void]
  stream = Zlib.gzip("".bytes).unwrap!
  body = try Compression.expand(GZIP, stream, 0)
  try must(body.size == 0, "the stream was not empty")
  refused(Compression.expand(GZIP, "not gzip".bytes, 0), MALFORMED)
end

def test_an_uncompressed_v2_page_must_have_the_size_its_header_says() -> Result[Void]
  header = Header.Header(
    kind: 3,
    size: 10,
    compressed: 10,
    count: 1,
    encoding: 0,
    level_encoding: 3,
    definition_bytes: 0,
    repetition_bytes: 0,
    is_compressed: false,
    start: 0,
  )

  layout = Pages.Layout(
    kind: Plain.Kind(physical: Plain.INT32, text: false, width: 0, unsigned: false),
    max_level: 0,
    codec: UNCOMPRESSED,
  )

  refused(Pages.page_values(header, "abcd".bytes, layout, none), MALFORMED)
end
