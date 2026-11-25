## Multipart uploads: the calls of S3 one by one, and `upload_file`, which makes them for a file.

import Failure from "failure"
import Objects from "objects"
import Request from "request"
import Types from "types"
import Xml from "xml"

## Starts an upload and gives its id. The `options` are those of the object that `complete` will make.
def create(client: Types.Client, key: String, options: Types.PutOptions = Types.PutOptions()) -> Result[String]
  try Failure.named(key)
  response = try Request.send(client, "POST", key, [uploads()], Objects.put_headers(options), "".bytes)
  case Xml.text(text_of(response.body), "UploadId")
    some(id) -> ok(id)
    none -> error("s3: no UploadId in the answer", kind: Types.PROTOCOL)
  end
end

## Uploads part `number` (1 to 10,000) of the upload. Every part but the last must be 5 MiB or more (S3 answers
## `s3.entity_too_small` when the upload completes). The `Part` has the `etag` that `complete` needs.
def upload_part(client: Types.Client, key: String, upload_id: String, number: Int, body: Bytes) -> Result[Types.Part]
  try checked(key, upload_id, number)
  query = [Types.Param(name: "partNumber", value: "#{number}"), Types.Param(name: "uploadId", value: upload_id)]
  response = try Request.send(client, "PUT", key, query, [], body)
  etag = Objects.info_of(response.headers).etag
  return error("s3: no ETag in the answer", kind: Types.PROTOCOL) if etag == ""

  ok(Types.Part(number: number, etag: etag, size: body.size))
end

## Finishes the upload with `parts`, in ascending order of number, and gives the `etag` of the object. S3 may answer
## 200 with an error in the body, which is an `error` here as any other.
def complete(client: Types.Client, key: String, upload_id: String, parts: List[Types.Part]) -> Result[Types.ObjectInfo]
  try checked(key, upload_id, 1)
  try ascending(parts)
  response = try Request.send(client, "POST", key, [upload_query(upload_id)], [], completion(parts).bytes)
  xml = text_of(response.body)
  return Failure.refused(response.status, response.body) if xml.include?("<Error>")

  etag = Xml.text(xml, "ETag").unwrap_or("")
  ok(Types.ObjectInfo(etag: etag))
end

## Drops the upload and its parts. An upload that is gone is an `error` of the kind `s3.no_such_upload`.
def abort(client: Types.Client, key: String, upload_id: String) -> Result[Void]
  try checked(key, upload_id, 1)
  _ = try Request.send(client, "DELETE", key, [upload_query(upload_id)], [], "".bytes)
  ok()
end

## The parts uploaded so far, in ascending order (every page of the answer).
def list_parts(client: Types.Client, key: String, upload_id: String) -> Result[List[Types.Part]]
  try checked(key, upload_id, 1)
  parts: List[Types.Part] = []
  marker = 0
  for _page in 1..MAX_PAGES
    query = [
      upload_query(upload_id),
      Types.Param(name: "part-number-marker", value: "#{marker}"),
      Types.Param(name: "max-parts", value: "#{PAGE_PARTS}"),
    ]

    response = try Request.send(client, "GET", key, query, [], "".bytes)
    xml = text_of(response.body)
    parts = parts + Xml.elements(xml, "Part").map { |part| part_of(part) }
    return ok(parts) if Xml.text(xml, "IsTruncated").unwrap_or("false") != "true"

    marker = Xml.text(xml, "NextPartNumberMarker").unwrap_or("0").to_i.unwrap_or(0)
  end

  ok(parts)
end

