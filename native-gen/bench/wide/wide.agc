## The cost of the codecs on a struct of 26 fields: a call that only decodes it, one that decodes and makes it again,
## and a call with one Int as the floor. `agentica wide.agc [CALLS]` prints nanoseconds per call of each.

private

struct Wide
  a: Int
  b: Float
  c: Bool
  d: String
  e: Int
  f: Float
  g: Bool
  h: String
  i: Int
  j: Float
  k: Bool
  l: String
  m: Int
  n: Float
  o: Bool
  p: String
  q: Int
  r: Float
  s: Bool
  t: String
  u: Int
  v: Float
  w: Bool
  x: String
  y: Int
  z: Float
end

extern module "wide"
  ## The field `a`, after reading the whole struct.
  def first(value: Wide) -> Int
  def echo(value: Wide) -> Wide
  def floor(value: Int) -> Int
end

def main() -> Void
  args = System.args()
  calls = 100_000
  if !args.empty?
    calls = args[0].to_i!
  end

  wide = Wide(
    a: 0,
    b: 1.5,
    c: false,
    d: "field 3",
    e: 4,
    f: 5.5,
    g: false,
    h: "field 7",
    i: 8,
    j: 9.5,
    k: false,
    l: "field 11",
    m: 12,
    n: 13.5,
    o: false,
    p: "field 15",
    q: 16,
    r: 17.5,
    s: false,
    t: "field 19",
    u: 20,
    v: 21.5,
    w: false,
    x: "field 23",
    y: 24,
    z: 25.5,
  )

  start = Time.monotonic_ns()
  for k in 0...calls
    _ = floor(k)
  end

  puts("one Int: #{(Time.monotonic_ns() - start) / calls} ns per call")
  start = Time.monotonic_ns()
  for _k in 0...calls
    _ = first(wide)
  end

  puts("decode: #{(Time.monotonic_ns() - start) / calls} ns per call")
  start = Time.monotonic_ns()
  for _k in 0...calls
    _ = echo(wide)
  end

  puts("decode and make: #{(Time.monotonic_ns() - start) / calls} ns per call")
end
