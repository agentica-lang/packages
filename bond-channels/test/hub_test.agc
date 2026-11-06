import Hubs from "../src/hub"
import {HubOptions} from "../src/types"

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
  ])
end
