## One object: put, get, head and delete, from memory, from a file or as a stream.

import Failure from "failure"
import HTTP from "std/http"
import Request from "request"
import Types from "types"

## The headers of a request that stores an object: its content type and the `headers` of the options.
def put_headers(options: Types.PutOptions) -> List[Types.Param]
  return options.headers if options.content_type == ""

  [Types.Param(name: "content-type", value: options.content_type)] + options.headers
end

## What the headers of an answer say about the object. `x-amz-meta-*` headers are kept in `headers`.
def info_of(headers: List[HTTP.Header]) -> Types.ObjectInfo
  Types.ObjectInfo(
    etag: header(headers, "etag"),
    size: header(headers, "content-length").to_i.unwrap_or(-1),
    content_type: header(headers, "content-type"),
    last_modified: header(headers, "last-modified"),
    headers: headers.select { |h| h.name.start_with?("x-amz-meta-") }
      .map { |h| Types.Param(name: h.name, value: h.value) },
  )
end

## Stores `body` under `key`, replacing what is there. The `ObjectInfo` has the `etag` of the answer.
def put(
  client: Types.Client,
  key: String,
  body: Bytes,
  options: Types.PutOptions = Types.PutOptions(),
) -> Result[Types.ObjectInfo]
  try Failure.named(key)
  response = try Request.send(client, "PUT", key, [], put_headers(options), body)
  ok(stored(response.headers))
end

## Stores the file at `path` under `key` in one request, read and sent in pieces and not signed (`UNSIGNED-PAYLOAD`).
def put_file(
  client: Types.Client,
  key: String,
  path: String,
  options: Types.PutOptions = Types.PutOptions(),
) -> Result[Types.ObjectInfo]
  try Failure.named(key)
  stat = try File.stat(path)
  return Failure.invalid("#{path} is not a regular file") if stat.kind != "file"

  pieces: Channel[Bytes] = Channel.new(PIECES_QUEUED)
  feeder = Task.spawn do feed(path, pieces) end
  sent = Request.send_stream(client, "PUT", key, put_headers(options), pieces, stat.size_bytes)
  pieces.close
  fed = Task.await(feeder)
  response = try sent
  try fed
  ok(stored(response.headers))
end

## Reads the object whole, up to `max_body_bytes` of the client.
def get(client: Types.Client, key: String) -> Result[Types.Object]
  try Failure.named(key)
  response = try Request.send(client, "GET", key, [], [], "".bytes)
  ok(Types.Object(info: info_of(response.headers), body: response.body))
end

## Reads the bytes `first` to `last` (both included) of the object: `last` -1 reads to the end. S3 answers 416
## (`s3.invalid_range`) when `first` is at or past the end.
def get_range(client: Types.Client, key: String, first: Int, last: Int) -> Result[Types.Object]
  try Failure.named(key)
  return Failure.invalid("the range #{first}-#{last} is not valid") if first < 0 or (last >= 0 and last < first)

  response = try Request.send(client, "GET", key, [], [range_header(first, last)], "".bytes)
  ok(Types.Object(info: info_of(response.headers), body: response.body))
end

## Reads the object into the file at `path`: the pieces go to a hidden file beside it, which replaces `path` only
## after the whole body came. A failure removes it and leaves `path` as it was.
def get_file(client: Types.Client, key: String, path: String) -> Result[Types.ObjectInfo]
  try Failure.named(key)
  stream = try Request.open(client, key, [])
  hidden = "#{path}.#{OpenSSL.Random.hex(4)}.s3-part"
  written = copy(stream, hidden)
  case written
    ok(_) -> nil
    error(e) ->
      _ = Path.remove(hidden)
      return error(e)
  end

  try Path.replace(hidden, path)
  ok(info_of(stream.headers))
end

## Reads the object as it arrives: `body` of the stream has the pieces, and the head has been checked (a status of 300
## or more is an `error`). Read `body` to its closed error, then `Task.await(done)`: only `done` says the body was
## whole. Close `body` and `Task.cancel(done)` to stop early.
def open(client: Types.Client, key: String) -> Result[HTTP.Stream]
  try Failure.named(key)
  Request.open(client, key, [])
end

## What the object is, with no body: the `size`, `etag`, `content_type` and `last_modified` of the `ObjectInfo`. A
## missing key is an `error` of the kind `s3.no_such_key`.
def head(client: Types.Client, key: String) -> Result[Types.ObjectInfo]
  try Failure.named(key)
  response = try Request.send(client, "HEAD", key, [], [], "".bytes)
  ok(info_of(response.headers))
end

## Deletes `key`. S3 says success for a key that is not there.
def delete(client: Types.Client, key: String) -> Result[Void]
  try Failure.named(key)
  _ = try Request.send(client, "DELETE", key, [], [], "".bytes)
  ok()
end

private

FILE_PIECE_BYTES = 262_144
PIECES_QUEUED = 4
PIECE_MS = 300_000

# A `PUT` answers the etag and nothing else about the object.
def stored(headers: List[HTTP.Header]) -> Types.ObjectInfo = Types.ObjectInfo(etag: header(headers, "etag"))

def header(headers: List[HTTP.Header], name: String) -> String
  values = HTTP.header_values(headers, name)
  return "" if values.empty?

  values[0]
end

def range_header(first: Int, last: Int) -> Types.Param
  return Types.Param(name: "range", value: "bytes=#{first}-") if last < 0

  Types.Param(name: "range", value: "bytes=#{first}-#{last}")
end

# The task that reads the file, since a file belongs to the task that opened it; it ends the body by closing
# the channel.
def feed(path: String, pieces: Channel[Bytes]) -> Result[Void]
  File.open(path, "read", 30_000) do |file|
    while true
      chunk = try File.read_bytes(file, FILE_PIECE_BYTES, 30_000)
      break if chunk.empty?

      try pieces.send(chunk, PIECE_MS)
    end

    pieces.close
    ok()
  end
end

def copy(stream: HTTP.Stream, path: String) -> Result[Void]
  written: Result[Void] = File.open(path, "write", 30_000) do |file|
    while true
      case stream.body.recv(PIECE_MS)
        ok(piece) -> try File.write_bytes(file, piece, 30_000)
        error(e) ->
          break if e.is_a?("channel.closed")

          Task.cancel(stream.done)
          return error(e)
      end
    end

    ok()
  end

  try written
  Task.await(stream.done)
end
