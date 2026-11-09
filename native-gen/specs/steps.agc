## The steps of `header.feature`. The command runs as a program under test; a step here gives each scenario a package
## cache of its own, so a native build in it never reuses or leaves an entry in the user's cache.

import BDD from "std/bdd"

def main() -> Void
  BDD.run([BDD.step("a fresh package cache", &fresh_cache)])
end

# A new private folder for XDG_CACHE_HOME of the program, removed when the scenario ends.
def fresh_cache(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  base = System.env("TMPDIR").unwrap_or("/tmp")
  if base.empty?
    base = "/tmp"
  end

  folder = Path.join([base, "native-gen-cache-#{System.pid()}-#{Random.int(0, 1_000_000_000)}"]).unwrap!
  made = Dir.mkdir_private(folder)
  if !made.ok?
    return BDD.assert(ctx, false, "cannot make #{folder}: #{made.message}")
  end

  kept = BDD.after(ctx) do |_done| Path.remove(folder) end
  return BDD.given_env(kept, "XDG_CACHE_HOME", folder)
end
