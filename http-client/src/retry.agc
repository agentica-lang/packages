## When a request goes again, and after how long: only an idempotent method, after a transient error (a connect or
## read timeout, a broken connection) or a transient status (408, 429, 500, 502, 503, 504), at most `retries` times.
## The wait doubles from `delay_ms` on each try, up to `max_delay_ms`, with jitter; a `Retry-After` of the response
## (seconds or an HTTP date) is waited as it is, and one over `max_delay_ms` gives the response back instead.

import Exchange from "exchange"
import HTTP from "std/http"

## The retry settings of a client.
struct Policy
  retries: Int
  delay_ms: Int
  max_delay_ms: Int
end

## The wait before the next try, after `tries` retries, or none when `result` is final. `now_ms` is the wall clock
## (for an HTTP date), and `jitter` takes the backoff and gives the wait.
def wait_ms(
  policy: Policy,
  method: String,
  result: Result[Exchange.Response],
  tries: Int,
  now_ms: Int,
  jitter: Fn[Int, Int],
) -> Optional[Int]
  return none if tries >= policy.retries or not IDEMPOTENT.include?(method)

  case result
    ok(response) if TRANSIENT_STATUSES.include?(response.status) ->
      case retry_after_ms(response.headers, now_ms)
        some(ms) if ms <= policy.max_delay_ms -> some(ms)
        some(_) -> none
        none -> some(jitter.call(backoff_ms(policy, tries)))
      end

    error(e) if transient?(e) -> some(jitter.call(backoff_ms(policy, tries)))
    _ -> none
  end
end

## `delay_ms` doubled `tries` times, at most `max_delay_ms`.
def backoff_ms(policy: Policy, tries: Int) -> Int
  wait = policy.delay_ms
  doubled = 0
  while doubled < tries and wait < policy.max_delay_ms
    wait = wait * 2
    doubled = doubled + 1
  end

  [wait, policy.max_delay_ms].min.unwrap!
end

## The wait that `Retry-After` asks for, in ms: delta seconds, or the time until an HTTP date (IMF-fixdate, as
## `Sun, 06 Nov 1994 08:49:37 GMT`). None without one, or with one that does not read.
def retry_after_ms(headers: List[HTTP.Header], now_ms: Int) -> Optional[Int]
  values = HTTP.header_values(headers, "retry-after")
  return none if values.empty?

  text = values[0].strip
  case text.to_i
    ok(seconds) if seconds >= 0 -> some([seconds, MAX_SECONDS].min.unwrap! * 1000)
    ok(_) -> none
    error(_) ->
      case http_date_ms(text)
        some(at) -> some([at - now_ms, 0].max.unwrap!)
        none -> none
      end
  end
end

## The Unix ms of an IMF-fixdate, or none.
def http_date_ms(text: String) -> Optional[Int]
  parts = text.split(" ")
  return none if parts.size != 6 or parts[5] != "GMT" or not parts[0].end_with?(",")

  clock = parts[4].split(":")
  return none if clock.size != 3

  numbers = [parts[1], parts[3], clock[0], clock[1], clock[2]].map { |part| part.to_i.unwrap_or(-1) }
  month = MONTHS.index(parts[2])
  return none if numbers.min.unwrap_or(-1) < 0 or not month.some?

  day = numbers[0]
  year = numbers[1]
  return none if day < 1 or day > 31 or year < 1970 or numbers[2] > 23 or numbers[3] > 59 or numbers[4] > 60

  days = days_from_civil(year, month.unwrap! + 1, day)
  some((((days * 24 + numbers[2]) * 60 + numbers[3]) * 60 + numbers[4]) * 1000)
end

private

IDEMPOTENT = ["GET", "HEAD", "OPTIONS", "TRACE", "PUT", "DELETE"]
TRANSIENT_STATUSES = [408, 429, 500, 502, 503, 504]
TRANSIENT_KINDS = ["http_client.timeout.connect", "http_client.timeout.read", "http_client.network"]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
# Past a day the wait is long enough, and the product stays far from overflow.
MAX_SECONDS = 86_400

def transient?(e: Error) -> Bool = TRANSIENT_KINDS.any? { |kind| e.is_a?(kind) }

# Days since 1970-01-01 of a date of the proleptic Gregorian calendar, for a year from 1970 (Howard Hinnant's
# `days_from_civil`: a year that starts in March puts the leap day last).
def days_from_civil(year: Int, month: Int, day: Int) -> Int
  y = year
  shifted = month + 9
  if month <= 2
    y = y - 1
  end

  if month > 2
    shifted = month - 3
  end

  era = y / 400
  year_of_era = y - era * 400
  day_of_year = (153 * shifted + 2) / 5 + day - 1
  day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year
  era * 146_097 + day_of_era - 719_468
end
