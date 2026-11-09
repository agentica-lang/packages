# Two libraries in one file: the header is made for one block.
extern module "stats"
  def count(values: List[Int]) -> Int
end

extern module "words"
  def length(text: String) -> Int
end
