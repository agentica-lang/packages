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
    BDD.step(
      "running {string} alone from the release with {string} prints {string} and exits with {int}",
      &ran_in_release,
    ),
    BDD.step(
      "running {string} alone from another folder with {string} prints {string} and exits with {int}",
      &ran_elsewhere,
    ),
    BDD.step("running the launcher through a link fails saying {string}", &linked),
    BDD.step("a file {string} beside the project", &beside),
    BDD.step("the project has a link {string} to {string}", &linking),
    BDD.step("the project has the dependency {string} with this agentica.toml:", &dependency),
    BDD.step("the project has the path dependency {string} at {string} with this agentica.toml:", &path_dependency),
    BDD.step("the folder {string} of deps has this agentica.toml:", &folder_of_deps),
    BDD.step("the project is in a workspace with the member {string} that has this agentica.toml:", &workspace_member),
    BDD.step("the lock names the package {string} that is not installed", &locked),
    BDD.step("building fails as {string} saying {string}", &again_fails),
    BDD.step(
      "building with a program that is not agentica fails as {string} saying {string} and leaves nothing",
      &broken,
    ),
    BDD.step("packing again fails as {string} saying {string}", &packing_fails),
    BDD.step("the archive is made again with {string}", &archive_changed),
    BDD.step("inspecting the new archive fails as {string} saying {string}", &new_archive_fails),
    BDD.step("these commands of cli.agc give these exit codes and lines:", &commands),
    BDD.step("the manifest lists these files:", &lists),
    BDD.step("the release passes inspect", &inspected),
    BDD.step("the release is damaged: {string} {string}", &damaged),
    BDD.step("inspect fails as {string} saying {string}", &inspect_fails),
    BDD.step("the release is packed", &packed),
    BDD.step("the archive is named for the version, the system and the architecture", &named),
    BDD.step("the archive passes inspect", &archive_inspected),
    BDD.step("building again fails as {string} saying {string}", &again_fails),
    BDD.step("a project with each of these agentica.toml is refused:", &refused),
    BDD.step(
      "the release lists the system library {string} on linux, {string} on macos and {string} on windows",
      &libraries,
    ),
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
  Release.Options(project: "#{folder_of(ctx)}/project", out: "#{folder_of(ctx)}/#{out}", agentica: "", entry: "")
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

# Only the library of the system that runs the specs is listed.
def libraries(ctx: BDD.Context, args: List[String]) -> BDD.Context
  found = BDD.get(ctx, LIBRARIES).unwrap!
  wanted = {"linux": args[0], "macos": args[1], "windows": args[2]}
  BDD.assert(ctx, JSON.encode(found) == JSON.encode([wanted[System.os()]]), "the release lists #{JSON.encode(found)}")
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

def ran_in_release(ctx: BDD.Context, args: List[String]) -> BDD.Context = run_alone(ctx, root_of(ctx), args)

def ran_elsewhere(ctx: BDD.Context, args: List[String]) -> BDD.Context
  elsewhere = "#{folder_of(ctx)}/cwd"
  made = sh(["mkdir", "-p", elsewhere])
  return BDD.assert(ctx, false, made.message) if !made.ok?

  run_alone(ctx, elsewhere, ["#{root_of(ctx)}/#{args[0]}", args[1], args[2], args[3]])
end

# The program is `args[0]` (a path from `dir`), started by `env -i` with a CDPATH that would hijack a `cd` of the
# launcher, and a HOME that is empty.
def run_alone(ctx: BDD.Context, dir: String, args: List[String]) -> BDD.Context
  home = "#{folder_of(ctx)}/home"
  made = sh(["mkdir", "-p", home])
  return BDD.assert(ctx, false, made.message) if !made.ok?

  child = Process.spawn_captured(
    "env",
    ["-i", "HOME=#{home}", "CDPATH=/", args[0], args[1]],
    Process.Options(chdir: dir, timeout_ms: RUN_MS),
  )

  return BDD.assert(ctx, false, child.message) if !child.ok?

  process = child.unwrap!
  out = Process.output(process, RUN_MS)
  code = Process.wait(process, RUN_MS)
  Process.close(process)
  checked = BDD.assert(ctx, out.ok? and out.unwrap!.stdout.strip == args[2], "#{args[0]} printed #{out}")
  BDD.assert(checked, code == ok(args[3].to_i!), "#{args[0]} exited with #{code}")
