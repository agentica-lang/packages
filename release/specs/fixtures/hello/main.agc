## A small program to release: it greets with the file that the release carries (read with a `std/` module, which the
## release holds too) and exits with the code it is given.

import Toml from "std/toml"

def main() -> Void
  args = System.args()
  root = System.env("RELEASE_ROOT").unwrap_or(".")
  puts("#{greeting("#{root}/assets/greeting.toml")} (#{args.join(" ")})")
  if args.size > 0 and args[0] == "fail"
    System.exit(3)
  end
end

private

def greeting(path: String) -> String
  doc = Toml.parse(File.read_text(path).unwrap!).unwrap!
  case Toml.get(doc, "text")
    ok(Toml.Value.Str(text)) -> text
    _ -> "no greeting"
  end
end
