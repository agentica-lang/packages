## Lists and Maps through the cursors and builders of the header: each function reads its arguments item by item and
## builds what it gives.

struct Point
  x: Int
  y: Int
end

extern module "lists"
  ## The sum of each row.
  def sums(rows: List[List[Float]]) -> List[Float]
  ## The bytes of each word.
  def codes(words: List[String]) -> Map[String, List[Int]]
  ## The points of `named`, in its order, each moved by `by`.
  def moved(named: Map[String, Point], by: Point) -> List[Point]
  ## The sum of each key times its values, and 1000 for each item of `maybe` that is there.
  def tally(groups: Map[Int, List[Int]], maybe: List[Optional[Int]]) -> Int
  ## Reads a List whose second item is a String: the call fails at `List[Int].1`.
  def misread_list(values: List[Int]) -> Int
  ## Reads a Map whose first Point has a String `x`: the call fails at `Map[String, Point].0.value.x`.
  def misread_map(named: Map[String, Point]) -> Int
  ## Calls the wrapper of `sums` with a bad row in its argument: the call fails at `argument 1: List[List[Float]].1`.
  def misread_argument() -> Int
  ## Calls the wrapper of `sums` with a bad item in the first row: the call fails at `argument 1: List[Float].1`.
  def misread_nested_argument() -> Int
  ## Calls the wrapper of `tally` with a bad value for the third key: the call fails at
  ## `argument 1: Map[Int, List[Int]].2.value`.
  def misread_map_argument() -> Int
  ## Calls the wrapper of `tally` with a bad item in the value of the second key: the call fails at
  ## `argument 1: List[Int].2`.
  def misread_map_value() -> Int
end

def main() -> Void
  call = System.args().join(" ")
  named = {"p": Point(x: 1, y: 2), "q": Point(x: -1, y: 0)}
  if call == "misread_list"
    puts(misread_list([1]))
  elsif call == "misread_map"
    puts(misread_map(named))
  elsif call == "misread_argument"
    puts(misread_argument())
  elsif call == "misread_nested_argument"
    puts(misread_nested_argument())
  elsif call == "misread_map_argument"
    puts(misread_map_argument())
  elsif call == "misread_map_value"
    puts(misread_map_value())
  else
    puts(sums([[1.0, 2.5], [], [4.0]]))
    puts(codes(["ab", "", "é"]))
    puts(moved(named, Point(x: 10, y: 20)))
    empty: Map[Int, List[Int]] = {}
    puts([tally({1: [2, 3], 4: [5]}, [some(1), none]), tally(empty, [])])
  end
end
