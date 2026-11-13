## The functions of the vm-check module against the real VM: every String of a large List made in one call, short or
## dirty, comes back whole, and the other functions give back what they read.

private

struct Point
  x: Int
  y: Int
end

extern module "vm_check"
  def strings(n: Int) -> List[String]
  compute def staged_strings(n: Int) -> List[String]
  def squares(n: Int) -> Map[Int, Int]
  compute def staged_squares(n: Int) -> Map[Int, Int]
  def labels(n: Int) -> Map[String, Int]
  def pairs(named: Map[String, Int]) -> List[String]
  def point(x: Int, y: Int) -> Point
  def bad_point() -> Point
  def sum_x(points: List[Point]) -> Int
  compute def total(values: List[Int]) -> Int
  def filled(n: Int) -> Bytes
  def lookup(named: Map[String, Int], key: String) -> Optional[Int]
  def echo_rows(rows: List[Map[String, Optional[Result[List[Float]]]]]) -> List[Map[String, Optional[Result[List[Float]]]]]
  compute def echo_staged(
    rows: List[Map[String, Optional[Result[List[Float]]]]],
  ) -> List[Map[String, Optional[Result[List[Float]]]]]
  def borrowed(texts: List[String]) -> Bool
  def describe(n: Int, x: Float, flag: Bool, text: String, data: Bytes) -> String
  resource Counter
  def counter(n: Int) -> Counter
  def count(counter: Counter) -> Int
  def dropped() -> Int
  compute def checked(n: Int) -> Int
end

def main() -> Void
  # While the dirty call runs on the compute pool, the spawned task makes and collects in a short call; a few rounds.
  rows = [{"b": some(ok([1.5, 2.0])), "a": none}, {}, {"e": some(error("no"))}]
  for _round in 1..3
    short = Task.spawn do strings(200000) end
    puts(summary(staged_strings(200000)))
    puts(echo_staged(rows) == rows)
    puts(summary(Task.await(short)))
  end

  puts([squared?(squares(5000), 5000), squared?(staged_squares(5000), 5000)])
  puts(labeled?(labels(5000), 5000))
  named = {"q": 1, "p": 2}
  puts(pairs(named))
  puts(point(3, 4))
  puts(sum_x([Point(x: 1, y: 0), Point(x: 5, y: 0)]))
  puts(total([1, 2, 3]))
  puts(filled(3).to_a)
  puts([lookup(named, "p"), lookup(named, "z")])
  texts = (0..999).to_a.map do |k| "text number #{k} of the argument" end
  puts(borrowed(texts))
  puts([echo_rows(rows) == rows, echo_staged(rows) == rows])
  puts(echo_rows(rows))
  puts(describe(-7, 2.5, true, "héllo", Bytes.from_list([0, 255]).unwrap!))
  # The end of a task frees the resources it made: each Counter is dropped once, after the program read them all.
  made = Task.spawn do
    counters = (0..999).to_a.map do |k| counter(k) end
    sum = 0
    for one in counters
      sum += count(one)
    end

    sum
  end

  puts([Task.await(made), dropped()])
  one = counter(7)
  Native.close(one)
  puts("#{Native.closed?(one)} #{dropped()} #{checked(5)}")
  puts(bad_point())
end

# The count of `made`, and whether each is the String its index gives.
def summary(made: List[String]) -> String
  whole = true
  at = 0
  for text in made
    if text != "a string long enough to live on the heap #{at}"
      whole = false
    end

    at += 1
  end

  "#{made.size} #{whole}"
end

# Whether `map` has the keys 0 to n - 1 in order, each with its square.
def squared?(map: Map[Int, Int], n: Int) -> Bool
  at = 0
  for key in map.keys
    return false if key != at or map[key] != at * at

    at += 1
  end

  at == n
end

# Whether `map` has "label K" for K from 0 to n - 1 in order, each with K.
def labeled?(map: Map[String, Int], n: Int) -> Bool
  at = 0
  for key in map.keys
    return false if key != "label #{at}" or map[key] != at

    at += 1
  end

  at == n
end
