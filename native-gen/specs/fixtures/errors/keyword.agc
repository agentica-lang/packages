private

# A parameter that is a C keyword and one that has its new name: both are `int_`.
extern module "stats"
  def pair(int: Int, int_: Int) -> Int
end
