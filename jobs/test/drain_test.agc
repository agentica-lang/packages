import Jobs from "../jobs"
import Logger from "std/logger"

private

def logged(max_attempts: Int) -> List[String]
  seen: ATS[String, Int] = ATS.new()
  _ = Logger.attach("drain-test", Logger.Level.Debug) do |event| seen.put("#{event.level} #{event.message}", 1) end
  drain_failing(max_attempts)
  _ = Logger.detach("drain-test")
  seen.keys
end

def drain_failing(max_attempts: Int) -> Void
  clock = Jobs.manual_clock()
  backend = Jobs.memory(Jobs.MemoryOptions(clock: some(clock.now))).unwrap!
  _ = Jobs.enqueue(backend, Jobs.NewJob(queue: "q", payload: "a".bytes, max_attempts: max_attempts))
  plan = Jobs.Drain(queue: "q", clock: some(clock))
  _ = Jobs.drain(backend, plan) do |_job| error("boom") end
  Jobs.close(backend, 1_000)
end

def main() -> Void
  Test.run([
    Test.test("a drain logs a job that will run again as a warning") do
      return Test.eq(logged(3), ["Logger.Level.Warning job failed, it will run again"])
    end,
    Test.test("a drain logs a dead job as an error") do return Test.eq(logged(1), ["Logger.Level.Error job dead"]) end,
  ])
end
