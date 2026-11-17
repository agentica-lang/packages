import Url from "../src/url"

private

BASE = "http://api.example.com/v1"

def resolved(url: String) -> String = Url.to_s(Url.resolve(BASE, url).unwrap!)

def kind(base_url: String, url: String) -> String
  case Url.resolve(base_url, url)
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def test_an_absolute_url_has_its_default_port_and_path() -> Result[Void]
  try Test.eq(
    Url.resolve("", "HTTPS://Example.COM?q=1#top").unwrap!,
    Url.Target(scheme: "https", host: "example.com", port: 443, origin: "https://example.com:443", target: "/?q=1"),
  )

  try Test.eq(Url.resolve("", "http://127.0.0.1:8080/a/b").unwrap!.origin, "http://127.0.0.1:8080")
  Test.eq(Url.resolve("", "http://[::1]:9000/x").unwrap!.origin, "http://[::1]:9000")
end

def test_a_path_is_joined_to_the_base_url() -> Result[Void]
  try Test.eq(resolved("/todos"), "http://api.example.com:80/v1/todos")
  try Test.eq(resolved("todos?page=2"), "http://api.example.com:80/v1/todos?page=2")
  try Test.eq(resolved("?page=2"), "http://api.example.com:80/v1?page=2")
  try Test.eq(resolved(""), "http://api.example.com:80/v1")
  try Test.eq(Url.to_s(Url.resolve("http://h/", "/x").unwrap!), "http://h:80/x")
  Test.eq(resolved("https://other.example.com/x"), "https://other.example.com:443/x")
end

def test_a_bad_url_is_an_argument_error() -> Result[Void]
  try Test.eq(kind("", "/todos"), "argument")
  try Test.eq(kind("", "ftp://example.com/"), "argument")
  try Test.eq(kind(BASE, "ftp://example.com/"), "argument")
  try Test.eq(kind(BASE, "/go?to=ftp://example.com/"), "ok")
  try Test.eq(kind("", "http://user:pw@example.com/"), "argument")
  try Test.eq(kind("", "http://example.com:0/"), "argument")
  try Test.eq(kind("", "http://example.com:65536/"), "argument")
  try Test.eq(kind("", "http://:80/"), "argument")
  Test.eq(kind("", "http://[::1/"), "argument")
end

# The examples of RFC 3986, section 5.4, with the default port written out.
def test_a_location_is_read_against_the_url_of_its_response() -> Result[Void]
  base = Url.resolve("", "http://a/b/c/d;p?q").unwrap!
  cases = {
    "g": "http://a:80/b/c/g",
    "./g": "http://a:80/b/c/g",
    "g/": "http://a:80/b/c/g/",
    "/g": "http://a:80/g",
    "//g": "http://g:80/",
    "?y": "http://a:80/b/c/d;p?y",
    "g?y": "http://a:80/b/c/g?y",
    "#s": "http://a:80/b/c/d;p?q",
    "g#s": "http://a:80/b/c/g",
    "": "http://a:80/b/c/d;p?q",
    ".": "http://a:80/b/c/",
    "./": "http://a:80/b/c/",
    "..": "http://a:80/b/",
    "../g": "http://a:80/b/g",
    "../..": "http://a:80/",
    "../../g": "http://a:80/g",
    "../../../g": "http://a:80/g",
    "/./g": "http://a:80/g",
    "/../g": "http://a:80/g",
    "g.": "http://a:80/b/c/g.",
    "..g": "http://a:80/b/c/..g",
    "./g/.": "http://a:80/b/c/g/",
    "g/../h": "http://a:80/b/c/h",
    "g;x=1/../y": "http://a:80/b/c/y",
    "g?y/./x": "http://a:80/b/c/g?y/./x",
    "https://other:8443/x": "https://other:8443/x",
  }

  for reference in cases.keys
    try Test.eq([reference, Url.to_s(try Url.follow(base, reference))], [reference, cases.get(reference).unwrap!])
  end

  Test.eq(Url.follow(base, "ftp://a/b").ok?, false)
end