end

def linked(ctx: BDD.Context, args: List[String]) -> BDD.Context
  link = "#{folder_of(ctx)}/launcher-link"
  made = sh(["ln", "-s", "#{root_of(ctx)}/bin/hello", link])
  return BDD.assert(ctx, false, made.message) if !made.ok?

  child = Process.spawn_captured("env", ["-i", link], Process.Options(timeout_ms: RUN_MS))
  return BDD.assert(ctx, false, child.message) if !child.ok?

  process = child.unwrap!
  out = Process.output(process, RUN_MS)
  code = Process.wait(process, RUN_MS)
  Process.close(process)
  said = out.ok? and out.unwrap!.stderr.include?(args[0])
  BDD.assert(BDD.assert(ctx, said, "the launcher said #{out}"), code == ok(1), "the launcher exited with #{code}")
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
  elsif args[0] == "locks"
    done = sh(["chmod", "644", path])
  elsif args[0] == "lists"
    manifest = "#{root_of(ctx)}/releases/manifest.json"
    text = File.read_text(manifest).unwrap!
    done = File.write_text(
      manifest,
      text.replace("\"files\":[", "\"files\":[{\"path\":\"#{args[1]}\",\"sha256\":\"00\"},"),
    )
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

def packing_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case Release.tar("#{root_of(ctx)}/")
    ok(_) -> BDD.assert(ctx, false, "the second tar passed")
    error(e) -> BDD.assert(ctx, e.kind == args[0] and e.message.include?(args[1]), "gave #{e.kind}: #{e.message}")
  end
end

