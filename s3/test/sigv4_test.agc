import Encoding from "../src/encoding"
import Sigv4 from "../src/sigv4"
import Types from "../src/types"

private

# The examples of "Signature Calculations for the Authorization Header" and "Authenticating Requests: Using Query
# Parameters" of the S3 documentation (examplebucket, 2013-05-24), and get-vanilla of the AWS Signature Version 4 test
# suite.
EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
AT = "20130524T000000Z"

def docs_scope() -> Sigv4.Scope
  Sigv4.Scope(
    access_key: "AKIAIOSFODNN7EXAMPLE",
    secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region: "us-east-1",
  )
end

def param(name: String, value: String) -> Types.Param = Types.Param(name: name, value: value)

def object_headers(extra: List[Types.Param], hash: String) -> List[Types.Param]
  (
    [param("host", "examplebucket.s3.amazonaws.com"), param("x-amz-content-sha256", hash), param("x-amz-date", AT)] +
    extra
  )
end

def test_get_object_with_a_range() -> Result[Void]
  headers = object_headers([param("Range", "bytes=0-9")], EMPTY)
  signed = Sigv4.sign(docs_scope(), "GET", "/test.txt", [], headers, EMPTY, AT)
  try Test.eq(signed.signature, "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
  try Test.eq(signed.signed_headers, "host;range;x-amz-content-sha256;x-amz-date")
  names = "host;range;x-amz-content-sha256;x-amz-date"
  Test.eq(
    signed.authorization,
    "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=#{names}, Signature=#{signed.signature}",
  )
end

def test_put_object_with_a_signed_body_and_an_encoded_key() -> Result[Void]
  body = "Welcome to Amazon S3."
  hash = Encoding.hex(OpenSSL.Digest.sha256(body.bytes))
  headers = object_headers(
    [param("date", "Fri, 24 May 2013 00:00:00 GMT"), param("x-amz-storage-class", "REDUCED_REDUNDANCY")],
    hash,
  )

  signed = Sigv4.sign(docs_scope(), "PUT", "/#{Encoding.path("test$file.text")}", [], headers, hash, AT)
  Test.eq(signed.signature, "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
end

def test_a_query_with_an_empty_value_and_one_with_two_parameters() -> Result[Void]
  headers = object_headers([], EMPTY)
  lifecycle = Sigv4.sign(docs_scope(), "GET", "/", [param("lifecycle", "")], headers, EMPTY, AT)
  try Test.eq(lifecycle.signature, "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
  listing = Sigv4.sign(docs_scope(), "GET", "/", [param("prefix", "J"), param("max-keys", "2")], headers, EMPTY, AT)
  Test.eq(listing.signature, "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
end

def test_a_presigned_url_for_a_day() -> Result[Void]
  query = Sigv4.presign(docs_scope(), "GET", "examplebucket.s3.amazonaws.com", "/test.txt", [], [], 86_400, AT)
  Test.eq(
    query,
    "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
  )
end

def test_get_vanilla_of_the_signature_test_suite() -> Result[Void]
  scope = Sigv4.Scope(
    access_key: "AKIDEXAMPLE",
    secret_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    region: "us-east-1",
    service: "service",
  )

  headers = [param("Host", "example.amazonaws.com"), param("X-Amz-Date", "20150830T123600Z")]
  try Test.eq(
    Sigv4.canonical_request("GET", "/", [], headers, EMPTY),
    "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\n#{EMPTY}",
  )

  signed = Sigv4.sign(scope, "GET", "/", [], headers, EMPTY, "20150830T123600Z")
  Test.eq(signed.signature, "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
end

def test_header_values_are_trimmed_and_the_same_name_is_joined() -> Result[Void]
  headers = [param("Host", "h"), param("My-Header", "  a   b  "), param("my-header", "c")]
  Test.eq(
    Sigv4.canonical_request("GET", "/", [], headers, EMPTY),
    "GET\n/\n\nhost:h\nmy-header:a b,c\n\nhost;my-header\n#{EMPTY}",
  )
end

def test_a_session_token_is_part_of_a_presigned_query() -> Result[Void]
  scope = Sigv4.Scope(access_key: "AK", secret_key: "SK", region: "eu-west-1", session_token: "tok/en")
  query = Sigv4.presign(scope, "PUT", "h", "/k", [], [], 60, AT)
  Test.assert(query.include?("X-Amz-Security-Token=tok%2Fen"), "the token is in the query: #{query}")
end
