## A small program to release: it greets with the file that the release carries and exits with the code it is given.

def main() -> Void
  args = System.args()
  root = System.env("RELEASE_ROOT").unwrap_or(".")
  puts("#{File.read_text("#{root}/assets/greeting.txt").unwrap!.strip} (#{args.join(" ")})")
  if args.size > 0 and args[0] == "fail"
    System.exit(3)
  end
end
