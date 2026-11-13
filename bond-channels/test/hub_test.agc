import HTTP from "std/http"
import Hubs from "../src/hub"
import Protocol from "../src/protocol"
import {HubOptions} from "../src/types"

private

# True when the next event of the inbox is `Away(reconnect)`.
def away?(inbox: Channel[Hubs.Event], reconnect: Bool) -> Bool
  got = inbox.recv(2_000)
  return false if not got.ok?

  case got.unwrap!
    Hubs.Event.Away(again) -> again == reconnect
    _ -> false
  end
end

def wait_closed(inbox: Channel[Hubs.Event]) -> Bool
  for _ in 1..200
    return true if inbox.closed?

    Task.sleep(10)
  end

  false
end

def inbox_of() -> Channel[Hubs.Event] = Channel.new(4)

def line_of(capacity: Int) -> Channel[HTTP.Message] = Channel.new(capacity)

def framed(text: String) -> HTTP.Message = HTTP.prepare(HTTP.Message.Text(text))

def confirm(identifier: String) -> String = "confirmed #{identifier}"

def join(hub: Hubs.Hub, connection: Int, identity: String, outgoing: Channel[HTTP.Message]) -> Result[Void]
  Hubs.register(hub, connection, identity, inbox_of(), outgoing, 1)
end

def attach(hub: Hubs.Hub, connection: Int, identifier: String, topics: List[String]) -> Result[Void]
  Hubs.attach(hub, connection, identifier, topics, confirm(identifier))
end

# What the WebSocket was given, once the hub has handled every message queued before it was stopped.
def written(outgoing: Channel[HTTP.Message]) -> List[HTTP.Message]
  messages: List[HTTP.Message] = []
  while true
    got = outgoing.recv(100)
    return messages if not got.ok?

    messages = messages.push(got.unwrap!)
  end

  messages
end

def finish(hub: Hubs.Hub) -> Result[Void]
  try Hubs.stop(hub)
  Task.await(hub.task)
end

