## The functions of the vm-check module against the real VM: every String of a large List made in one call comes back
## whole, and the other functions give back what they read.

struct Point
  x: Int
  y: Int
end

extern module "vm_check"
  def strings(n: Int) -> List[String]
  def pairs(named: Map[String, Int]) -> List[String]
  def point(x: Int, y: Int) -> Point
  def bad_point() -> Point
  def sum_x(points: List[Point]) -> Int
  compute def total(values: List[Int]) -> Int
  def filled(n: Int) -> Bytes
  def lookup(named: Map[String, Int], key: String) -> Optional[Int]
end

def main() -> Void
  made = strings(200000)
  whole = true
  at = 0
  for text in made
    if text != "a string long enough to live on the heap #{at}"
      whole = false
    end

    at += 1
  end

  puts("#{made.size} #{whole}")
  named = {"q": 1, "p": 2}
  puts(pairs(named))
  puts(point(3, 4))
  puts(sum_x([Point(x: 1, y: 0), Point(x: 5, y: 0)]))
  puts(total([1, 2, 3]))
  puts(filled(3).to_a)
  puts([lookup(named, "p"), lookup(named, "z")])
  puts(bad_point())
end