## Stores the file at `path` under `key`: one request when it fits `part_size`, else a multipart upload of its parts
## one after the other, aborted when a part fails. The `ObjectInfo` has the `etag`.
def upload_file(
  client: Types.Client,
  key: String,
  path: String,
  options: Types.UploadOptions = Types.UploadOptions(),
) -> Result[Types.ObjectInfo]
  if options.part_size < Types.MIN_PART_BYTES or options.part_size > Types.MAX_PART_BYTES
    return Failure.invalid("part_size must be from #{Types.MIN_PART_BYTES} to #{Types.MAX_PART_BYTES}")
  end

  stat = try File.stat(path)
  return Failure.invalid("#{path} is not a regular file") if stat.kind != "file"

  put = Types.PutOptions(content_type: options.content_type, headers: options.headers)
  return Objects.put_file(client, key, path, put) if stat.size_bytes <= options.part_size

  id = try create(client, key, put)
  size = part_size_for(stat.size_bytes, options.part_size)
  parts = send_parts(client, key, id, path, stat.size_bytes, size)
  case parts
    ok(done) ->
      finished = complete(client, key, id, done)
      return finished if finished.ok?

      _ = abort(client, key, id)
      finished
    error(e) ->
      _ = abort(client, key, id)
      error(e)
  end
end

private

MAX_PAGES = 10
PAGE_PARTS = 1000
READ_BYTES = 1_048_576

def smaller(a: Int, b: Int) -> Int
  return a if a < b

  b
end

def uploads() -> Types.Param = Types.Param(name: "uploads", value: "")

def upload_query(upload_id: String) -> Types.Param = Types.Param(name: "uploadId", value: upload_id)

def text_of(body: Bytes) -> String = String.from_bytes(body).unwrap_or("")

def checked(key: String, upload_id: String, number: Int) -> Result[Void]
  try Failure.named(key)
  return Failure.invalid("the upload id is empty") if upload_id == ""
  return Failure.invalid("a part number is from 1 to #{Types.MAX_PARTS}") if number < 1 or number > Types.MAX_PARTS

  ok()
end

def ascending(parts: List[Types.Part]) -> Result[Void]
  return Failure.invalid("an upload needs at least one part") if parts.empty?

  previous = 0
  for part in parts
    return Failure.invalid("the parts must be in ascending order of number") if part.number <= previous

    previous = part.number
  end

  ok()
end

def completion(parts: List[Types.Part]) -> String
  items = parts.map { |p| "<Part><PartNumber>#{p.number}</PartNumber><ETag>#{Xml.escape(p.etag)}</ETag></Part>" }
  "<CompleteMultipartUpload>#{items.join("")}</CompleteMultipartUpload>"
end

def part_of(xml: String) -> Types.Part
  Types.Part(
    number: Xml.text(xml, "PartNumber").unwrap_or("0").to_i.unwrap_or(0),
    etag: Xml.text(xml, "ETag").unwrap_or(""),
    size: Xml.text(xml, "Size").unwrap_or("-1").to_i.unwrap_or(-1),
  )
end

# Whole parts of `wanted` bytes or more, so that the file never needs more than 10,000 of them.
def part_size_for(total: Int, wanted: Int) -> Int
  needed = (total + Types.MAX_PARTS - 1) / Types.MAX_PARTS
  return wanted if wanted >= needed

  needed
end

def send_parts(
  client: Types.Client,
  key: String,
  id: String,
  path: String,
  total: Int,
  size: Int,
) -> Result[List[Types.Part]]
  parts: List[Types.Part] = []
  offset = 0
  number = 1
  while offset < total
    body = try read_part(path, offset, smaller(size, total - offset))
    parts = parts.push(try upload_part(client, key, id, number, body))
    offset = offset + body.size
    number = number + 1
  end

  ok(parts)
end

def read_part(path: String, offset: Int, count: Int) -> Result[Bytes]
  File.open(path, "read", 30_000) do |file|
    try File.seek(file, offset)
    pieces: List[Bytes] = []
    left = count
    while left > 0
      piece = try File.read_bytes(file, smaller(READ_BYTES, left), 30_000)
      return error("s3: #{path} ended before the part did", kind: Types.INVALID) if piece.empty?

      pieces = pieces.push(piece)
      left = left - piece.size
    end

    ok(Bytes.concat(pieces))
  end
end
