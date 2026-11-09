## The shapes of the Rust file that the C fixtures do not reach, built only by rust/gen-check: a recursive struct,
## two types that lead to each other, Maps of Int and Bytes keys, resources in a List and an Optional, a compute def
## of a type that holds a term, a method that borrows only in its result, a struct of no fields, and the names and
## types that clippy would flag.

struct Node
  value: Int
  next: Optional[Node]
end

enum Expr
  Num(Int)
  Apply(Call)
end

struct Call
  name: String
  args: List[Expr]
end

struct Unit
end

enum Color
  RedColor
  BlueColor
end

struct HTTP
  table: Map[String, List[Optional[Result[List[Int]]]]]
end

extern module "shapes2"
  ## A handle with an id.
  resource Handle
  ## The chain of `n` nodes, n first.
  ##
  ## ```
  ## chain(2) == Node(value: 2, next: some(Node(value: 1, next: none)))
  ## ```
  ##
  ##     chain(0) is a node of 0
  ##
  ## ~~~
  ## no Rust here either
  ## ~~~
  ##
  ## ````
  ## a fence of four, closed by five
  ## `````
  ##
  ## - an item
  ##
  ##     more of the item, not code
  def chain(n: Int) -> Node
  ## The sum of the values of the chain, read in the compute pool.
  compute def total(node: Node) -> Int
  ## The value of an expression: a Call adds its arguments.
  def eval(expr: Expr) -> Int
  def lengths(words: Map[Int, String]) -> Map[Int, Int]
  def sizes(blobs: Map[Bytes, Int]) -> Int
  def handles(n: Int) -> List[Handle]
  def maybe(n: Int) -> Optional[Handle]
  def handle_id(handle: Handle) -> Int
  def unit(u: Unit) -> Unit
  def colors(color: Color) -> Color
  def http(value: HTTP) -> HTTP
  def seven(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int) -> Int
end

def main() -> Void
  node = chain(3)
  puts(node)
  puts(total(node))
  puts(eval(Expr.Apply(Call(name: "add", args: [Expr.Num(1), Expr.Apply(Call(name: "add", args: [Expr.Num(2)]))]))))
  puts(lengths({1: "a", 2: "bcd"}))
  puts(sizes({Bytes.from_list([1, 2]).unwrap!: 3, Bytes.from_list([]).unwrap!: 4}))
  puts(handles(2).map do |h| handle_id(h) end)
  puts([maybe(0).map do |h| handle_id(h) end, maybe(5).map do |h| handle_id(h) end])
  puts(unit(Unit()))
  puts(colors(Color.RedColor))
  value = HTTP(table: {"t": [some(ok([1])), none]})
  puts(http(value) == value)
  puts(seven(1, 2, 3, 4, 5, 6, 7))
end
