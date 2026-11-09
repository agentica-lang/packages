## Every kind of argument that native-gen decodes, the names it changes and a resource. Each function answers with what
## it got, so the run shows that each wrapper passed its arguments on.

struct Point
  x: Int
  y: Int
end

enum Shape
  Dot
  Circle(Point, Float)
end

extern module "kinds"
  ## A count kept in C.
  resource Counter
  ## A new counter at `start`.
  def counter(start: Int) -> Counter
  ## The counter's value after adding `step`.
  def bump!(counter: Counter, step: Int) -> Int
  def describe(n: Int, x: Float, flag: Bool, text: String, data: Bytes) -> String
  ## Whether `text` is empty.
  ##
  ## A second paragraph, and a */ that must not end the comment.
  def empty?(text: String) -> Bool
  def keywords(int: Int, env: String, class: Bool) -> String
  def nothing() -> Void
  compute def total(values: List[Int]) -> Int
  ## The center of a circle; none for a dot.
  def corner(shape: Shape) -> Optional[Point]
end

def main() -> Void
  c = counter(40)
  puts(bump!(c, 2))
  puts(describe(-7, 2.5, true, "héllo", Bytes.from_list([0, 255]).unwrap!))
  puts([empty?(""), empty?("x")])
  puts(keywords(1, "e", false))
  nothing()
  puts(total([1, 2, 3]))
  puts([corner(Shape.Dot), corner(Shape.Circle(Point(x: 3, y: 4), 1.5))])
end
