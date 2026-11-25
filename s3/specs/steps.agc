## The steps of the features: a scenario starts the stub server of `fixtures/s3_stub.py` (an independent S3 that checks
## every signature), and the steps call the package as a program would.

import BDD from "std/bdd"
import HTTP from "std/http"
import S3 from "../s3"
import Signing from "signing"
import World from "world"

def main() -> Void
  BDD.run([
    BDD.step("an S3 server", &server),
    BDD.step("an S3 server that needs the session token {string}", &server_with_token),
    BDD.step("the client uses the secret key {string}", &uses_secret),
    BDD.step("the client uses the access key {string}", &uses_access),
    BDD.step("the client uses the bucket {string}", &uses_bucket),
    BDD.step("the client uses the session token {string}", &uses_token),
    BDD.step("the client addresses the bucket as a virtual host", &uses_virtual_host),
    BDD.step("I put {string} with the text {string}", &put_text),
    BDD.step("I put {string} with the text {string} as {string}", &put_text_typed),
    BDD.step("the object {string} reads as {string}", &reads_as),
    BDD.step("the object {string} is {int} bytes of {string}", &is_bytes_of),
    BDD.step("the range {int} to {int} of {string} reads as {string}", &range_reads_as),
    BDD.step("the range {int} to the end of {string} reads as {string}", &tail_reads_as),
    BDD.step("I delete {string}", &delete),
    BDD.step("the object {string} is missing", &is_missing),
    BDD.step("reading {string} fails with {string} and status {int}", &reading_fails),
    BDD.step("putting {string} fails with {string} and status {int}", &putting_fails),
    BDD.step("a file {string} of {int} bytes", &file_of),
    BDD.step("I put the file {string} as {string}", &put_file),
    BDD.step("I get {string} into the file {string}", &get_file),
    BDD.step("I stream {string} into the file {string}", &stream_file),
    BDD.step("the files {string} and {string} have the same bytes", &same_files),
    BDD.step("the object {string} has the bytes of the file {string}", &object_has_file),
    BDD.step("fetching a presigned URL for {string} gives {string} and the disposition {string}", &presigned_get),
    BDD.step("curl puts the file {string} to a presigned URL for {string}", &curl_puts),
    BDD.step(
      "a presigned URL for {string} made {int} seconds ago for {int} seconds answers {int} with {string}",
      &stale_url,
    ),
    BDD.step("a presigned URL for {string} that is changed to {string} answers {int} with {string}", &changed_url),
    BDD.step("I start a multipart upload of {string}", &start_upload),
    BDD.step("I upload part {int} from the file {string}", &upload_part),
    BDD.step("I upload part {int} through a presigned URL from the file {string}", &upload_part_presigned),
    BDD.step("the parts of the upload are {string}", &parts_are),
    BDD.step("I complete the upload of {string}", &complete_upload),
    BDD.step("completing the upload of {string} fails with {string} and status {int}", &completing_fails),
    BDD.step("I abort the upload of {string}", &abort_upload),
    BDD.step("the parts of the upload of {string} fail with {string} and status {int}", &listing_fails),
    BDD.step("I upload the file {string} as {string} in parts of {int} bytes", &upload_file),
    BDD.step("the etag of {string} ends with {string}", &etag_ends),
    BDD.step("the peer signs {int} random requests from the seed {int}", &Signing.write_cases),
    BDD.step("the package signs every one as the peer does", &Signing.agree),
  ])
end

private

def server(ctx: BDD.Context, _args: List[String]) -> BDD.Context = World.folder(World.start_stub(ctx, ""))

def server_with_token(ctx: BDD.Context, args: List[String]) -> BDD.Context
  World.folder(World.start_stub(World.set_text(ctx, "session_token", args[0]), args[0]))
end

def uses_secret(ctx: BDD.Context, args: List[String]) -> BDD.Context = World.set_text(ctx, "secret_key", args[0])

