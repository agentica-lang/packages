## The files of a release folder.

import Errors from "errors"
import Layout from "layout"

## The path of every regular file below `root`, relative to it, in name order. A link or another kind of file is an
## error, since a release holds plain files.
def walk(root: String) -> Result[List[String]] = below(root, "")

## The entries of `paths` with the sha256 of each file, as hex.
def hashed(root: String, paths: List[String]) -> Result[List[Layout.Entry]]
  entries: List[Layout.Entry] = []
  for path in paths
    digest = try File.sha256(Layout.at(root, path))
    entries = entries.push(Layout.Entry(path: path, sha256: OpenSSL.Digest.hexencode(digest)))
  end

  ok(entries)
end

## `path` of the project is there, is not a link, and is really below the project once the links of its folders are
## followed. `project` is the real path of the project.
def confined(project: String, path: String) -> Result[Void]
  from = Layout.at(project, path)
  info = File.lstat(from)
  return Errors.invalid("#{path.inspect} is not in the project") if !info.ok?
  return Errors.invalid("#{path.inspect} is a link, and a release holds no links") if info.unwrap!.kind == "link"

  real = Path.real(from)
  return Errors.invalid("#{path.inspect} is not in the project: #{real.message}") if !real.ok?
  if !real.unwrap!.start_with?("#{project}/")
    return Errors.invalid("#{path.inspect} leaves the project through a link")
  end

  ok()
end

## `path` of the project is a regular file.
def program(project: String, path: String) -> Result[Void]
  try confined(project, path)
  kind = (try File.lstat(Layout.at(project, path))).kind
  return Errors.invalid("#{path.inspect} is a #{kind}, not a file") if kind != "file"

  ok()
end

private

def below(root: String, rel: String) -> Result[List[String]]
  names = try Dir.list(Layout.at(root, rel))
  found: List[String] = []
  for name in names.sort
    path = name
    if !rel.empty?
      path = "#{rel}/#{name}"
    end

    info = try File.lstat(Layout.at(root, path))
    if info.kind == "directory"
      found = found + try below(root, path)
    elsif info.kind == "file"
      found = found.push(path)
    else
      return Errors.invalid("#{path} is a #{info.kind}, not a plain file or folder")
    end
  end

  ok(found)
end
