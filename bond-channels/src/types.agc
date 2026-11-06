## The records that an app of `bond-channels` builds or receives: who is connected, what a channel does, the options.

## Who a connection is, as `connect` decides it: `id` is the key of the person (for logs and presence) and `data` what
## the handlers need to know (JSON, so that the hub holds no type of the app).
export struct Identity
  id: String
  data: Json
end

## One cable connection, as a handler sees it: `connection` is its number, `subscriptions` the identifiers that it
## holds now.
export struct Session
  connection: Int
  identity: Identity
  subscriptions: List[String]
end

## What `subscribed` decides. `streams` are the topics whose broadcasts reach this subscription; `transmit` are the
## payloads sent to this connection only, before the confirmation (a JSON string is a Turbo Stream, an object a
## notice); `rejected` answers `reject_subscription` instead of the confirmation.
export struct Subscription
  streams: List[String] = []
  transmit: List[Json] = []
  rejected: Bool = false
end

## The functions of one channel class. `perform` gets the `action` and the whole `data` of a client message and gives
## the payloads to transmit to that connection. An `error` of any of them is logged and the connection stays open.
export struct Handler
  subscribed: Fn[Session, Json, Result[Subscription]]
  unsubscribed: Fn[Session, Json, Result[Void]]
  perform: Fn[Session, Json, String, Json, Result[List[Json]]]
end

## `inbox`, `idle_ms` and `max_message_bytes` are read by `mount`, `broadcast_wait_ms` and `beat_ms` by `start_hub`.
## `inbox` is the frames queued for one connection (a connection with a full inbox is dropped); a peer silent for
## `idle_ms` is closed; a client frame over `max_message_bytes` closes with 1009; a broadcast waits `broadcast_wait_ms`
## for room in the hub inbox. `beat_ms` is the Action Cable ping, 3000 as Rails has it; only the specs change it.
export struct Options
  inbox: Int = 256
  idle_ms: Int = 120_000
  max_message_bytes: Int = 65_536
  broadcast_wait_ms: Int = 5_000
  beat_ms: Int = 3_000
end

## What `stats` counts: `drops` are connections the hub closed for a full inbox, `lost` broadcasts that could not be
## queued.
export struct Stats
  connections: Int
  subscriptions: Int
  drops: Int
  lost: Int
end