def uses_access(ctx: BDD.Context, args: List[String]) -> BDD.Context = World.set_text(ctx, "access_key", args[0])

def uses_bucket(ctx: BDD.Context, args: List[String]) -> BDD.Context = World.set_text(ctx, "bucket", args[0])

def uses_token(ctx: BDD.Context, args: List[String]) -> BDD.Context = World.set_text(ctx, "session_token", args[0])

# Every request goes to the stub's port, while the URL names `photos.127.0.0.1`, as AWS's would name the bucket.
def uses_virtual_host(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  World.set_text(World.set_text(ctx, "addressing", "virtual"), "connect_to", "127.0.0.1")
end

def put_text(ctx: BDD.Context, args: List[String]) -> BDD.Context = put_typed(ctx, args[0], args[1], "")

def put_text_typed(ctx: BDD.Context, args: List[String]) -> BDD.Context = put_typed(ctx, args[0], args[1], args[2])

def put_typed(ctx: BDD.Context, key: String, text: String, content_type: String) -> BDD.Context
  client = World.client_of(ctx)
  stored = S3.put(client, key, text.bytes, S3.PutOptions(content_type: content_type))
  S3.close(client)
  BDD.assert(ctx, stored.ok?, "put failed as #{World.failure_of(stored)}")
end

def read_object(ctx: BDD.Context, key: String) -> Result[S3.Object]
  client = World.client_of(ctx)
  object = S3.get(client, key)
  S3.close(client)
  object
end

def reads_as(ctx: BDD.Context, args: List[String]) -> BDD.Context
  object = read_object(ctx, args[0])
  BDD.assert(ctx, object.ok?, "get failed as #{World.failure_of(object)}")
  BDD.assert(ctx, String.from_bytes(object.unwrap!.body).unwrap_or("") == args[1], "the object is not #{args[1]}")
end

def is_bytes_of(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  info = S3.head(client, args[0])
  S3.close(client)
  BDD.assert(ctx, info.ok?, "head failed as #{World.failure_of(info)}")
  seen = "#{info.unwrap!.size} #{info.unwrap!.content_type}"
  BDD.assert(ctx, seen == "#{args[1]} #{args[2]}", "the object is #{seen}")
end

def range_reads_as(ctx: BDD.Context, args: List[String]) -> BDD.Context
  ranged(ctx, args[2], args[0].to_i!, args[1].to_i!, args[3])
end

def tail_reads_as(ctx: BDD.Context, args: List[String]) -> BDD.Context
  ranged(ctx, args[1], args[0].to_i!, -1, args[2])
end

def ranged(ctx: BDD.Context, key: String, first: Int, last: Int, expected: String) -> BDD.Context
  client = World.client_of(ctx)
  object = S3.get_range(client, key, first, last)
  S3.close(client)
  BDD.assert(ctx, object.ok?, "get_range failed as #{World.failure_of(object)}")
  BDD.assert(ctx, String.from_bytes(object.unwrap!.body).unwrap_or("") == expected, "the range is not #{expected}")
end

def delete(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  deleted = S3.delete(client, args[0])
  S3.close(client)
  BDD.assert(ctx, deleted.ok?, "delete failed as #{World.failure_of(deleted)}")
end

# Both ways of asking for a key that is not there: a `GET` with the error body, and a `HEAD` with none.
def is_missing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  got = World.failure_of(S3.get(client, args[0]))
  described = World.failure_of(S3.head(client, args[0]))
  S3.close(client)
  BDD.assert(ctx, got == "#{S3.NO_SUCH_KEY} 404" and described == got, "get: #{got}, head: #{described}")
end

def reading_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  World.fails_with(ctx, read_object(ctx, args[0]), args[1], args[2].to_i!)
end

def putting_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  stored = S3.put(client, args[0], "x".bytes)
  S3.close(client)
  World.fails_with(ctx, stored, args[1], args[2].to_i!)
end

def file_of(ctx: BDD.Context, args: List[String]) -> BDD.Context
  World.write_random(World.file_path(ctx, args[0]), args[1].to_i!)
  ctx
end

def put_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  stored = S3.put_file(client, args[1], World.file_path(ctx, args[0]))
  S3.close(client)
  BDD.assert(ctx, stored.ok?, "put_file failed as #{World.failure_of(stored)}")
end

def get_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  info = S3.get_file(client, args[0], World.file_path(ctx, args[1]))
  S3.close(client)
  BDD.assert(ctx, info.ok?, "get_file failed as #{World.failure_of(info)}")
end

def stream_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  stream = S3.open(client, args[0]).unwrap!
  path = World.file_path(ctx, args[1])
  World.drain_to_file(stream.body, path)
  done = Task.await(stream.done)
  S3.close(client)
  BDD.assert(ctx, done.ok?, "the stream ended as #{World.failure_of(done)}")
end

def same_files(ctx: BDD.Context, args: List[String]) -> BDD.Context
  same = World.same_bytes?(World.file_path(ctx, args[0]), World.file_path(ctx, args[1]))
  BDD.assert(ctx, same, "#{args[0]} and #{args[1]} differ")
end

def object_has_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  copy = "copy-#{OpenSSL.Random.hex(4)}"
  got = get_file(ctx, [args[0], copy])
  same_files(got, [copy, args[1]])
end

def presigned_url(ctx: BDD.Context, key: String, options: S3.Presign) -> String
  S3.presign_get(World.config_of(ctx), key, options).unwrap!
end

def presigned_get(ctx: BDD.Context, args: List[String]) -> BDD.Context
  query = [S3.Param(name: "response-content-disposition", value: args[2])]
  url = presigned_url(ctx, args[0], S3.Presign(query: query))
  response = World.fetch("GET", url, "".bytes)
  disposition = HTTP.header_values(response.headers, "content-disposition")
  seen = "#{response.status} #{String.from_bytes(response.body).unwrap_or("")} #{disposition.join(",")}"
  BDD.assert(ctx, seen == "200 #{args[1]} #{args[2]}", "the fetch gave #{seen}")
end

def curl_puts(ctx: BDD.Context, args: List[String]) -> BDD.Context
  url = S3.presign_put(World.config_of(ctx), args[1]).unwrap!
  curl = Process.spawn_captured("curl", ["-sS", "--fail-with-body", "-T", World.file_path(ctx, args[0]), url]).unwrap!
  code = Process.wait(curl, 60_000).unwrap!
  BDD.assert(ctx, code == 0, "curl exited with #{code}: #{Process.output(curl, 5_000).unwrap!.stderr}")
end

def refused_url(ctx: BDD.Context, url: String, status: Int, code: String) -> BDD.Context
  response = World.fetch("GET", url, "".bytes)
  body = String.from_bytes(response.body).unwrap_or("")
  BDD.assert(
    ctx,
    response.status == status and body.include?("<Code>#{code}</Code>"),
    "answered #{response.status} #{body}",
  )
end

def stale_url(ctx: BDD.Context, args: List[String]) -> BDD.Context
  at = Time.now().to_i - args[1].to_i!
  url = presigned_url(ctx, args[0], S3.Presign(expires_s: args[2].to_i!, at: some(at)))
  refused_url(ctx, url, args[3].to_i!, args[4])
end

def changed_url(ctx: BDD.Context, args: List[String]) -> BDD.Context
  url = presigned_url(ctx, args[0], S3.Presign())
  refused_url(ctx, url.replace("/#{World.BUCKET}/#{args[0]}?", "/#{World.BUCKET}/#{args[1]}?"), args[2].to_i!, args[3])
end

def start_upload(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  id = S3.create_multipart(client, args[0])
  S3.close(client)
  BDD.assert(ctx, id.ok?, "create failed as #{World.failure_of(id)}")
  parts: List[S3.Part] = []
  started = World.set_text(World.set_text(ctx, "upload", id.unwrap!), "upload_key", args[0])
  BDD.set(started, "parts", JSON.from(parts))
end

def key_of(ctx: BDD.Context) -> String = World.text(ctx, "upload_key", "")

def upload_id(ctx: BDD.Context) -> String = World.text(ctx, "upload", "")

def kept_parts(ctx: BDD.Context) -> List[S3.Part] = JSON.decode(BDD.get(ctx, "parts").unwrap!, List[S3.Part]).unwrap!

def keep_part(ctx: BDD.Context, part: Result[S3.Part]) -> BDD.Context
  asserted = BDD.assert(ctx, part.ok?, "the part failed as #{World.failure_of(part)}")
  BDD.set(asserted, "parts", JSON.from(kept_parts(ctx).push(part.unwrap!)))
end

def upload_part(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  body = World.read_all(World.file_path(ctx, args[1]))
  part = S3.upload_part(client, key_of(ctx), upload_id(ctx), args[0].to_i!, body)
  S3.close(client)
  keep_part(ctx, part)
end

# What a browser does: the server makes the URL, the browser puts the bytes and reads the ETag of the answer.
def upload_part_presigned(ctx: BDD.Context, args: List[String]) -> BDD.Context
  number = args[0].to_i!
  url = S3.presign_part(World.config_of(ctx), key_of(ctx), upload_id(ctx), number).unwrap!
  response = World.fetch("PUT", url, World.read_all(World.file_path(ctx, args[1])))
  etag = HTTP.header_values(response.headers, "etag")
  ok_part = response.status == 200 and not etag.empty?
  asserted = BDD.assert(ctx, ok_part, "the part answered #{response.status}")
  BDD.set(asserted, "parts", JSON.from(kept_parts(ctx).push(S3.Part(number: number, etag: etag[0]))))
end

def parts_are(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  listed = S3.list_parts(client, key_of(ctx), upload_id(ctx))
  S3.close(client)
  BDD.assert(ctx, listed.ok?, "list_parts failed as #{World.failure_of(listed)}")
  seen = listed.unwrap!.map { |p| "#{p.number}:#{p.size}" }.join(",")
  BDD.assert(ctx, seen == args[0], "the parts are #{seen}")
end

def complete_upload(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  done = S3.complete_multipart(client, args[0], upload_id(ctx), kept_parts(ctx))
  S3.close(client)
  BDD.assert(ctx, done.ok?, "complete failed as #{World.failure_of(done)}")
end

def completing_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  done = S3.complete_multipart(client, args[0], upload_id(ctx), kept_parts(ctx))
  S3.close(client)
  World.fails_with(ctx, done, args[1], args[2].to_i!)
end

def abort_upload(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  aborted = S3.abort_multipart(client, args[0], upload_id(ctx))
  S3.close(client)
  BDD.assert(ctx, aborted.ok?, "abort failed as #{World.failure_of(aborted)}")
end

def listing_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  listed = S3.list_parts(client, args[0], upload_id(ctx))
  S3.close(client)
  World.fails_with(ctx, listed, args[1], args[2].to_i!)
end

def upload_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  options = S3.UploadOptions(part_size: args[2].to_i!)
  info = S3.upload_file(client, args[1], World.file_path(ctx, args[0]), options)
  S3.close(client)
  BDD.assert(ctx, info.ok?, "upload_file failed as #{World.failure_of(info)}")
  World.set_text(ctx, "etag", info.unwrap!.etag)
end

def etag_ends(ctx: BDD.Context, args: List[String]) -> BDD.Context
  client = World.client_of(ctx)
  info = S3.head(client, args[0])
  S3.close(client)
  BDD.assert(ctx, info.ok?, "head failed as #{World.failure_of(info)}")
  BDD.assert(ctx, info.unwrap!.etag.end_with?(args[1]), "the etag is #{info.unwrap!.etag}")
end
