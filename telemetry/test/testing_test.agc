import Telemetry from "../telemetry"
import Testing from "../testing"

private

def emit_two(capture: Testing.Capture) -> Result[List[String]]
  Telemetry.execute("mail.send.stop", ints: {"duration_ns": 5})
  Telemetry.execute("mail.send.error", ints: {"duration_ns": 7}, metadata: {"error_kind": "mail.bad"})
  found = try Testing.events(capture)
  ok(found.map(->(event) { event.name }))
end

def main() -> Void
  Test.run([
    Test.test("a session gives the events, and the hub and its tasks are gone when it returns") do
      before = Task.pending_count()
      names = try Testing.session(["mail"], &emit_two)
      try Test.eq(names, ["mail.send.stop", "mail.send.error"])
      try Test.eq(Task.pending_count(), before)
      Test.eq(Telemetry.handlers(), [])
    end,
    Test.test("a session fails when the body fails, and still ends the hub") do
      before = Task.pending_count()
      failed: Result[Int] = Testing.session(["mail"], ->(_capture) { error("no", kind: "my.kind") })
      try Test.assert(not failed.ok?, "the session gave ok")
      try Test.eq(Task.pending_count(), before)
      Test.eq(Telemetry.handlers(), [])
    end,
  ])
end
