## The steps of `release.feature`. Each scenario works in a fresh folder, removed when it ends: a copy of the fixture
## project in `project/`, and the releases in `out/`.

import BDD from "std/bdd"
import Release from "../release"

def main() -> Void
  BDD.run([
    BDD.step("a fresh folder", &fresh),
    BDD.step("a copy of the project {string} in it", &copied),
    BDD.step("the release is built", &built),
    BDD.step("the release is built from this agentica.toml:", &built_from),
    BDD.step("the release folder is moved to {string}", &moved),
    BDD.step("the project folder is removed", &project_removed),
    BDD.step("running {string} alone with {string} prints {string} and exits with {int}", &ran),
    BDD.step("the manifest lists these files:", &lists),
    BDD.step("the release passes inspect", &inspected),
    BDD.step("the release is damaged: {string} {string}", &damaged),
    BDD.step("inspect fails as {string} saying {string}", &inspect_fails),
    BDD.step("the release is packed", &packed),
    BDD.step("the archive is named for the version, the system and the architecture", &named),
    BDD.step("the archive passes inspect", &archive_inspected),
    BDD.step("building again fails as {string} saying {string}", &again_fails),
    BDD.step("a project with each of these agentica.toml is refused:", &refused),
    BDD.step("the release lists the system library {string} and {string} and {string}", &libraries),
  ])
end

private

FOLDER = "folder"
ROOT = "root"
ARCHIVE = "archive"
LIBRARIES = "libraries"
RUN_MS = 60_000

def sh(args: List[String]) -> Result[Void]
  child = try Process.spawn_captured(args[0], args.drop(1), Process.Options(timeout_ms: RUN_MS))
  out = Process.output(child, RUN_MS)
  code = Process.wait(child, RUN_MS)
  Process.close(child)
  done = try out
  status = try code
  return error("#{args.join(" ")} exited with #{status}: #{done.stderr}") if status != 0

  ok()
end

def folder_of(ctx: BDD.Context) -> String = JSON.string(BDD.get(ctx, FOLDER).unwrap!).unwrap!

def root_of(ctx: BDD.Context) -> String = JSON.string(BDD.get(ctx, ROOT).unwrap!).unwrap!

