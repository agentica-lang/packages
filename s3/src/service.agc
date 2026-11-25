## The service: a checked `Config` and the connections it uses.

import Address from "address"
import HTTP from "std/http"
import Failure from "failure"
import Types from "types"

## The most that `Options.max_body_bytes` may be: the limit of `std/http`.
MAX_BODY_BYTES = 67_108_864

## Makes a client. An `error` of the kind `s3.invalid` for a `Config` that `Address.target` refuses (see `S3.client`)
## or an option that is not positive, and the error of `std/http` when it cannot make its client.
def client(config: Types.Config, options: Types.Options = Types.Options()) -> Result[Types.Client]
  try Address.check(config)
  return Failure.invalid("the timeouts must be positive") if options.timeout_ms < 1 or options.transfer_timeout_ms < 1

  if options.max_body_bytes < 1 or options.max_body_bytes > MAX_BODY_BYTES
    return Failure.invalid("max_body_bytes must be from 1 to #{MAX_BODY_BYTES}")
  end

  http = try HTTP.client(http_options(options, options.timeout_ms, options.max_body_bytes))
  transfer = http_options(options, options.transfer_timeout_ms, ANSWER_BYTES)
  ok(Types.Client(config: config, http: http, options: options, transfer: transfer))
end

## Closes the connections of a client.
def close(client: Types.Client) -> Void
  HTTP.close_client(client.http)
end

private

# What a streamed call keeps of an answer: the XML of an error, or the little that a `PUT` answers.
ANSWER_BYTES = 1_048_576
# The longest wait for the next bytes of a body or of an upload: S3 and the servers like it send or take a piece in
# seconds, so a stalled transfer ends here and not after `transfer_timeout_ms`.
READ_TIMEOUT_MS = 120_000

def http_options(options: Types.Options, timeout_ms: Int, max_body_bytes: Int) -> HTTP.ClientOptions
  HTTP.ClientOptions(
    timeout_ms: timeout_ms,
    max_body_bytes: max_body_bytes,
    read_timeout_ms: READ_TIMEOUT_MS,
    tls: options.tls,
    connect_to: options.connect_to,
  )
end
