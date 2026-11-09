## Optional and Result through the header: each one that is read is a C struct, each one that is made has a
## constructor, and each function gives back what it read.

struct Point
  x: Int
  y: Int
end

struct Box
  maybe: Optional[Int]
  outcome: Result[String]
end

extern module "options"
  def echo_optional(value: Optional[Point]) -> Optional[Point]
  def echo_result(value: Result[Int]) -> Result[Int]
  def echo_nested(value: Optional[Result[List[Int]]]) -> Optional[Result[List[Int]]]
  ## The value of `maybe` (0 when none) plus the length of the String of `outcome` (100 for an error), read from the
  ## terms of the fields with _get.
  def open_box(box: Box) -> Int
  ## The first String of `values` that is there.
  def first_some(values: List[Optional[String]]) -> Optional[String]
  ## Reads a List whose Result holds a String: the call fails at `List[Result[Int]].0.ok`.
  def misread_result(values: List[Result[Int]]) -> Int
  ## Reads a List whose Point has a String `x`: the call fails at `List[Optional[Point]].0.some.x`.
  def misread_optional(values: List[Optional[Point]]) -> Int
  ## Calls the wrapper of `echo_nested` with `some(ok([1, 2, "a"]))`: the call fails at `argument 1: List[Int].2`.
  def misread_nested() -> Int
end

def main() -> Void
  call = System.args().join(" ")
  if call == "misread_result"
    puts(misread_result([ok(1)]))
  elsif call == "misread_optional"
    puts(misread_optional([none]))
  elsif call == "misread_nested"
    puts(misread_nested())
  else
    puts([echo_optional(some(Point(x: 1, y: 2))), echo_optional(none)])
    puts([echo_result(ok(3)), echo_result(error("no"))])
    puts([echo_nested(some(ok([1, 2]))), echo_nested(some(error("e"))), echo_nested(none)])
    puts([first_some([none, some("b"), some("c")]), first_some([])])
    puts([open_box(Box(maybe: some(4), outcome: error("x"))), open_box(Box(maybe: none, outcome: ok("yes")))])
  end
end
