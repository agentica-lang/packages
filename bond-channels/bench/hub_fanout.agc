## Measures the fan-out of the hub alone: no sockets, the inboxes of the connections are read by this program.
##
##   CLIENTS=2000 MESSAGES=50 IDENTIFIERS=2 PAYLOAD=1000 agentica bench/hub_fanout.agc
##
## CLIENTS connections subscribe to one topic under each of IDENTIFIERS identifiers; MESSAGES broadcasts of a PAYLOAD
## bytes text go out. It prints the wall time of the broadcasts and the frames per second. With
## `AGENTICA_VM_TRACE=profile` the `steps`, `gc_ms` and `collections` of the report are the cost of the hub task and the
## process. It is run by hand: the time depends on the machine.

import Hubs from "../src/hub"
import Protocol from "../src/protocol"
import {HubOptions} from "../src/types"

TOPIC = "room:1"

def setting(name: String, fallback: Int) -> Int
  case System.env(name)
    ok(text) -> return text.to_i.unwrap_or(fallback)
    error(_) -> return fallback
  end
end

def identifier(index: Int) -> String
  return "{\"channel\":\"RoomChannel\",\"room\":\"#{index}\"}"
end

# The frames wait in the inboxes of the connections, so each holds every message of every identifier.
def join(hub: Hubs.Hub, connection: Int, identifiers: Int, capacity: Int) -> Result[Channel[Hubs.Event]]
  inbox: Channel[Hubs.Event] = Channel.new(capacity)
  try Hubs.register(hub, connection, "user#{connection}", inbox, 1_000)
  for index in 1..identifiers
    try Hubs.attach(hub, connection, identifier(index), [TOPIC])
  end

  return ok(inbox)
end

def run(clients: Int, messages: Int, identifiers: Int, payload: Int) -> Result[Void]
  hub = try Hubs.start(HubOptions())
  inboxes: List[Channel[Hubs.Event]] = []
  for connection in 1..clients
    inboxes = inboxes.push(try join(hub, connection, identifiers, messages * identifiers))
  end

  text = Protocol.text_payload(List.repeat("x", payload).join(""))
  started = Time.monotonic_ms()
  for _ in 1..messages
    try Hubs.broadcast(hub, TOPIC, text)
  end

  # The hub serves a broadcast to its connections in order, so the last one is the last to hear the last frame.
  last = inboxes[clients - 1]
  for _ in 1..(messages * identifiers)
    try last.recv(60_000)
  end

  elapsed = Time.monotonic_ms() - started
  frames = clients * messages * identifiers
  puts("clients=#{clients} messages=#{messages} identifiers=#{identifiers} payload=#{payload} wall_ms=#{elapsed}")
  puts("frames=#{frames} frames_per_s=#{frames * 1_000 / (elapsed + 1)}")
  try Hubs.stop(hub)
  return Task.await(hub.task)
end

def main() -> Void
  outcome = run(
    setting("CLIENTS", 2_000),
    setting("MESSAGES", 50),
    setting("IDENTIFIERS", 2),
    setting("PAYLOAD", 1_000),
  )

  if not outcome.ok?
    IO.warn("bench failed: #{outcome.message}")
  end
end
