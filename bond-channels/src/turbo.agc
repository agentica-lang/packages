## The channel of `<turbo-cable-stream-source>`: `Turbo::StreamsChannel` of turbo-rails. The client sends the
## `signed_stream_name` that the page carried; the channel verifies it and streams from the name inside.

import Signing from "signing"
import Types from "types"

## The `subscribed` of a Turbo channel. A name that is missing, is not a string or does not verify with `key` rejects
## the subscription, and so does a verified one that `authorize(session, name)` refuses (the membership check of the
## app: a signature says the page was made for someone, not that this person may read it now).
export def subscribing(
  key: Bytes,
  authorize: Fn[Types.Session, String, Bool],
) -> Fn[Types.Session, Json, Result[Types.Subscription]]
  return signed() do |session, params| subscribe(key, authorize, session, params) end
end

# A block cannot be assigned to a name: this gives it a typed parameter first.
def signed(
  f: Fn[Types.Session, Json, Result[Types.Subscription]],
) -> Fn[Types.Session, Json, Result[Types.Subscription]]
  return f
end

def subscribe(
  key: Bytes,
  authorize: Fn[Types.Session, String, Bool],
  session: Types.Session,
  params: Json,
) -> Result[Types.Subscription]
  name = verified(key, params)
  if name.none? or not authorize.call(session, name.unwrap!)
    return ok(Types.Subscription(rejected: true))
  end

  return ok(Types.Subscription(streams: [name.unwrap!]))
end

def verified(key: Bytes, params: Json) -> Optional[String]
  field = JSON.get(params, "signed_stream_name")
  if not field.ok?
    return none
  end

  signed_name = JSON.string(field.unwrap!)
  if not signed_name.ok?
    return none
  end

  return Signing.verified_stream_name(key, signed_name.unwrap!)
end
