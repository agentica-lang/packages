import Address from "../src/address"
import Encoding from "../src/encoding"
import Failure from "../src/failure"
import Presigned from "../src/presigned"
import Request from "../src/request"
import Types from "../src/types"
import Xml from "../src/xml"

private

def config(endpoint: String, bucket: String, addressing: Types.Addressing) -> Types.Config
  Types.Config(
    endpoint: endpoint,
    region: "us-east-1",
    access_key: "AK",
    secret_key: "SK",
    bucket: bucket,
    addressing: addressing,
  )
end

def path_style(endpoint: String) -> Types.Config = config(endpoint, "photos", Types.Addressing.Path)

def failed?[T](result: Result[T]) -> Bool = not result.ok?

def refused?(result: Result[Void]) -> Bool
  case result
    ok(_) -> false
    error(e) -> e.kind == Types.INVALID
  end
end

def test_the_encoding_keeps_unreserved_characters_and_encodes_the_rest() -> Result[Void]
  try Test.eq(Encoding.component("AZaz09-._~"), "AZaz09-._~")
  try Test.eq(Encoding.component("a b/c+d*é"), "a%20b%2Fc%2Bd%2A%C3%A9")
  Test.eq(Encoding.path("a b/c/ñ"), "a%20b/c/%C3%B1")
end

def test_the_time_is_written_as_sigv4_does() -> Result[Void]
  Test.eq(Encoding.amz_date(1_369_353_600), "20130524T000000Z")
end

def test_path_style_and_virtual_host_addressing() -> Result[Void]
  path = Address.target(path_style("http://127.0.0.1:9000"), "a b/c").unwrap!
  try Test.eq(path.origin, "http://127.0.0.1:9000")
  try Test.eq(path.host, "127.0.0.1:9000")
  try Test.eq(path.path, "/photos/a%20b/c")
  virtual = Address.target(config("https://s3.example.com:443", "photos", Types.Addressing.Virtual), "a b/c").unwrap!
  try Test.eq(virtual.origin, "https://photos.s3.example.com:443")
  try Test.eq(virtual.host, "photos.s3.example.com")
  Test.eq(virtual.path, "/a%20b/c")
end

def test_a_config_or_a_key_that_s3_would_refuse_is_refused_before_a_request() -> Result[Void]
  bad_endpoints = [
    "", "example.com", "ftp://example.com", "https://", "https://example.com/path", "https://u@example.com",
  ]

  for endpoint in bad_endpoints
    try Test.assert(refused?(Address.check(path_style(endpoint))), "the endpoint #{endpoint}")
  end

  for bucket in ["", "ab", "UPPER", "under_score", "-dash", "a/b"]
    try Test.assert(refused?(Address.check(config("http://h", bucket, Types.Addressing.Path))), "the bucket #{bucket}")
  end

  good = path_style("http://h:1")
  try Test.assert(refused?(Address.check(good.with(region: ""))), "no region")
  try Test.assert(refused?(Address.check(good.with(secret_key: ""))), "no secret key")
  try Test.assert(failed?(Address.target(good, "/lead")), "a key that starts with /")
  Test.assert(Address.target(good, "x").ok?, "a short key")
end

def test_a_presigned_url_needs_a_valid_expiry_and_key() -> Result[Void]
  good = path_style("http://h:1")
  try Test.assert(failed?(Presigned.url(good, "GET", "k", Types.Presign(expires_s: 0))), "expires 0")
  try Test.assert(failed?(Presigned.url(good, "GET", "k", Types.Presign(expires_s: 604_801))), "expires over 7 days")
  try Test.assert(failed?(Presigned.url(good, "GET", "", Types.Presign())), "no key")
  try Test.assert(failed?(Presigned.part(good, "k", "", 1, Types.Presign())), "no upload id")
  try Test.assert(failed?(Presigned.part(good, "k", "u", 10_001, Types.Presign())), "part 10001")
  url = Presigned.url(good, "GET", "k", Types.Presign(expires_s: 604_800, at: some(1_369_353_600))).unwrap!
  Test.assert(url.start_with?("http://h:1/photos/k?X-Amz-Algorithm=AWS4-HMAC-SHA256&"), "the url is #{url}")
end

def test_a_signed_request_has_the_headers_of_sigv4_and_no_host() -> Result[Void]
  prepared = Request.prepare(path_style("http://h:1"), "GET", "k", [], [], "e3b0c442", 1_369_353_600).unwrap!
  names = prepared.headers.map { |h| h.name }
  try Test.eq(names, ["x-amz-content-sha256", "x-amz-date", "authorization"])
  Test.eq(prepared.url, "http://h:1/photos/k")
end

def test_the_error_of_an_answer_has_a_kind_made_from_its_code() -> Result[Void]
  try Test.eq(Failure.kind_of("NoSuchKey"), "s3.no_such_key")
  try Test.eq(Failure.kind_of("SignatureDoesNotMatch"), "s3.signature_does_not_match")
  try Test.eq(Failure.kind_of("XAmzContentSHA256Mismatch"), "s3.x_amz_content_sha256_mismatch")
  try Test.eq(Failure.kind_of("EntityTooSmall"), "s3.entity_too_small")
  try Test.eq(Failure.kind_of("???"), Types.HTTP_STATUS)
  body = "<Error><Code>NoSuchUpload</Code><Message>gone &amp; lost</Message><RequestId>R1</RequestId></Error>".bytes
  refused: Result[Void] = Failure.refused(404, body)
  case refused
    ok(_) -> error("expected an error", kind: "test")
    error(e) ->
      try Test.eq(e.kind, Types.NO_SUCH_UPLOAD)
      try Test.eq(e.code, some(404))
      try Test.eq(e.message, "NoSuchUpload: gone & lost")
      Test.eq(e.details, {"s3_code": "NoSuchUpload", "request_id": "R1"})
  end
end

def test_an_answer_with_no_error_body_gets_its_kind_from_the_status() -> Result[Void]
  missing: Result[Void] = Failure.refused(403, "".bytes)
  try Test.assert(failed?(missing), "403")
  case missing
    ok(_) -> error("expected an error", kind: "test")
    error(e) -> Test.eq(e.kind, Types.ACCESS_DENIED)
  end
end

def test_the_xml_is_read_by_tag_and_written_escaped() -> Result[Void]
  xml = (
    "<R><Part><PartNumber>1</PartNumber><ETag>&quot;ab&quot;</ETag></Part><Part><PartNumber>2</PartNumber></Part></R>"
  )

  try Test.eq(Xml.text(xml, "ETag"), some("\"ab\""))
  try Test.eq(Xml.text(xml, "Missing"), none)
  try Test.eq(Xml.elements(xml, "Part").length, 2)
  Test.eq(Xml.escape("a<b>&\"c\""), "a&lt;b&gt;&amp;&quot;c&quot;")
end
