## The functions of the vm-check module against the real VM: every String of a large List made in one call comes back
## whole.

extern module "vm_check"
  def strings(n: Int) -> List[String]
end

def main() -> Void
  made = strings(200000)
  whole = true
  at = 0
  for text in made
    if text != "a string long enough to live on the heap #{at}"
      whole = false
    end

    at += 1
  end

  puts("#{made.size} #{whole}")
end
