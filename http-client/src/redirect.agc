## Where a redirect leads: the next hop of a request after a 301, 302, 303, 307 or 308 with a `Location`.
##
## A 303 turns the method into GET (HEAD stays HEAD), and so do a 301 and a 302 for a POST, as browsers and Req do; a
## 307 and a 308 keep the method and the body. A hop that turns into GET has no body and no `Content-Type`. A hop to
## another origin than the first request's goes without `Authorization`, `Cookie` and `Proxy-Authorization`.

import Exchange from "exchange"
import HTTP from "std/http"
import Url from "url"

## One hop of a request: the method, where it goes, its headers and its body.
struct Hop
  method: String
  target: Url.Target
  headers: List[HTTP.Header]
  body: Bytes
end

## The `Location` of a redirect, or none for a response that is not one.
def location(response: Exchange.Response) -> Optional[String]
  values = HTTP.header_values(response.headers, "location")
  return none if values.empty? or not REDIRECTS.include?(response.status)

  some(values[0])
end

## The hop after `hop` was answered with `status` and `location`. `first` is the target of the first hop. A `Location`
## that does not read as an http or https URL is an `http_client.redirect.location` error.
def next(first: Url.Target, hop: Hop, status: Int, location: String) -> Result[Hop]
  target = Url.follow(hop.target, location)
  return Exchange.failure("the redirect to #{location} cannot be followed", "redirect.location") if not target.ok?

  method = next_method(hop.method, status)
  headers = hop.headers
  body = hop.body
  if method != hop.method
    headers = without(headers, ["content-type"])
    body = NO_BODY
  end

  if target.unwrap!.origin != first.origin
    headers = without(headers, CREDENTIALS)
  end

  ok(Hop(method: method, target: target.unwrap!, headers: headers, body: body))
end

private

REDIRECTS = [301, 302, 303, 307, 308]
CREDENTIALS = ["authorization", "cookie", "proxy-authorization"]
NO_BODY = "".bytes

def next_method(method: String, status: Int) -> String
  return "GET" if status == 303 and method != "HEAD"
  return "GET" if (status == 301 or status == 302) and method == "POST"

  method
end

def without(headers: List[HTTP.Header], names: List[String]) -> List[HTTP.Header]
  headers.select { |header| not names.include?(header.name.downcase) }
end