def main() -> Void
  Test.run([
    # The ticker sleeps for a beat (3 s by default): a stop that left it would return the test with a task
    # still running.
    Test.test("stopping the hub ends its task and its ticker") do
      hub = try Hubs.start(HubOptions())
      try Hubs.stop(hub)
      try Task.await(hub.task)
      Test.assert(Hubs.gone?(hub), "the inbox is closed")
    end,
    Test.test("remove ends the connections of the identity and no others, and an unknown identity ends none") do
      hub = try Hubs.start(HubOptions())
      first = inbox_of()
      second = inbox_of()
      other = inbox_of()
      try Hubs.register(hub, 1, "ana", first, line_of(1), 1)
      try Hubs.register(hub, 2, "ana", second, line_of(1), 1)
      try Hubs.register(hub, 3, "ben", other, line_of(1), 1)
      try Hubs.remove(hub, "nobody", true)
      try Hubs.remove(hub, "ana", false)
      try Test.assert(away?(first, false), "the first connection of ana")
      try Test.assert(away?(second, false), "the second connection of ana")
      try Test.assert(not other.recv(200).ok?, "ben hears nothing")
      try Hubs.stop(hub)
      Task.await(hub.task)
    end,
    Test.test("a broadcast gives each subscription of the topic its own identifier, behind its confirmation") do
      hub = try Hubs.start(HubOptions())
      ana = line_of(8)
      ben = line_of(8)
      cat = line_of(8)
      try join(hub, 1, "ana", ana)
      try join(hub, 2, "ben", ben)
      try join(hub, 3, "cat", cat)
      try attach(hub, 1, "one", ["room"])
      try attach(hub, 2, "one", ["room"])
      try attach(hub, 3, "one", ["room"])
      try attach(hub, 3, "two", ["room", "other"])
      try attach(hub, 1, "three", ["other"])
      payload = Protocol.text_payload("hello")
      try Hubs.broadcast(hub, "room", payload)
      try Hubs.broadcast(hub, "nowhere", payload)
      try finish(hub)
      one = framed(Protocol.message("one", payload))
      try Test.eq(written(ana), [framed(confirm("one")), framed(confirm("three")), one])
      try Test.eq(written(ben), [framed(confirm("one")), one])
      Test.eq(
        written(cat),
        [framed(confirm("one")), framed(confirm("two")), one, framed(Protocol.message("two", payload))],
      )
    end,
    Test.test("an attach for a connection the hub does not know is an error, and writes nothing") do
      hub = try Hubs.start(HubOptions())
      try Test.assert(not attach(hub, 9, "one", ["room"]).ok?, "no such connection")
      try Hubs.broadcast(hub, "room", "1")
      try Hubs.stop(hub)
      Task.await(hub.task)
    end,
    Test.test("an unsubscribe silences one identifier and a disconnect all of them, for that connection only") do
      hub = try Hubs.start(HubOptions())
      ana = line_of(8)
      ben = line_of(8)
      try join(hub, 1, "ana", ana)
      try join(hub, 2, "ben", ben)
      try attach(hub, 1, "one", ["room"])
      try attach(hub, 1, "two", ["room"])
      try attach(hub, 2, "one", ["room"])
      try Hubs.detach(hub, 1, "one")
      try Hubs.broadcast(hub, "room", "1")
      try Hubs.disconnect(hub, 1)
      try Hubs.broadcast(hub, "room", "2")
      try finish(hub)
      try Test.eq(written(ana), [framed(confirm("one")), framed(confirm("two")), framed(Protocol.message("two", "1"))])
      Test.eq(
        written(ben),
        [framed(confirm("one")), framed(Protocol.message("one", "1")), framed(Protocol.message("one", "2"))],
      )
    end,
    Test.test("a full queue is one drop, a closed one none, and the others still hear the broadcast") do
      hub = try Hubs.start(HubOptions())
      slow = line_of(1)
      quick = line_of(8)
      ended = line_of(8)
      slow_inbox = inbox_of()
      try Hubs.register(hub, 1, "slow", slow_inbox, slow, 1)
      try join(hub, 2, "quick", quick)
      try join(hub, 3, "ended", ended)
      try attach(hub, 1, "one", ["room"])
      try attach(hub, 2, "one", ["room"])
      try attach(hub, 3, "one", ["room"])
      # Its connection is over and its `Disconnect` not yet handled: the hub finds a closed queue, which is no drop.
      ended.close
      try Hubs.broadcast(hub, "room", "1")
      try Hubs.broadcast(hub, "room", "2")
      try Hubs.broadcast(hub, "room", "3")
      try Test.assert(wait_closed(slow_inbox), "the inbox of the slow connection is closed")
      try slow.recv(0)
      try Hubs.broadcast(hub, "room", "4")
      try finish(hub)
      try Test.eq(Hubs.stats(hub).drops, 1)
      try Test.assert(written(slow).empty?, "the hub no longer routes to the dropped connection")
      heard = ["1", "2", "3", "4"].map do |payload| framed(Protocol.message("one", payload)) end
      Test.eq(written(quick), [framed(confirm("one"))] + heard)
    end,
    # The `Away` event cannot be queued, so the hub closes the inbox and leaves the reason where the loop finds it. It
    # is not a drop, and the slot goes when the connection ends.
    Test.test("remove closes a full inbox, keeps the reason for the connection, and counts no drop") do
      hub = try Hubs.start(HubOptions())
      full: Channel[Hubs.Event] = Channel.new(1)
      try Hubs.register(hub, 1, "ana", full, line_of(1), 1)
      try full.send(Hubs.Event.Ping, 0)
      try Hubs.remove(hub, "ana", false)
      try Test.assert(wait_closed(full), "the inbox is closed")
      reason = Hubs.away_reason(hub, 1)
      try Test.assert(reason.some? and not reason.unwrap!, "reconnect false is kept")
      try Test.eq(Hubs.stats(hub).drops, 0)
      try Hubs.disconnect(hub, 1)
      try Hubs.stop(hub)
      try Task.await(hub.task)
      Test.assert(Hubs.away_reason(hub, 1).none?, "the slot is gone with the connection")
    end,
  ])
end
