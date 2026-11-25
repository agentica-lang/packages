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
