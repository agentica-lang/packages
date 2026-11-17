import Encoding from "../src/encoding"
import Exchange from "../src/exchange"
import HTTP from "std/http"

private

TEXT = "hello hello hello"

def coded(coding: String, body: Bytes) -> Exchange.Response
  Exchange.Response(
    status: 200,
    headers: [
      HTTP.Header(name: "content-encoding", value: coding),
      HTTP.Header(name: "content-length", value: "#{body.size}"),
    ],
    body: body,
    url: "http://a.example/",
  )
end

def kind(result: Result[Exchange.Response]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def test_gzip_and_both_forms_of_deflate_decode_and_lose_their_headers() -> Result[Void]
  raw = Bytes.concat(try [TEXT.bytes].lazy.deflate(6, true).to_a)
  for response in [
    coded("gzip", try Zlib.gzip(TEXT.bytes)),
    coded("Deflate", try Zlib.deflate(TEXT.bytes)),
    coded("deflate", raw),
  ]
    decoded = try Encoding.decoded(response, 1_000)
    try Test.eq(decoded.body, TEXT.bytes)
    try Test.eq(decoded.headers, [])
  end

  ok()
end

def test_another_coding_or_a_part_stays_and_a_body_over_the_limit_is_too_large() -> Result[Void]
  brotli = coded("br", "data".bytes)
  try Test.eq(Encoding.decoded(brotli, 1_000).unwrap!, brotli)
  part = coded("gzip", "part".bytes).with(status: 206)
  try Test.eq(Encoding.decoded(part, 1_000).unwrap!, part)
  Test.eq(kind(Encoding.decoded(coded("gzip", try Zlib.gzip(TEXT.bytes)), 5)), "http_client.too_large")
end
