## The differential check of the signing: the cases that `fixtures/sigv4_peer.py` writes (one JSON object a line), and
## the package's answer to each.

import BDD from "std/bdd"
import Presigned from "../src/presigned"
import Request from "../src/request"
import Types from "../src/types"

struct Setup
  endpoint: String
  region: String
  access_key: String
  secret_key: String
  bucket: String
  addressing: String
  session_token: String
end

struct Case
  config: Setup
  method: String
  key: String
  query: List[List[String]]
  at: Int
  kind: String
  headers: List[List[String]]
  url: String
  payload: String = ""
  expires: Int = 0
  authorization: String = ""
end

## Runs the peer and keeps its lines for the scenario.
def write_cases(ctx: BDD.Context, args: List[String]) -> BDD.Context
  peer = Process.spawn_captured("python3", ["-I", PEER, args[1], args[0]], Process.Options(timeout_ms: 60_000)).unwrap!
  output = Process.output(peer, 60_000).unwrap!
  lines = output.stdout.split("\n").select { |line| line != "" }
  BDD.assert(BDD.set(ctx, "cases", JSON.from(lines)), lines.length == args[0].to_i!, "the peer wrote #{lines.length}")
end

## Signs each case and compares the URL, and for a request the `Authorization` header, with the peer's. The first that
## differs is the failure, with its URL.
def agree(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  lines = JSON.list(BDD.get(ctx, "cases").unwrap!).unwrap!
  seen = 0
  for line in lines
    item = JSON.decode(JSON.string(line).unwrap!, Case).unwrap!
    mine = sign(item)
    return BDD.assert(ctx, false, "#{item.kind} #{item.url}: the package says #{mine}") if mine != expected(item)

    seen = seen + 1
  end

  BDD.assert(ctx, seen > 0, "no case written")
end

private

PEER = "specs/fixtures/sigv4_peer.py"

def params(pairs: List[List[String]]) -> List[Types.Param]
  pairs.map { |pair| Types.Param(name: pair[0], value: pair[1]) }
end

def config_of(setup: Setup) -> Types.Config
  addressing = Types.Addressing.Path
  if setup.addressing == "Virtual"
    addressing = Types.Addressing.Virtual
  end

  Types.Config(
    endpoint: setup.endpoint,
    region: setup.region,
    access_key: setup.access_key,
    secret_key: setup.secret_key,
    bucket: setup.bucket,
    session_token: setup.session_token,
    addressing: addressing,
  )
end

def expected(item: Case) -> String = "#{item.url}\n#{item.authorization}"

def sign(item: Case) -> String
  config = config_of(item.config)
  if item.kind == "presign"
    options = Types.Presign(
      expires_s: item.expires,
      query: params(item.query),
      headers: params(item.headers),
      at: some(item.at),
    )

    return "#{Presigned.url(config, item.method, item.key, options).unwrap_or("error")}\n"
  end

  prepared = Request.prepare(
    config,
    item.method,
    item.key,
    params(item.query),
    params(item.headers),
    item.payload,
    item.at,
  )

  case prepared
    ok(p) -> "#{p.url}\n#{authorization(p)}"
    error(e) -> "error #{e.message}"
  end
end

def authorization(prepared: Request.Prepared) -> String
  found = prepared.headers.select { |h| h.name == "authorization" }
  return "" if found.empty?

  found[0].value
end
