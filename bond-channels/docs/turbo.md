---
title: Turbo Streams
description: Signed stream names, the same format as Rails, and the handler for turbo-cable-stream-source.
weight: 2
---

Turbo pages open a stream with `<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="...">`. The name is signed so that a person cannot subscribe to the stream of somebody else.

`bond-channels` signs and verifies the names in the format of Rails (`Turbo.signed_stream_verifier` of turbo-rails). A name that Rails signed with the same secret verifies here, and the other way round. This is checked against vectors that Rails made.

The name is signed, not encrypted: anybody can read it. The signature is what stops a person from making a name.

## Sign a name

`Channels.stream_key(secret)` makes the key from the secret of the app (the `secret_key_base` of a Rails app too). Make it once, at start-up. An empty secret is an `error`.

`Channels.signed_stream_name(key, name)` returns the value for the `signed-stream-name` attribute of the page. `name` is the parts of the stream joined with `:`, as `Turbo::StreamsChannel.broadcast_*_to` of Rails joins them.

`Channels.verified_stream_name(key, signed)` returns the name as `some(name)` if `key` signed it, and `none` for anything else (a bad signature, or a message that is not a name).

```agentica {mode="fragment"}
key = Channels.stream_key("dev-secret").unwrap!
signed = Channels.signed_stream_name(key, "user:ana")
puts(signed)
puts(Channels.verified_stream_name(key, signed))
puts(Channels.verified_stream_name(key, "nope"))
```

```text
InVzZXI6YW5hIg==--56e83d88cc04ffe87c8de8a81f38a5ce347b0bca96fa9e304730cf7588cdf875
some("user:ana")
none
```

The first line depends on the secret. Use the real secret of your app, not the one of this example.

## The channel

`Channels.turbo_streams(key, authorize)` is the handler for `<turbo-cable-stream-source>`. It verifies the `signed_stream_name` that the client sends, and streams from the name inside. It rejects the subscription when the name is missing, is not a string, does not verify, is empty, or when `authorize(session, name)` is false.

The signature says that the page was made for someone, not that this person may read the stream now. `authorize` is the membership check of your app:

```agentica {mode="fragment"}
# A person may listen to the stream of their own name only.
def allowed?(session: Channels.Session, name: String) -> Bool
  return name == "user:#{session.identity.id}"
end

key = Channels.stream_key(System.env("SECRET_KEY_BASE").unwrap_or("dev-secret")).unwrap!
handlers = {"Turbo::StreamsChannel": Channels.turbo_streams(key, &allowed?)}
options = Channels.MountOptions(connect: &connect, handlers: handlers)
```

Register it under the channel names that the page uses (`Turbo::StreamsChannel`, or one of your own).

## Broadcast a Turbo Stream

`Channels.broadcast_text(hub, topic, text)` sends the text as a JSON string, which is how Turbo reads a Turbo Stream. The topic is the verified name:

```agentica {mode="fragment"}
html = "<turbo-stream action=\"append\" target=\"log\"><template>hi</template></turbo-stream>"
Channels.broadcast_text(hub, "user:ana", html).unwrap!
```

`Channels.broadcast_json(hub, topic, value)` sends a JSON value instead, such as an object for a notice.
