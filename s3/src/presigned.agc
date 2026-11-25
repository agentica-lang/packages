## Presigned URLs: pure, they touch no network. The URL is signed for the host of the endpoint of the `Config`.

import Address from "address"
import Encoding from "encoding"
import Failure from "failure"
import Request from "request"
import Sigv4 from "sigv4"
import Types from "types"

## A URL that does `method` on `key` for `expires_s` seconds (1 to 604800) from `options.at`. An `error` of the kind
## `s3.invalid` for a `Config`, a key or an expiry that is refused.
def url(config: Types.Config, method: String, key: String, options: Types.Presign = Types.Presign()) -> Result[String]
  if options.expires_s < 1 or options.expires_s > Types.MAX_EXPIRES_S
    return Failure.invalid("expires_s must be from 1 to #{Types.MAX_EXPIRES_S}")
  end

  return Failure.invalid("a presigned URL needs a key") if key == ""

  target = try Address.target(config, key)
  at = options.at.unwrap_or(Time.now().to_i)
  amz = try Encoding.amz_date(at)
  query = Sigv4.presign(
    Request.scope_of(config),
    method,
    target.host,
    target.path,
    options.query,
    options.headers,
    options.expires_s,
    amz,
  )

  ok("#{target.origin}#{target.path}?#{query}")
end

## A URL for a `PUT` of one part of a multipart upload.
def part(config: Types.Config, key: String, upload_id: String, number: Int, options: Types.Presign) -> Result[String]
  return Failure.invalid("a part number is from 1 to #{Types.MAX_PARTS}") if number < 1 or number > Types.MAX_PARTS

  return Failure.invalid("the upload id is empty") if upload_id == ""

  query = [Types.Param(name: "partNumber", value: "#{number}"), Types.Param(name: "uploadId", value: upload_id)]
  url(
    config,
    "PUT",
    key,
    Types.Presign(
      expires_s: options.expires_s,
      query: options.query + query,
      headers: options.headers,
      at: options.at,
    ),
  )
end
