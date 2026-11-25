## Where a request goes, pure: the endpoint of a `Config` checked, and the URL, the `Host` and the path of a key.

import Encoding from "encoding"
import Types from "types"

## Where one key is: `origin` is the scheme and the host (`https://bucket.s3.example.com`), `host` the value of the
## `Host` header, `path` the path as sent and as signed.
struct Target
  origin: String
  host: String
  path: String
end

## The `Target` of a key (`""` is the bucket itself), or an `error` of the kind `s3.invalid` for a `Config` or a key S3
## would refuse: an endpoint that is not `http://` or `https://` host with an optional port and no path, no region,
## credentials or bucket, a bucket that is not a DNS name of 3 to 63 characters, a key over 1024 bytes, or one that
## starts with `/`.
def target(config: Types.Config, key: String) -> Result[Target]
  try check(config)
  return invalid("a key may not start with /") if key.start_with?("/")
  return invalid("a key is at most #{Types.MAX_KEY_BYTES} bytes") if key.bytesize > Types.MAX_KEY_BYTES

  scheme = config.endpoint.split("://")[0]
  authority = config.endpoint.split("://")[1]
  case config.addressing
    Types.Addressing.Path ->
      path = "/#{Encoding.component(config.bucket)}"
      if key != ""
        path = "#{path}/#{Encoding.path(key)}"
      end

      ok(Target(origin: "#{scheme}://#{authority}", host: host_of(scheme, authority), path: path))
    Types.Addressing.Virtual ->
      host = "#{config.bucket}.#{authority}"
      ok(Target(origin: "#{scheme}://#{host}", host: host_of(scheme, host), path: "/#{Encoding.path(key)}"))
  end
end

## Checks a `Config` as `target` does.
def check(config: Types.Config) -> Result[Void]
  return invalid("the endpoint must be http:// or https:// followed by a host") if bad_endpoint?(config.endpoint)
  return invalid("the region is empty") if config.region == ""
  if config.access_key == "" or config.secret_key == ""
    return invalid("the access key and the secret key must not be empty")
  end

  return invalid("the bucket #{config.bucket} is not a DNS name of 3 to 63 characters") if bad_bucket?(config.bucket)

  ok()
end

private

def invalid[T](message: String) -> Result[T] = error(message, kind: Types.INVALID)

def bad_endpoint?(endpoint: String) -> Bool
  parts = endpoint.split("://")
  return true if parts.length != 2 or not (parts[0] == "http" or parts[0] == "https")

  authority = parts[1]
  return true if authority == ""

  authority.split("").any? { |c| c == "/" or c == "?" or c == "#" or c == "@" or c == " " }
end

def bad_bucket?(bucket: String) -> Bool
  return true if bucket.length < 3 or bucket.length > 63
  return true if bucket.start_with?(".") or bucket.end_with?(".") or bucket.start_with?("-") or bucket.end_with?("-")

  bucket.bytes.to_a.any? { |b| not bucket_byte?(b) }
end

def bucket_byte?(b: Int) -> Bool
  return true if b >= "a".code and b <= "z".code
  return true if b >= "0".code and b <= "9".code

  b == "-".code or b == ".".code
end

# The default port is not part of the Host that clients send, so it is not part of the signed one.
def host_of(scheme: String, authority: String) -> String
  return authority.slice(0, authority.length - 3) if scheme == "http" and authority.end_with?(":80")
  return authority.slice(0, authority.length - 4) if scheme == "https" and authority.end_with?(":443")

  authority
end
