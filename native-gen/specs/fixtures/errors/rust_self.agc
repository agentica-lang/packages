private

# A variant named Self, a keyword of Rust.
enum Who
  Self
  Other
end

extern module "stats"
  def who(n: Int) -> Who
end