def beside(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = "#{folder_of(ctx)}/#{args[0]}"
  parts = path.split("/")
  made = sh(["mkdir", "-p", parts.take(parts.size - 1).join("/")])
  return BDD.assert(ctx, false, made.message) if !made.ok?

  BDD.assert(ctx, File.write_text(path, "outside").ok?, "cannot write #{path}")
end

def linking(ctx: BDD.Context, args: List[String]) -> BDD.Context
  made = sh(["ln", "-s", args[1], "#{folder_of(ctx)}/project/#{args[0]}"])
  BDD.assert(ctx, made.ok?, "cannot link #{args[0]}")
end

def dependency(ctx: BDD.Context, args: List[String]) -> BDD.Context
  made = write_manifest(ctx, "#{folder_of(ctx)}/project/deps/#{args[0]}")
  return BDD.assert(ctx, false, made.message) if !made.ok?

  locked_as(ctx, "name = \"#{args[0]}\"\n")
end

def folder_of_deps(ctx: BDD.Context, args: List[String]) -> BDD.Context
  made = write_manifest(ctx, "#{folder_of(ctx)}/project/deps/#{args[0]}")
  BDD.assert(ctx, made.ok?, "cannot write the manifest: #{made}")
end

def path_dependency(ctx: BDD.Context, args: List[String]) -> BDD.Context
  made = write_manifest(ctx, "#{folder_of(ctx)}/project/#{args[1]}")
  return BDD.assert(ctx, false, made.message) if !made.ok?

  locked_as(ctx, "name = \"#{args[0]}\"\npath = \"#{args[1]}\"\n")
end

# A workspace in the folder above the project, with one member; the lock names the workspace (no folder of its own)
# and the member.
def workspace_member(ctx: BDD.Context, args: List[String]) -> BDD.Context
  workspace = "[workspace]\nrepository = \"https://example.invalid/r\"\nmembers = [\"#{args[0]}\"]\n"
  written = File.write_text("#{folder_of(ctx)}/agentica.toml", workspace)
  return BDD.assert(ctx, false, written.message) if !written.ok?

  made = write_manifest(ctx, "#{folder_of(ctx)}/#{args[0]}")
  return BDD.assert(ctx, false, made.message) if !made.ok?

  members = (
    "name = \"ws\"\nworkspace = true\n\n[[package]]\nname = \"#{args[0]}\"\nworkspace = true\nsubdir = \"#{args[0]}\"\n"
  )

  locked_as(ctx, members)
end

def write_manifest(ctx: BDD.Context, folder: String) -> Result[Void]
  try sh(["mkdir", "-p", folder])
  File.write_text("#{folder}/agentica.toml", BDD.doc_string(ctx))
end

def locked(ctx: BDD.Context, args: List[String]) -> BDD.Context = locked_as(ctx, "name = \"#{args[0]}\"\n")

def locked_as(ctx: BDD.Context, entry: String) -> BDD.Context
  lock = "version = 1\n\n[[package]]\n#{entry}"
  BDD.assert(ctx, File.write_text("#{folder_of(ctx)}/project/agentica.lock", lock).ok?, "cannot write the lock")
end

# A program that answers `--version` and fails at the compile, the way a broken binary does.
def broken(ctx: BDD.Context, args: List[String]) -> BDD.Context
  fake = "#{folder_of(ctx)}/not-agentica"
  script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 0.0.1; exit 0; fi\necho not a compiler >&2\nexit 1\n"
  made = File.write_text(fake, script)
  return BDD.assert(ctx, false, made.message) if !made.ok?

  _ = sh(["chmod", "755", fake])
  chosen = Release.Options(
    project: "#{folder_of(ctx)}/project",
    out: "#{folder_of(ctx)}/out",
    agentica: fake,
    entry: "",
  )

  case Release.build(chosen)
    ok(_) -> BDD.assert(ctx, false, "the build passed")
    error(e) ->
      said = e.kind == args[0] and e.message.include?(args[1])
      BDD.assert(
        BDD.assert(ctx, said, "gave #{e.kind}: #{e.message}"),
        left_nothing("#{folder_of(ctx)}/out"),
        "the build left files",
      )
  end
end

def left_nothing(path: String) -> Bool
  listed = Dir.list(path)
  !listed.ok? or listed.unwrap!.empty?
end

# The archive is unpacked in `again/`, changed, and packed again as `again.tar.gz` (`-P` keeps a `../` name).
def archive_changed(ctx: BDD.Context, args: List[String]) -> BDD.Context
  name = root_of(ctx).split("/").last
  changes = {
    "an extra file": "touch #{name}/extra.txt",
    "a link": "ln -s elsewhere #{name}/link",
    "a name outside": "touch ../outside.txt",
  }

  members = name
  if args[0] == "a name outside"
    members = "#{name} ../outside.txt"
  end

  script = (
    "cd #{folder_of(ctx)} && mkdir again && cd again && tar -xzf #{archive_of(ctx)} && #{changes[args[0]]} && tar -czPf ../again.tar.gz #{members}"
  )

  made = sh(["sh", "-c", script])
  BDD.assert(ctx, made.ok?, "cannot make the archive again: #{made}")
end

def new_archive_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case Release.inspect("#{folder_of(ctx)}/again.tar.gz")
    ok(_) -> BDD.assert(ctx, false, "inspect passed")
    error(e) ->
      BDD.assert(ctx, e.kind == args[0] and e.message.include?(args[1]), "inspect gave #{e.kind}: #{e.message}")
  end
end

# `cli.agc` run as a user runs it, in the fresh folder: the exit code, and for an error one line on stderr.
def commands(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  checked = ctx
  resolved = Path.resolve("cli.agc")
  return BDD.assert(ctx, false, resolved.message) if !resolved.ok?

  cli = resolved.unwrap!
  for row in BDD.table(ctx).drop(1)
    child = Process.spawn_captured(
      "agentica",
      [cli] + row[0].split(" "),
      Process.Options(chdir: folder_of(ctx), timeout_ms: RUN_MS),
    )

    return BDD.assert(checked, false, child.message) if !child.ok?

    process = child.unwrap!
    out = Process.output(process, RUN_MS)
    code = Process.wait(process, RUN_MS)
    Process.close(process)
    return BDD.assert(checked, false, "#{row[0]} gave #{out}") if !out.ok?

    shown = out.unwrap!.stdout + out.unwrap!.stderr
    lines = out.unwrap!.stderr.strip.split("\n").size
    clean = code == ok(row[1].to_i!) and shown.include?(row[2])
    if row[1] != "0"
      clean = clean and lines == 1
    end

    checked = BDD.assert(checked, clean, "#{row[0]} gave #{code} and #{shown}")
  end

  checked
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
        checked = BDD.assert(checked, left_nothing("#{folder_of(ctx)}/refused-#{index}"), "#{row[0]} left files")
    end
  end

  checked
end
