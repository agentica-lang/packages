private

# @fresh on a function whose result is a plain value: there is no resource to own its memory.
extern module "stats"
  ## @fresh
  def count() -> Int
end
