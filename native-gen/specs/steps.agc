## The steps of `header.feature`. The command runs as a program under test; the steps here give a scenario a package
## cache of its own, so a native build never reuses or leaves an entry in the user's cache, and a folder for the header
## that `--output` writes. Both folders are removed when the scenario ends.

import BDD from "std/bdd"

# The name in the context of the header file that `--output` writes.
WRITTEN = "written"

# A fresh folder and the context that removes it at the end of the scenario.
struct Made
  ctx: BDD.Context
  path: String
end

def main() -> Void
  BDD.run([
    BDD.step("a fresh package cache", &fresh_cache),
    BDD.step("the header goes to a fresh folder as {string}", &fresh_output),
    BDD.step("the written header includes:", &written_header),
  ])
end

def fresh_cache(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case fresh_folder(ctx)
    ok(made) -> return BDD.given_env(made.ctx, "XDG_CACHE_HOME", made.path)
    error(message) -> return BDD.assert(ctx, false, message)
  end
end

# `--output` to the file `args[0]` in a fresh folder, whose path the scenario keeps.
def fresh_output(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case fresh_folder(ctx)
    ok(made) ->
      path = Path.join([made.path, args[0]]).unwrap!
      kept = BDD.set(made.ctx, WRITTEN, JSON.from(path))
      return BDD.given_argument(BDD.given_argument(kept, "--output"), path)
    error(message) -> return BDD.assert(ctx, false, message)
  end
end

def written_header(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  path = JSON.string(BDD.get(ctx, WRITTEN).unwrap!).unwrap!
  case File.read_text(path)
    ok(text) -> return BDD.assert(ctx, text.include?(BDD.doc_string(ctx)), "#{path} is not the header: #{text}")
    error(message) -> return BDD.assert(ctx, false, "cannot read #{path}: #{message}")
  end
end

# A new private folder, removed when the scenario ends, with the context that holds its removal.
def fresh_folder(ctx: BDD.Context) -> Result[Made]
  base = System.env("TMPDIR").unwrap_or("/tmp")
  if base.empty?
    base = "/tmp"
  end

  folder = try Path.join([base, "native-gen-#{System.pid()}-#{Random.int(0, 1_000_000_000)}"])
  made = Dir.mkdir_private(folder)
  if !made.ok?
    return error("cannot make #{folder}: #{made.message}")
  end

  return ok(Made(ctx: BDD.after(ctx) do |_done| Path.remove(folder) end, path: folder))
end
