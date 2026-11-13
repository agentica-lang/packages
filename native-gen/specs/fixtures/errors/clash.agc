private

# Two functions whose names map to one C identifier: stats_empty_p.
extern module "stats"
  def empty?(text: String) -> Bool
  def empty_p(text: String) -> Bool
end
