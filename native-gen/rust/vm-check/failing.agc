## The failures of a call against the real VM: `checked(-1)` fails with its Raise, `checked(0)` with its caught panic.

private

extern module "vm_check"
  compute def checked(n: Int) -> Int
end

def main() -> Void
  n = 0
  if System.args().size > 0
    n = -1
  end

  puts(checked(n))
end
