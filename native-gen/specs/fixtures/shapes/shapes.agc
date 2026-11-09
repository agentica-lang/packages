## The codecs of native-gen: each echo function reads its argument into a C value and makes it again, so the run
## prints `true` when a value comes back equal. `Label` embeds a `Point`, keeps a list as a term and has a field that
## is a C keyword. `misread` reads a term of the wrong type.

struct Point
  x: Int
  y: Int
end

struct Label
  text: String
  data: Bytes
  shown: Bool
  weight: Float
  at: Point
  tags: List[String]
  class: Int
end

extern module "shapes"
  def echo_point(value: Point) -> Point
  def echo_label(value: Label) -> Label
  ## Reads `values` as a Point, which it is not: the call fails.
  def misread(value: Point, values: List[Int]) -> Point
end

def main() -> Void
  if System.args() == ["misread"]
    puts(misread(Point(x: 1, y: 2), [1, 2]))
    return
  end

  point = Point(x: -3, y: 4)
  label = Label(
    text: "héllo",
    data: Bytes.from_list([0, 255]).unwrap!,
    shown: true,
    weight: 2.5,
    at: point,
    tags: ["a", "b"],
    class: 7,
  )

  puts(echo_point(point) == point)
  puts(echo_label(label) == label)
end
