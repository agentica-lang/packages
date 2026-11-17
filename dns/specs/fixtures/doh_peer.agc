## The peer of the DNS over HTTPS scenarios: an HTTPS server of `std/http` on 127.0.0.1 and a free port, which it says
## on its first line (`listening on PORT`), with the certificate of the environment variables `TLS_CERT` and `TLS_KEY`
## (PEM files). It does not use the codec of the package. The script is the program arguments, one path each:
##
##   PATH STATUS TYPE DELAY HEX
##
## A request for PATH waits DELAY milliseconds and gets the status STATUS, the header `Content-Type: TYPE` (`-` for
## none) and the bytes of HEX as the body. In a HEX the words are joined (spaces are ignored) and `ID` (the id of the
## query), `OTHERID` (another id) and `QUESTION` (its question section) stand for bytes of the query. A path that the
## script does not name gets a 404.
##
## For each request the peer prints `request METHOD PATH type=T accept=A id=N ID` and the rest of the query in hex.

import HTTP from "std/http"

private

HEADER_BYTES = 12

struct Rule
  path: String
  status: Int
  type: String
  delay: Int
  words: List[String]
end

def header_of(request: HTTP.Request, name: String) -> String
  values = HTTP.header_values(request.headers, name)
  return "none" if values.empty?

  values[0]
end

def rules_of(lines: List[String]) -> List[Rule]
  lines.map do |line|
    fields = line.split(" ")
    Rule(path: fields[0], status: fields[1].to_i!, type: fields[2], delay: fields[3].to_i!, words: fields.drop(4))
  end
end

def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

def word(query: Bytes, text: String) -> String
  case text
    "ID" -> hex(query.take(2))
    "OTHERID" -> hex(Bytes.from_list([(query[0] + 1) % 256, query[1]]).unwrap!)
    "QUESTION" -> hex(query.drop(HEADER_BYTES))
    _ -> text
  end
end

def answer(rule: Rule, query: Bytes) -> HTTP.Response
  headers: List[HTTP.Header] = []
  if rule.type != "-"
    headers = [HTTP.Header(name: "Content-Type", value: rule.type)]
  end

  body = OpenSSL.Digest.hexdecode(rule.words.map { |w| word(query, w) }.join("")).unwrap!
  HTTP.Response(status: rule.status, headers: headers, body: body)
end

def serve(rules: List[Rule], request: HTTP.Request) -> Result[HTTP.Response]
  query = request.body
  id = 0
  if query.size >= 2
    id = query[0] * 256 + query[1]
  end

  type = header_of(request, "content-type")
  accept = header_of(request, "accept")
  puts("request #{request.method} #{request.path} type=#{type} accept=#{accept} id=#{id} ID#{hex(query.drop(2))}")
  IO.flush()
  for rule in rules
    if rule.path == request.path
      Task.sleep(rule.delay)
      return ok(answer(rule, query))
    end
  end

  ok(HTTP.Response(status: 404, headers: [], body: "not found".bytes))
end

def main() -> Void
  rules = rules_of(System.args())
  context = TLS.server_context(
    TLS.ServerOptions(cert_file: System.env("TLS_CERT").unwrap!, key_file: System.env("TLS_KEY").unwrap!),
  ).unwrap!

  app = HTTP.app(->(request) { serve(rules, request) })
  server = HTTP.serve_tls("127.0.0.1", 0, context, app).unwrap!
  puts("listening on #{HTTP.local_port(server)}")
  IO.flush()
  HTTP.wait(server).unwrap!
end
