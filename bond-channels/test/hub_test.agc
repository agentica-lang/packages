import Hubs from "../src/hub"
import {HubOptions} from "../src/types"

# True when the next event of the inbox is `Away(reconnect)`.
def away?(inbox: Channel[Hubs.Event], reconnect: Bool) -> Bool
  got = inbox.recv(2_000)
  if not got.ok?
    return false
  end

  case got.unwrap!
    Hubs.Event.Away(again) -> return again == reconnect
    _ -> return false
  end
end

def wait_closed(inbox: Channel[Hubs.Event]) -> Bool
  for _ in 1..200
    if inbox.closed?
      return true
    end

    Task.sleep(10)
  end

  return false
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
