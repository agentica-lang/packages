## agentica's examples/native_module, on the header of native-gen: one call gives a struct, another reads a CSV text
## into rows of typed cells.

private

struct Summary
  count: Int
  min: Float
  max: Float
  mean: Float
end

enum Cell
  Empty
  Number(Float)
  Text(String)
end

extern module "stats"
  ## The count, smallest, largest and mean of the values; none for no values.
  def summary(values: List[Float]) -> Optional[Summary]
  ## The lines of a CSV text after its header, as maps from the header's names to typed cells.
  def rows(text: String) -> Result[List[Map[String, Cell]]]
end

def main() -> Void
  puts(summary([2.0, 4.0, 9.0]))
  puts(summary([]))
  case rows("name,qty,note\nkiwi,3,\napple,1.5,ripe\n")
    ok(table) -> table.each do |row| puts(row) end
    error(e) -> puts(e.message)
  end

  puts(rows("a,b\n1\n"))
end
