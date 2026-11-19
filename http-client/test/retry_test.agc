import Exchange from "../src/exchange"
import HTTP from "std/http"
import Retry from "../src/retry"

private

POLICY = Retry.Policy(max_retries: 3, delay_ms: 100, max_delay_ms: 1_000)

def answer(status: Int, headers: List[HTTP.Header] = []) -> Result[Exchange.Response]
  ok(Exchange.Response(status: status, headers: headers, body: "".bytes, url: "http://h:80/"))
end

def whole(backoff_ms: Int) -> Int = backoff_ms

def wait(method: String, result: Result[Exchange.Response], tries: Int) -> Optional[Int]
  Retry.wait_ms(POLICY, method, result, tries, 0, &whole)
end

# The IMF-fixdate of a Unix ms.
def http_date(ms: Int) -> String = Time.at_us(ms * 1_000).unwrap!.strftime("%a, %d %b %Y %H:%M:%S GMT")

def test_only_an_idempotent_request_after_a_transient_failure_goes_again() -> Result[Void]
  try Test.eq(wait("GET", answer(503), 0), some(100))
  try Test.eq(wait("PUT", answer(429), 2), some(400))
  try Test.eq(wait("GET", answer(503), 3), none)
  try Test.eq(wait("POST", answer(503), 0), none)
  try Test.eq(wait("get", answer(503), 0), some(100))
  try Test.eq(wait("GET", answer(404), 0), none)
  try Test.eq(wait("GET", error("down", kind: "http_client.network"), 0), some(100))
  try Test.eq(wait("GET", error("slow", kind: "http_client.timeout.read"), 0), some(100))
  try Test.eq(wait("GET", error("slow", kind: "http_client.timeout.request"), 0), none)
  Test.eq(wait("GET", error("big", kind: "http_client.too_large"), 0), none)
end

def test_the_backoff_doubles_up_to_the_most_and_never_overflows() -> Result[Void]
  try Test.eq([0, 1, 2, 3, 4, 40].map { |tries| Retry.backoff_ms(POLICY, tries) }, [100, 200, 400, 800, 1_000, 1_000])
  huge = Retry.Policy(max_retries: 3, delay_ms: 4_000_000_000_000_000_000, max_delay_ms: 9_000_000_000_000_000_000)
  Test.eq(Retry.backoff_ms(huge, 3), 9_000_000_000_000_000_000)
end

def test_retry_after_is_waited_unless_it_is_over_the_most() -> Result[Void]
  try Test.eq(wait("GET", answer(503, [HTTP.Header(name: "retry-after", value: "1")]), 0), some(1_000))
  try Test.eq(wait("GET", answer(503, [HTTP.Header(name: "retry-after", value: "2")]), 0), none)
  Test.eq(wait("GET", answer(503, [HTTP.Header(name: "retry-after", value: "soon")]), 0), some(100))
end

def test_an_http_date_reads_back_as_the_time_it_was_written_from() -> Result[Void]
  for ms in [0, 784_111_777_000, 951_782_400_000, 1_709_164_799_000, 4_102_444_800_000, 1_234_567_890_000]
    try Test.eq("#{http_date(ms)} #{Retry.http_date_ms(http_date(ms))}", "#{http_date(ms)} #{some(ms)}")
  end

  try Test.eq(http_date(784_111_777_000), "Sun, 06 Nov 1994 08:49:37 GMT")
  try Test.eq(Retry.http_date_ms("Sun, 06 Nov 1994 08:49:37 GMT"), some(784_111_777_000))
  try Test.eq(Retry.http_date_ms("Sunday, 06-Nov-94 08:49:37 GMT"), none)
  try Test.eq(Retry.http_date_ms("Sun, 06 Nov 99999999999999 08:49:37 GMT"), none)
  try Test.eq(Retry.http_date_ms("Fri, 31 Dec 9999 23:59:59 GMT"), some(253_402_300_799_000))
  headers = [HTTP.Header(name: "retry-after", value: http_date(10_000))]
  Test.eq(Retry.retry_after_ms(headers, 4_000), some(6_000))
end
