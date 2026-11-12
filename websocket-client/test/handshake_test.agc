import HTTP from "std/http"
import Handshake from "../src/handshake"

# RFC 6455 4.2.2 and 1.3: the key of the example and the accept it gets.
KEY = "dGhlIHNhbXBsZSBub25jZQ=="
ACCEPT = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

def target(url: String) -> Handshake.Target = Handshake.parse_url(url).unwrap!

def test_the_accept_of_the_rfc() -> Result[Void] = Test.eq(Handshake.accept_key(KEY), ACCEPT)

def test_a_ws_url_has_a_default_port_and_path() -> Result[Void]
  try Test.eq(target("ws://example.com"), Handshake.Target(secure: false, host: "example.com", port: 80, path: "/"))
  try Test.eq(
    target("WSS://example.com/cable?x=1#top"),
    Handshake.Target(secure: true, host: "example.com", port: 443, path: "/cable?x=1"),
  )

  try Test.eq(target("ws://127.0.0.1:8080/a/b").port, 8080)
  try Test.eq(target("ws://[::1]:9000/").host, "::1")
  try Test.eq(target("ws://example.com?x=1").path, "/?x=1")
  try Test.eq(Handshake.host_header(target("ws://example.com")), "example.com")
  try Test.eq(Handshake.host_header(target("ws://example.com:80/")), "example.com")
  try Test.eq(Handshake.host_header(target("wss://example.com:8443/")), "example.com:8443")
  Test.eq(Handshake.host_header(target("ws://[::1]:9000/")), "[::1]:9000")
end

def test_a_url_that_is_not_a_websocket_url_is_refused() -> Result[Void]
  for url in [
    "http://example.com/", "example.com", "ws://", "ws://:80/", "ws://user:pw@example.com/", "ws://host:0/",
    "ws://host:99999/", "ws://host:x/", "ws://a b/",
  ]
    try Test.error?(Handshake.parse_url(url))
  end

  ok()
end

def header(name: String, value: String) -> HTTP.Header = HTTP.Header(name: name, value: value)

def test_the_request_is_an_upgrade_with_the_key_and_the_extra_headers() -> Result[Void]
  text = Handshake.request(target("ws://example.com:81/cable"), KEY, ["chat", "v2"], [header("Cookie", "a=b")]).unwrap!
  lines = text.split("\r\n")
  try Test.eq(lines[0], "GET /cable HTTP/1.1")
  try Test.eq(
    lines.drop(1).take(7),
    [
      "Host: example.com:81",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: #{KEY}",
      "Sec-WebSocket-Version: 13",
      "Sec-WebSocket-Protocol: chat, v2",
      "Cookie: a=b",
    ],
  )

  Test.assert(text.end_with?("\r\n\r\n"), "the head ends with an empty line")
end

def test_a_header_that_the_handshake_owns_or_that_injects_is_refused() -> Result[Void]
  t = target("ws://example.com/")
  for bad in [
    header("Upgrade", "h2c"),
    header("connection", "close"),
    header("Sec-WebSocket-Key", "x"),
    header("sec-websocket-version", "8"),
    header("Sec-WebSocket-Protocol", "chat"),
    header("Sec-WebSocket-Extensions", "permessage-deflate"),
    header("Host", "other"),
    header("X-A", "b\r\nX-B: c"),
    header("X A", "b"),
    header("", "b"),
  ]
    try Test.error?(Handshake.request(t, KEY, [], [bad]))
  end

  ok()
end

def answer(extra: List[String]) -> List[String]
  (
    [
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Accept: #{ACCEPT}",
    ] +
    extra
  )
end

def test_a_good_answer_gives_the_protocol_the_server_chose() -> Result[Void]
  try Test.eq(Handshake.check_response(answer([]), KEY, []), ok(""))
  try Test.eq(Handshake.check_response(answer(["Sec-WebSocket-Protocol: chat"]), KEY, ["chat", "v2"]), ok("chat"))
  # Names of headers and the tokens of Upgrade and Connection have no case.
  lines = [
    "HTTP/1.1 101 Switching Protocols",
    "upgrade: WebSocket",
    "CONNECTION: keep-alive, upgrade",
    "sec-websocket-accept: #{ACCEPT}",
  ]

  Test.eq(Handshake.check_response(lines, KEY, []), ok(""))
end

def test_a_bad_answer_is_an_error() -> Result[Void]
  try Test.error?(Handshake.check_response(["HTTP/1.1 403 Forbidden", "Content-Length: 0"], KEY, []))
  try Test.error?(Handshake.check_response(["HTTP/1.1 200 OK"] + answer([]).drop(1), KEY, []))
  try Test.error?(Handshake.check_response(["garbage"], KEY, []))
  try Test.error?(Handshake.check_response([], KEY, []))
  try Test.error?(Handshake.check_response(answer([]).drop(1), KEY, []))
  try Test.error?(Handshake.check_response(answer([]).take(1) + answer([]).drop(2), KEY, []))
  try Test.error?(Handshake.check_response(answer([]).take(2) + answer([]).drop(3), KEY, []))
  try Test.error?(Handshake.check_response(answer([]).take(3), KEY, []))
  try Test.error?(Handshake.check_response(answer([]), "AAAAAAAAAAAAAAAAAAAAAA==", []))
  # A protocol nobody asked for, and an extension that the client did not offer.
  try Test.error?(Handshake.check_response(answer(["Sec-WebSocket-Protocol: chat"]), KEY, []))
  try Test.error?(Handshake.check_response(answer(["Sec-WebSocket-Protocol: other"]), KEY, ["chat"]))
  try Test.error?(
    Handshake.check_response(answer(["Sec-WebSocket-Protocol: chat", "Sec-WebSocket-Protocol: chat"]), KEY, ["chat"]),
  )

  Test.error?(Handshake.check_response(answer(["Sec-WebSocket-Extensions: permessage-deflate"]), KEY, []))
end

def test_the_headers_of_an_answer_keep_their_names_and_lose_the_spaces() -> Result[Void]
  headers = Handshake.headers_of(["UPGRADE:  WebSocket ", "X-Url: http://a:80", "no colon", "Content-Length: 12"])
  try Test.eq(headers.size, 3)
  try Test.eq(headers[0], HTTP.Header(name: "UPGRADE", value: "WebSocket"))
  try Test.eq(headers[1], HTTP.Header(name: "X-Url", value: "http://a:80"))
  try Test.eq(Handshake.content_length(headers, 100), 12)
  try Test.eq(Handshake.content_length(headers, 5), 5)
  try Test.eq(Handshake.content_length([HTTP.Header(name: "content-length", value: "x")], 100), 0)
  try Test.eq(Handshake.content_length([HTTP.Header(name: "Content-Length", value: "99999999999999999999")], 100), 100)
  try Test.eq(Handshake.content_length([HTTP.Header(name: "Content-Length", value: "-3")], 100), 0)
  # The first one wins.
  try Test.eq(
    Handshake.content_length(
      [HTTP.Header(name: "Content-Length", value: "3"), HTTP.Header(name: "content-length", value: "9")],
      100,
    ),
    3,
  )

  try Test.eq(Handshake.content_length([], 100), 0)
  try Test.eq(Handshake.status_of("HTTP/1.1 403 Forbidden"), ok(403))
  Test.error?(Handshake.status_of("garbage"))
end
