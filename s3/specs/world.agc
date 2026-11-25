## What the steps share: the stub server of a scenario, the client of the scenario's settings, the files it works on,
## and the way a failure is told.

import BDD from "std/bdd"
import HTTP from "std/http"
import S3 from "../s3"

BUCKET = "photos"
ACCESS_KEY = "AKIDEXAMPLE"
SECRET_KEY = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
REGION = "us-east-1"

## Starts `fixtures/s3_stub.py` for the scenario and remembers its port. A process belongs to the task that opens it, so
## this runs in a step; the stub is closed (SIGTERM, which removes its files) when the scenario ends.
def start_stub(ctx: BDD.Context, session_token: String) -> BDD.Context
  args = ["-I", STUB, "--bucket", BUCKET, "--access-key", ACCESS_KEY, "--secret-key", SECRET_KEY]
  if session_token != ""
    args = args + ["--session-token", session_token]
  end

  stub = Process.spawn_captured("python3", args, Process.Options(timeout_ms: 600_000)).unwrap!
  port = Process.read_line(stub, 10_000).unwrap!.split(" ")[1]
  armed = BDD.after(ctx, ->(_final) { stop(stub) })
  set_text(set_text(armed, "port", port), "token", session_token)
end

def set_text(ctx: BDD.Context, name: String, value: String) -> BDD.Context = BDD.set(ctx, name, JSON.from(value))

def text(ctx: BDD.Context, name: String, fallback: String) -> String
  case BDD.get(ctx, name)
    ok(value) -> JSON.string(value).unwrap_or(fallback)
    error(_) -> fallback
  end
end

## The `Config` of the scenario: the stub's address and the credentials, with the settings that steps changed.
def config_of(ctx: BDD.Context) -> S3.Config
  addressing = S3.Addressing.Path
  if text(ctx, "addressing", "path") == "virtual"
    addressing = S3.Addressing.Virtual
  end

  S3.Config(
    endpoint: "http://127.0.0.1:#{text(ctx, "port", "0")}",
    region: REGION,
    access_key: text(ctx, "access_key", ACCESS_KEY),
    secret_key: text(ctx, "secret_key", SECRET_KEY),
    bucket: text(ctx, "bucket", BUCKET),
    session_token: text(ctx, "session_token", ""),
    addressing: addressing,
  )
end

def options_of(ctx: BDD.Context) -> S3.Options
  S3.Options(timeout_ms: 20_000, transfer_timeout_ms: 60_000, connect_to: text(ctx, "connect_to", ""))
end

def client_of(ctx: BDD.Context) -> S3.Client = S3.client(config_of(ctx), options_of(ctx)).unwrap!

## A fresh folder for the files of the scenario, removed when it ends.
def folder(ctx: BDD.Context) -> BDD.Context
  return ctx if text(ctx, "dir", "") != ""

  dir = Path.join([System.env("TMPDIR").unwrap_or("/tmp"), "s3-spec-#{OpenSSL.Random.hex(6)}"]).unwrap!
  Dir.mkdir(dir).unwrap!
  BDD.after(set_text(ctx, "dir", dir), ->(_final) { Path.remove(dir) })
end

def file_path(ctx: BDD.Context, name: String) -> String = Path.join([text(ctx, "dir", ""), name]).unwrap!

## Writes `count` bytes to the file: one random block of 1 MiB (or less), repeated.
def write_random(path: String, count: Int) -> Void
  block = OpenSSL.Random.random_bytes(smaller(count, 1_048_576))
  written: Result[Void] = File.open(path, "write", 30_000) do |file|
    left = count
    while left > 0
      piece = block.take(left)
      try File.write_bytes(file, piece, 30_000)
      left = left - piece.size
    end

    ok()
  end

  written.unwrap!
end

## Writes the pieces of a channel to a file until the channel closes.
def drain_to_file(pieces: Channel[Bytes], path: String) -> Void
  written: Result[Void] = File.open(path, "write", 30_000) do |file|
    while true
      case pieces.recv(20_000)
        ok(piece) -> try File.write_bytes(file, piece, 30_000)
        error(_) -> break
      end
    end

    ok()
  end

  written.unwrap!
end

## The whole file, read in pieces.
def read_all(path: String) -> Bytes
  read: Result[Bytes] = File.open(path, "read", 30_000) do |file|
    pieces: List[Bytes] = []
    while true
      piece = try File.read_bytes(file, 1_048_576, 30_000)
      break if piece.empty?

      pieces = pieces.push(piece)
    end

    ok(Bytes.concat(pieces))
  end

  read.unwrap!
end

def same_bytes?(a: String, b: String) -> Bool = File.sha256(a).unwrap! == File.sha256(b).unwrap!

## The kind and status of the failure of a result, as `kind status`, or `none` when it succeeded.
def failure_of[T](result: Result[T]) -> String
  case result
    ok(_) -> "none"
    error(e) -> "#{e.kind} #{e.code.unwrap_or(0)}"
  end
end

def fails_with[T](ctx: BDD.Context, result: Result[T], kind: String, status: Int) -> BDD.Context
  BDD.assert(ctx, failure_of(result) == "#{kind} #{status}", "failed as #{failure_of(result)}")
end

## Asks a URL with no credentials: the status and the body of the answer.
def fetch(method: String, url: String, body: Bytes) -> HTTP.Response
  client = HTTP.client(HTTP.ClientOptions(timeout_ms: 20_000, max_body_bytes: 16_777_216)).unwrap!
  response = HTTP.request(client, method, url, body, []).unwrap!
  HTTP.close_client(client)
  response
end

private

STUB = "specs/fixtures/s3_stub.py"

def stop(stub: Process) -> Result[Void]
  Process.close(stub)
  ok()
end

def smaller(a: Int, b: Int) -> Int
  return a if a < b

  b
end
