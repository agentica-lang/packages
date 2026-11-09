# A struct named as a type of the Rust prelude, which the Rust file uses.
struct Vec
  x: Int
end

extern module "stats"
  def first(values: List[Int]) -> Vec
end
