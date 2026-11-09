## The codecs of native-gen: each echo function reads its argument into a C value and makes it again, so the run
## prints `true` when a value comes back equal. `Label` embeds a `Point` and keeps a list as a term; `Shape` has
## payloads; `Tree` is recursive, so its payloads stay terms. `misread` reads a term of the wrong type, the
## `misread_*` ones a value with a String where its Point has an Int.

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

enum Shape
  Dot
  Circle(Point, Float)
  Tagged(Label)
end

enum Tree
  Leaf(Int)
  Node(Tree, Tree)
end

extern module "shapes"
  def echo_point(value: Point) -> Point
  def echo_label(value: Label) -> Label
  def echo_shape(value: Shape) -> Shape
  def echo_tree(value: Tree) -> Tree
  ## A circle made with the one-line constructor of its variant.
  def circle(x: Int, y: Int, radius: Float) -> Shape
  ## Reads `values` as a Point, which it is not: the call fails.
  def misread(value: Point, values: List[Int]) -> Point
  ## Builds a Label whose Point has a String `x` and reads it: the call fails at `Label.at.x`.
  def misread_nested(value: Label) -> Label
  ## Builds a Circle whose Point has a String `x` and reads it: the call fails at `Shape.Circle.0.x`.
  def misread_payload(value: Shape) -> Shape
  ## The Label of `misread_nested`, given back without reading it, for the wrapper of `echo_label` to read.
  def bad_label(value: Label) -> Label
end

def main() -> Void
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

  call = System.args().join(" ")
  if call == "misread"
    puts(misread(point, [1, 2]))
  elsif call == "misread_nested"
    puts(misread_nested(label))
  elsif call == "echo_label"
    puts(echo_label(bad_label(label)))
  elsif call == "misread_payload"
    puts(misread_payload(Shape.Dot))
  else
    echo_all(point, label)
  end
end

def echo_all(point: Point, label: Label) -> Void
  puts(echo_point(point) == point)
  puts(echo_label(label) == label)
  puts([Shape.Dot, Shape.Circle(point, 1.5), Shape.Tagged(label)].map do |shape| echo_shape(shape) == shape end)
  tree = Tree.Node(Tree.Leaf(1), Tree.Node(Tree.Leaf(2), Tree.Leaf(3)))
  puts(echo_tree(tree) == tree)
  puts(circle(1, 2, 0.5))
end
