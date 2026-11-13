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

# What the inbox holds, once the hub has handled every message queued before it was stopped.
def frames(inbox: Channel[Hubs.Event]) -> List[String]
  texts: List[String] = []
  while true
    got = inbox.recv(100)
    return texts if not got.ok?

    case got.unwrap!
      Hubs.Event.Frame(text) -> texts = texts.push(text)
      _ -> next
    end
  end

  texts
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
      first: Channel[Hubs.Event] = Channel.new(4)
      second: Channel[Hubs.Event] = Channel.new(4)
      other: Channel[Hubs.Event] = Channel.new(4)
      try Hubs.register(hub, 1, "ana", first, 1)
      try Hubs.register(hub, 2, "ana", second, 1)
      try Hubs.register(hub, 3, "ben", other, 1)
      try Hubs.remove(hub, "nobody", true)
      try Hubs.remove(hub, "ana", false)
      try Test.assert(away?(first, false), "the first connection of ana")
      try Test.assert(away?(second, false), "the second connection of ana")
      try Test.assert(not other.recv(200).ok?, "ben hears nothing")
      try Hubs.stop(hub)
      Task.await(hub.task)
    end,
    Test.test("a broadcast gives each subscription of the topic its own identifier") do
      hub = try Hubs.start(HubOptions())
      ana: Channel[Hubs.Event] = Channel.new(8)
      ben: Channel[Hubs.Event] = Channel.new(8)
      cat: Channel[Hubs.Event] = Channel.new(8)
      try Hubs.register(hub, 1, "ana", ana, 1)
      try Hubs.register(hub, 2, "ben", ben, 1)
      try Hubs.register(hub, 3, "cat", cat, 1)
      try Hubs.attach(hub, 1, "one", ["room"])
      try Hubs.attach(hub, 2, "one", ["room"])
      try Hubs.attach(hub, 3, "one", ["room"])
      try Hubs.attach(hub, 3, "two", ["room", "other"])
      try Hubs.attach(hub, 1, "three", ["other"])
      payload = Protocol.text_payload("hello")
      try Hubs.broadcast(hub, "room", payload)
      try Hubs.broadcast(hub, "nowhere", payload)
      try finish(hub)
      one = Protocol.message("one", payload)
      try Test.eq(frames(ana), [one])
      try Test.eq(frames(ben), [one])
      Test.eq(frames(cat), [one, Protocol.message("two", payload)])
    end,
    Test.test("an unsubscribe silences one identifier and a disconnect all of them, for that connection only") do
      hub = try Hubs.start(HubOptions())
      ana: Channel[Hubs.Event] = Channel.new(8)
      ben: Channel[Hubs.Event] = Channel.new(8)
      try Hubs.register(hub, 1, "ana", ana, 1)
      try Hubs.register(hub, 2, "ben", ben, 1)
      try Hubs.attach(hub, 1, "one", ["room"])
      try Hubs.attach(hub, 1, "two", ["room"])
      try Hubs.attach(hub, 2, "one", ["room"])
      try Hubs.detach(hub, 1, "one")
      try Hubs.broadcast(hub, "room", "1")
      try Hubs.disconnect(hub, 1)
      try Hubs.broadcast(hub, "room", "2")
      try finish(hub)
      try Test.eq(frames(ana), [Protocol.message("two", "1")])
      Test.eq(frames(ben), [Protocol.message("one", "1"), Protocol.message("one", "2")])
    end,
    Test.test("a full inbox is one drop, a closed inbox none, and the others still hear the broadcast") do
      hub = try Hubs.start(HubOptions())
      slow: Channel[Hubs.Event] = Channel.new(1)
      quick: Channel[Hubs.Event] = Channel.new(8)
      ended: Channel[Hubs.Event] = Channel.new(8)
      try Hubs.register(hub, 1, "slow", slow, 1)
      try Hubs.register(hub, 2, "quick", quick, 1)
      try Hubs.register(hub, 3, "ended", ended, 1)
      try Hubs.attach(hub, 1, "one", ["room"])
      try Hubs.attach(hub, 2, "one", ["room"])
      try Hubs.attach(hub, 3, "one", ["room"])
      try slow.send(Hubs.Event.Ping, 0)
      # Its loop is over and its `Disconnect` not yet handled: the hub finds a closed inbox, which is no drop.
      ended.close
      try Hubs.broadcast(hub, "room", "1")
      try Hubs.broadcast(hub, "room", "2")
      try Hubs.broadcast(hub, "room", "3")
      try finish(hub)
      try Test.assert(slow.closed?, "the inbox of the slow connection is closed")
      # One drop, for the slow connection only; the third broadcast would count it again if the hub kept routing to it.
      try Test.eq(Hubs.stats(hub).drops, 1)
      heard = ["1", "2", "3"].map do |payload| Protocol.message("one", payload) end
      Test.eq(frames(quick), heard)
    end,
    # The `Away` event cannot be queued, so the hub closes the inbox and leaves the reason where the loop finds it. It
    # is not a drop, and the slot goes when the connection ends.
    Test.test("remove closes a full inbox, keeps the reason for the connection, and counts no drop") do
      hub = try Hubs.start(HubOptions())
      full: Channel[Hubs.Event] = Channel.new(1)
      try Hubs.register(hub, 1, "ana", full, 1)
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
