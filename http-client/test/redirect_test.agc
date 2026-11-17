import HTTP from "std/http"
import Redirect from "../src/redirect"
import {Hop} from "../src/redirect"
import Url from "../src/url"

private

def hop(url: String, headers: List[HTTP.Header]) -> Hop
  Hop(method: "POST", target: Url.resolve("", url).unwrap!, headers: headers, body: "data".bytes)
end

def kind(result: Result[Hop]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def names(result: Result[Hop]) -> List[String] = result.unwrap!.headers.map { |header| header.name }

def test_a_redirect_from_https_to_http_or_with_a_space_is_refused() -> Result[Void]
  secure = hop("https://a.example/x", [])
  try Test.eq(
    kind(Redirect.next(secure.target, secure, 302, "http://a.example/y", false)),
    "http_client.redirect.location",
  )

  try Test.eq(kind(Redirect.next(secure.target, secure, 302, "https://b.example/y", false)), "ok")
  Test.eq(kind(Redirect.next(secure.target, secure, 302, "/a b", false)), "http_client.redirect.location")
end

def test_proxy_authorization_goes_to_another_origin_only_through_the_proxy() -> Result[Void]
  first = hop(
    "http://a.example/x",
    [HTTP.Header(name: "Authorization", value: "a"), HTTP.Header(name: "Proxy-Authorization", value: "p")],
  )

  try Test.eq(
    names(Redirect.next(first.target, first, 307, "http://a.example/y", false)),
    ["Authorization", "Proxy-Authorization"],
  )

  try Test.eq(names(Redirect.next(first.target, first, 307, "http://b.example/y", true)), ["Proxy-Authorization"])
  try Test.eq(names(Redirect.next(first.target, first, 307, "http://b.example/y", false)), [])
  Test.eq(Redirect.next(first.target, first, 307, "http://b.example/y", false).unwrap!.body, "data".bytes)
end
