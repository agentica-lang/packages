# A field that is a C keyword and one that has its new name: both are the member `class_`.
struct Pair
  class: Int
  class_: Int
end

extern module "stats"
  def first(pair: Pair) -> Int
end
