## The `@fresh` line of a doc: its row is `AN_FRESH` or'd with the mode, and the header needs API 1.5. The header is the
## golden of the feature; it is not built, since Agentica 0.35.0 does not know `AN_FRESH`.

private

extern module "fresh"
  resource Handle
  ## A handle that owns all its memory.
  ##
  ## @fresh
  compute def make(size: Int) -> Result[Handle]
  ## @fresh
  def small(size: Int) -> Handle
  ## @fresh
  ##
  ## Makes a handle.
  def first(size: Int) -> Handle
  ## A handle made from another one, which it keeps alive, so it is not @fresh.
  def view(handle: Handle) -> Handle
end

def main() -> Void
  puts("not run")
end
