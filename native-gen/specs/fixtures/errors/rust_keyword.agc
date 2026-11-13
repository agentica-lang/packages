private

# Two parameters that map to one Rust name: `type` is a keyword, so it gets a trailing `_`.
extern module "stats"
  def count(type: Int, type_: Int) -> Int
end
