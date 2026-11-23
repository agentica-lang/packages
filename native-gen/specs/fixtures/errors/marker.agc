private

# A doc line that starts with @ and is not a marker: a typo of @fresh.
extern module "stats"
  resource Handle
  ## @Fresh
  def make() -> Handle
end
