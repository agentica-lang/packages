## Rows per second of `Csv.parse` and `Csv.encode` on a generated table of about 10 MB.
##
##   agentica bench/rows.agc [ROWS]

import Csv from "../csv"

def main() -> Void
  args = System.args()
  count = ROWS
  if args.size > 0
    count = args[0].to_i!
  end

  rows = table(count)
  t0 = Time.monotonic_ms()
  text = Csv.encode(rows).unwrap!
  encoded_ms = Time.monotonic_ms() - t0
  t1 = Time.monotonic_ms()
  parsed = Csv.parse(text).unwrap!
  parsed_ms = Time.monotonic_ms() - t1
  puts("#{count} rows, #{text.bytes.size} bytes, round trip #{parsed == rows}")
  puts("encode #{per_second(count, encoded_ms)} rows/s, parse #{per_second(count, parsed_ms)} rows/s")
end

private

ROWS = 100_000

# Six fields of about 15 bytes, one with a comma and one with a quote, so that quoting is part of the work.
def table(count: Int) -> List[List[String]]
  (0...count).map(
    ->(i) { ["id#{i}", "name number #{i}", "a, b #{i}", "say \"#{i}\"", "plain text of row #{i}", "#{i * 7}"] },
  )
end

def per_second(count: Int, ms: Int) -> Int
  return 0 if ms <= 0

  (count * 1000) / ms
end