def fresh(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  base = System.env("TMPDIR").unwrap_or("/tmp")
  if base.empty?
    base = "/tmp"
  end

  folder = "#{base}/release-#{System.pid()}-#{Time.now.to_us}"
  case sh(["mkdir", "-p", folder])
    ok(_) ->
      kept = BDD.set(ctx, FOLDER, JSON.from(folder))
      BDD.after(kept) do |_done| Path.remove(folder) end
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def copied(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case sh(["cp", "-R", args[0], "#{folder_of(ctx)}/project"])
    ok(_) -> ctx
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def options(ctx: BDD.Context, out: String) -> Release.Options
  Release.Options(
    project: "#{folder_of(ctx)}/project",
    out: "#{folder_of(ctx)}/#{out}",
    agentica: "",
    version: "",
    entry: "",
  )
end

def built(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case Release.build(options(ctx, "out"))
    ok(done) -> BDD.set(ctx, ROOT, JSON.from(done.path))
    error(e) -> BDD.assert(ctx, false, "build gave #{e.kind}: #{e.message}")
  end
end

def built_from(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  written = File.write_text("#{folder_of(ctx)}/project/agentica.toml", BDD.doc_string(ctx))
  return BDD.assert(ctx, false, written.message) if !written.ok?

  case Release.build(options(ctx, "out"))
    ok(done) -> BDD.set(BDD.set(ctx, ROOT, JSON.from(done.path)), LIBRARIES, JSON.from(done.system_libraries))
    error(e) -> BDD.assert(ctx, false, "build gave #{e.kind}: #{e.message}")
  end
end

def libraries(ctx: BDD.Context, args: List[String]) -> BDD.Context
  found = BDD.get(ctx, LIBRARIES).unwrap!
  BDD.assert(ctx, JSON.encode(found) == JSON.encode(args.sort), "the release lists #{JSON.encode(found)}")
end

def moved(ctx: BDD.Context, args: List[String]) -> BDD.Context
  target = "#{folder_of(ctx)}/#{args[0]}"
  case sh(["mkdir", "-p", target])
    ok(_) ->
      destination = "#{target}/release"
      case Path.rename(root_of(ctx), destination)
        ok(_) -> BDD.set(ctx, ROOT, JSON.from(destination))
        error(e) -> BDD.assert(ctx, false, e.message)
      end

    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def project_removed(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  done = Path.remove("#{folder_of(ctx)}/project")
  BDD.assert(ctx, done.ok?, "cannot remove the project: #{done}")
end

def ran(ctx: BDD.Context, args: List[String]) -> BDD.Context
  elsewhere = "#{folder_of(ctx)}/cwd"
  home = "#{folder_of(ctx)}/home"
  made = sh(["mkdir", "-p", elsewhere, home])
  return BDD.assert(ctx, false, made.message) if !made.ok?

  child = Process.spawn_captured(
    "env",
    ["-i", "HOME=#{home}", "#{root_of(ctx)}/#{args[0]}", args[1]],
    Process.Options(chdir: elsewhere, timeout_ms: RUN_MS),
  )

  return BDD.assert(ctx, false, child.message) if !child.ok?

  process = child.unwrap!
  out = Process.output(process, RUN_MS)
  code = Process.wait(process, RUN_MS)
  Process.close(process)
  checked = BDD.assert(ctx, out.ok? and out.unwrap!.stdout.strip == args[2], "#{args[0]} printed #{out}")
  BDD.assert(checked, code == ok(args[3].to_i!), "#{args[0]} exited with #{code}")
end

def lists(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  paths = BDD.table(ctx).drop(1).map { |row| row[0] }
  case Release.inspect(root_of(ctx))
    ok(manifest) ->
      listed = manifest.files.map { |entry| entry.path }
      BDD.assert(ctx, listed == paths, "the manifest lists #{listed}")
    error(e) -> BDD.assert(ctx, false, e.message)
  end
end

def inspected(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case Release.inspect(root_of(ctx))
    ok(manifest) -> BDD.assert(ctx, manifest.files.size == 4, "inspect read #{manifest.files.size} files")
    error(e) -> BDD.assert(ctx, false, "inspect gave #{e.kind}: #{e.message}")
  end
end

def damaged(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = "#{root_of(ctx)}/#{args[1]}"
  done = ok()
  if args[0] == "changes"
    done = File.write_text(path, "changed")
  elsif args[0] == "removes"
    done = Path.remove(path)
  else
    done = File.write_text(path, "extra")
  end

  BDD.assert(ctx, done.ok?, "cannot damage #{path}")
end

def inspect_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case Release.inspect(root_of(ctx))
    ok(_) -> BDD.assert(ctx, false, "inspect passed")
    error(e) ->
      BDD.assert(ctx, e.kind == args[0] and e.message.include?(args[1]), "inspect gave #{e.kind}: #{e.message}")
  end
end

def packed(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case Release.tar(root_of(ctx))
    ok(archive) -> BDD.set(ctx, ARCHIVE, JSON.from(archive))
    error(e) -> BDD.assert(ctx, false, "tar gave #{e.kind}: #{e.message}")
  end
end

def archive_of(ctx: BDD.Context) -> String = JSON.string(BDD.get(ctx, ARCHIVE).unwrap!).unwrap!

def named(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  name = archive_of(ctx).split("/").last
  expected = "hello-1.2.3-#{System.os()}-"
  BDD.assert(ctx, name.start_with?(expected) and name.end_with?(".tar.gz"), "the archive is #{name}")
end

def archive_inspected(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case Release.inspect(archive_of(ctx))
    ok(manifest) -> BDD.assert(ctx, manifest.name == "hello", "the archive holds #{manifest.name}")
    error(e) -> BDD.assert(ctx, false, "inspect gave #{e.kind}: #{e.message}")
  end
end

def again_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case Release.build(options(ctx, "out"))
    ok(_) -> BDD.assert(ctx, false, "the second build passed")
    error(e) -> BDD.assert(ctx, e.kind == args[0] and e.message.include?(args[1]), "gave #{e.kind}: #{e.message}")
  end
end

def unmarked(cell: String) -> String = cell.replace("{NL}", "\n").replace("{Q}", "\"")

def refused(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  checked = ctx
  rows = BDD.table(ctx).drop(1)
  for index in 0...rows.size
    row = rows[index]
    File.write_text("#{folder_of(ctx)}/project/agentica.toml", unmarked(row[0])).unwrap!
    case Release.build(options(ctx, "refused-#{index}"))
      ok(_) -> checked = BDD.assert(checked, false, "#{row[0]} was built")
      error(e) ->
        said = e.message.include?(unmarked(row[2]))
        checked = BDD.assert(checked, e.kind == row[1] and said, "#{row[0]} gave #{e.kind}: #{e.message}")
    end
  end

  checked
end
