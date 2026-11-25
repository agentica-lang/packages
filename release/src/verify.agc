## `inspect` and `tar`: a release folder is checked against its manifest, and packed.

import Errors from "errors"
import Files from "files"
import Layout from "layout"
import Shell from "shell"

## The manifest of a release folder or of a `.tar.gz` of one, after every file has been checked: each file the manifest
## lists is there with its sha256, and no other file is.
def inspect(path: String) -> Result[Layout.Manifest]
  source = try Path.resolve(path)
  return folder_checked(source) if !source.end_with?(".tar.gz")

  scratch = (try Shell.run("mktemp", ["-d"], ".")).strip
  checked = unpacked(source, scratch)
  _ = Shell.run("rm", ["-rf", scratch], ".")
  checked
end

## The `NAME-VERSION-OS-ARCH.tar.gz` of a release folder, written beside it. The folder is checked first.
def tar(path: String) -> Result[String]
  root = try Path.resolve(path)
  manifest = try folder_checked(root)
  parts = root.split("/")
  parent = parts.take(parts.size - 1).join("/")
  archive = Layout.at(parent, Layout.archive(manifest))
  _ = try Shell.run("tar", ["-czf", archive, "-C", parent, parts.last], ".")
  ok(archive)
end

private

def unpacked(archive: String, scratch: String) -> Result[Layout.Manifest]
  _ = try Shell.run("tar", ["-xzf", archive, "-C", scratch], ".")
  names = try Dir.list(scratch)
  return Errors.corrupt("#{archive} must hold one folder, not #{names.size} entries") if names.size != 1

  folder_checked(Layout.at(scratch, names[0]))
end

def folder_checked(root: String) -> Result[Layout.Manifest]
  text = File.read_text(Layout.at(root, Layout.MANIFEST))
  return Errors.corrupt("#{root} has no #{Layout.MANIFEST}: #{text.message}") if !text.ok?

  manifest = JSON.decode(text.unwrap!, Layout.Manifest)
  return Errors.corrupt("#{Layout.MANIFEST} is not a manifest: #{manifest.message}") if !manifest.ok?

  listed = manifest.unwrap!
  names = listed.files.map { |entry| entry.path }
  present = (try Files.walk(root)).select { |path| path != Layout.MANIFEST }
  for path in present
    return Errors.corrupt("#{path} is not in the manifest") if !names.include?(path)
  end

  for entry in listed.files
    return Errors.corrupt("#{entry.path} is missing") if !present.include?(entry.path)

    digest = OpenSSL.Digest.hexencode(try File.sha256(Layout.at(root, entry.path)))
    return Errors.corrupt("#{entry.path} has another sha256 than the manifest") if digest != entry.sha256
  end

  ok(listed)
end
