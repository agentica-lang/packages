## Prints 42 with the module built from source by `agentica twice.agc`.

extern module "twice"
  def twice(n: Int) -> Int
end

def main() -> Void
  puts(twice(21))
end
