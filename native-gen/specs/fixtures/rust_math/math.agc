## A native module written in Rust: `rust/src/lib.rs` implements the block on the file that native-gen makes from it,
## and `cli.agc build math.agc` builds it into native/ and adds its entry to agentica.toml.

struct Point
  x: Float
  y: Float
end

extern module "math"
  ## The sum of a and b.
  def add(a: Int, b: Int) -> Int
  ## The mean of the values; none for no values.
  def mean(values: List[Float]) -> Optional[Float]
  ## x kept between low and high.
  def clamp(x: Float, low: Float, high: Float) -> Float
  ## The point halfway between a and b.
  def midpoint(a: Point, b: Point) -> Point
end

def main() -> Void
  puts(add(2, 3))
  puts(mean([1.0, 2.0, 6.0]))
  puts(mean([]))
  puts(clamp(12.5, 0.0, 10.0))
  puts(midpoint(Point(x: 0.0, y: 0.0), Point(x: 4.0, y: 2.0)))
end
