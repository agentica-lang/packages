## `inspect` and `tar`: a release folder is checked against its manifest, and packed.

import Errors from "errors"
import Files from "files"
import Layout from "layout"
import Names from "names"
import Shell from "shell"

## The manifest of a release folder or of a `.tar.gz` of one, after every file has been checked: each file the manifest
## lists is there with its sha256, and no other file is. It finds a release that is damaged, not one that is changed on
## purpose: whoever changes a file can change the manifest too, so the hash of the archive itself belongs somewhere
## else.
def inspect(path: String) -> Result[Layout.Manifest]
  source = try Path.resolve(path)
  return folder_checked(source) if !source.end_with?(".tar.gz")

  scratch = (try Shell.run("mktemp", ["-d"], ".")).strip
  checked = unpacked(source, scratch)
  _ = Path.remove(scratch)
  checked
end

## The `NAME-VERSION-OS-ARCH.tar.gz` of a release folder, written beside it. The folder is checked first, and an
## archive that exists is not replaced.
def tar(path: String) -> Result[String]
  root = try Path.resolve(path)
  manifest = try folder_checked(root)
  parts = root.split("/")
  parent = parts.take(parts.size - 1).join("/")
  archive = Layout.at(parent, Layout.archive(manifest))
  return Errors.invalid("#{archive} exists already; remove it first") if File.lstat(archive).ok?

  # COPYFILE_DISABLE keeps the `._` files of macOS tar out of the archive, which `inspect` would find extra.
  packed = Shell.run("tar", ["-czf", archive, "-C", parent, parts.last], ".", {"COPYFILE_DISABLE": "1"})
  if !packed.ok?
    _ = Path.remove(archive)
    return error(packed.message, kind: "release.failed")
  end

  ok(archive)
end

private

# The system `tar`, which reads what `std/archive` reads but also writes, so that one program makes and opens the
# archive. The names and kinds are checked before anything is unpacked: a name that leaves the folder, a link or a
# device is not a release.
def unpacked(archive: String, scratch: String) -> Result[Layout.Manifest]
  names = (try Shell.run("tar", ["-tzf", archive], ".")).split("\n")
  for name in names
    unsafe = name.start_with?("/") or name.split("/").any? { |part| part == ".." }
    return Errors.corrupt("#{archive} holds the name #{name.inspect}, which leaves the folder") if unsafe
  end

  kinds = (try Shell.run("tar", ["-tvzf", archive], ".")).split("\n")
  for line in kinds
    if !line.empty? and !line.start_with?("-") and !line.start_with?("d")
      return Errors.corrupt("#{archive} holds a link or a special file: #{line.inspect}")
    end
  end

  _ = try Shell.run("tar", ["-xzf", archive, "--no-same-owner", "--no-same-permissions", "-C", scratch], ".")
  folders = try Dir.list(scratch)
  return Errors.corrupt("#{archive} must hold one folder, not #{folders.size} entries") if folders.size != 1

  folder_checked(Layout.at(scratch, folders[0]))
end

def folder_checked(root: String) -> Result[Layout.Manifest]
  text = File.read_text(Layout.at(root, Layout.MANIFEST))
  return Errors.corrupt("#{root} has no #{Layout.MANIFEST}: #{text.message}") if !text.ok?

  manifest = JSON.decode(text.unwrap!, Layout.Manifest)
  return Errors.corrupt("#{Layout.MANIFEST} is not a manifest: #{manifest.message}") if !manifest.ok?

  listed = manifest.unwrap!
  try named(listed)
  walked = Files.walk(root)
  return Errors.corrupt("#{root} is not a release: #{walked.message}") if !walked.ok?

  names = Set.new(listed.files.map { |entry| entry.path })
  found = walked.unwrap!.select { |path| path != Layout.MANIFEST }
  present = Set.new(found)
  for path in found
    return Errors.corrupt("#{path} is not in the manifest") if !names.include?(path)
  end

  for entry in listed.files
    return Errors.corrupt("#{entry.path} must be a path inside the release") if odd_path?(entry.path)
    return Errors.corrupt("#{entry.path} is missing") if !present.include?(entry.path)

    digest = OpenSSL.Digest.hexencode(try File.sha256(Layout.at(root, entry.path)))
    return Errors.corrupt("#{entry.path} has another sha256 than the manifest") if digest != entry.sha256
  end

  for path in [Layout.launcher_path(listed.name), Layout.binary_path(), Layout.program_path(listed.name)]
    return Errors.corrupt("#{path} is not in the manifest") if !names.include?(path)
  end

  for path in [Layout.launcher_path(listed.name), Layout.binary_path()]
    mode = (try File.lstat(Layout.at(root, path))).mode
    return Errors.corrupt("#{path} is not executable") if mode.bit_and(64) == 0
  end

  ok(listed)
end

# The name, the version, the system and the architecture make the name of the archive and the paths of the files.
def named(manifest: Layout.Manifest) -> Result[Void]
  for pair in [["name", manifest.name], ["version", manifest.version], ["os", manifest.os], ["arch", manifest.arch]]
    checked = Names.word(pair[0], pair[1], "the manifest is damaged")
    return Errors.corrupt("#{Layout.MANIFEST}: #{checked.message}") if !checked.ok?
  end

  ok()
end

def odd_path?(path: String) -> Bool = !Names.inside("path", path).ok?
