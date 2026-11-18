## The steps of the features. They drive `Pool` through `driver.agc`, which holds the pool and its jobs (see
## `protocol.agc`). A job is a caller that takes a resource, uses it in a way its name says, and gives it back; the
## resource is a fake cell, and its counters (`made`, `terminated`, `peak`, ...) are what the scenarios check.

import BDD from "std/bdd"
import Protocol from "protocol"
import {Count, Expect, Failing, Flood, Job, Kind, Match, Race, Request, Timeout} from "protocol"

private

REPLY_MS = 60_000

def main() -> Void
  BDD.run([
    BDD.step("the driver runs on {int} scheduler") do |ctx, args|
      BDD.given_env(ctx, "AGENTICA_SCHEDULERS", args[0])
    end,
    BDD.step("a pool with:") do |ctx, _args| send(ctx, Request.Start(BDD.table(ctx))) end,
    BDD.step("a pool started in a task of its own, with:") do |ctx, _args|
      send(ctx, Request.StartOwned(BDD.table(ctx)))
    end,
    BDD.step("the task that started the pool ends") do |ctx, _args| send(ctx, Request.EndStarter) end,
    BDD.step("starting a pool with these settings fails with {string}:") do |ctx, args|
      send(ctx, Request.StartFails(Failing(text: args[0], table: BDD.table(ctx))))
    end,
    BDD.step("job {string} holds a resource for {int} ms") do |ctx, args|
      send(ctx, Request.Job(Job(name: args[0], kind: Kind.Holds, ms: args[1].to_i!)))
    end,
    BDD.step("job {string} holds a resource for {int} ms, {int} times") do |ctx, args|
      send(ctx, Request.Job(Job(name: args[0], kind: Kind.Holds, ms: args[1].to_i!, times: args[2].to_i!)))
    end,
    BDD.step("job {string} probes the pool for {int} ms") do |ctx, args|
      send(ctx, Request.Job(Job(name: args[0], kind: Kind.Probe, ms: args[1].to_i!)))
    end,
    BDD.step("{int} callers each take a resource and give it back at once") do |ctx, args|
      send(ctx, Request.Flood(Flood(callers: args[0].to_i!)))
    end,
    BDD.step("{int} callers each take a resource and hold it for {int} ms") do |ctx, args|
      send(ctx, Request.Flood(Flood(callers: args[0].to_i!, hold_ms: args[1].to_i!)))
    end,
    BDD.step("{int} callers each take a resource {int} times") do |ctx, args|
      send(ctx, Request.Flood(Flood(callers: args[0].to_i!, times: args[1].to_i!)))
    end,
    BDD.step("job {string} keeps taking a resource for {int} ms") do |ctx, args|
      send(ctx, Request.Job(Job(name: args[0], kind: Kind.Loops, ms: args[1].to_i!)))
    end,
    job_step("job {string} crashes", Kind.Crashes),
    job_step("job {string} returns an error", Kind.Fails),
    job_step("job {string} never returns", Kind.Hangs),
    job_step("job {string} holds a resource until the jobs are released", Kind.Gated),
    job_step("job {string} checks out again inside its body", Kind.Nests),
    BDD.step("the caller of job {string} is cancelled") do |ctx, args| send(ctx, Request.CancelJob(args[0])) end,
    BDD.step("{int} callers are cancelled one after the other as their bodies crash {int} ms in") do |ctx, args|
      send(ctx, Request.RaceCrash(Race(callers: args[0].to_i!, crash_ms: args[1].to_i!)))
    end,
    BDD.step("the driver ends with code {int}") do |ctx, args|
      BDD.then_exit(BDD.when_eof(ctx), args[0].to_i!, REPLY_MS)
    end,
    BDD.step("I wait for the jobs") do |ctx, _args| send(ctx, Request.WaitJobs) end,
    BDD.step("the jobs are released") do |ctx, _args| send(ctx, Request.Release) end,
    BDD.step("I wait {int} ms") do |ctx, args| send(ctx, Request.Sleep(args[0].to_i!)) end,
    BDD.step("I close the pool, giving the jobs {int} ms to finish") do |ctx, args|
      send(ctx, Request.Close(args[0].to_i!))
    end,
    BDD.step("job {string} succeeds") do |ctx, args|
      send(ctx, Request.ExpectJob(Expect(name: args[0], text: "ok")))
    end,
    BDD.step("job {string} gets {string}") do |ctx, args|
      send(ctx, Request.ExpectJob(Expect(name: args[0], text: args[1])))
    end,
    BDD.step("job {string} fails with a pool timeout") do |ctx, args|
      send(ctx, Request.ExpectTimeout(Timeout(name: args[0])))
    end,
    BDD.step("job {string} succeeds or fails with a pool timeout") do |ctx, args|
      send(ctx, Request.ExpectTimeout(Timeout(name: args[0], or_ok: true)))
    end,
    BDD.step("job {string} fails with the kind {string}") do |ctx, args|
      send(ctx, Request.ExpectKind(Expect(name: args[0], text: args[1])))
    end,
    BDD.step("the jobs ended in this order: {string}") do |ctx, args| send(ctx, Request.ExpectOrder(args[0])) end,
    BDD.step("the checkout and the body ran in one task") do |ctx, _args| send(ctx, Request.ExpectOneTask) end,
    BDD.step("the count {string} is {int}") do |ctx, args|
      send(ctx, Request.ExpectCount(Count(name: args[0], value: args[1].to_i!, match: Match.Is)))
    end,
    BDD.step("the count {string} is at most {int}") do |ctx, args|
      send(ctx, Request.ExpectCount(Count(name: args[0], value: args[1].to_i!, match: Match.AtMost)))
    end,
    BDD.step("the pool counts {int} {string} within {int} ms") do |ctx, args|
      send(
        ctx,
        Request.ExpectPoolCount(Count(name: args[1], value: args[0].to_i!, match: Match.Is, wait_ms: args[2].to_i!)),
      )
    end,
    BDD.step("the count {string} reaches {int} within {int} ms") do |ctx, args|
      send(
        ctx,
        Request.ExpectCount(Count(name: args[0], value: args[1].to_i!, match: Match.Reaches, wait_ms: args[2].to_i!)),
      )
    end,
  ])
end

def job_step(pattern: String, kind: Kind) -> BDD.Step
  BDD.step(pattern) do |ctx, args| send(ctx, Request.Job(Job(name: args[0], kind: kind))) end
end

# Sends the request to the driver, started on the first one, and checks that it answers ok. The driver puts what went
# wrong in the reply, which shows as the actual line of the failed check.
def send(ctx: BDD.Context, req: Request) -> BDD.Context
  running = start(ctx)
  asked = BDD.when_line(running, JSON.encode(req))
  BDD.then_line(asked, Protocol.OK, REPLY_MS)
end

def start(ctx: BDD.Context) -> BDD.Context
  return ctx if BDD.get(ctx, "driver").ok?

  BDD.set(BDD.given_program(ctx, "driver.agc"), "driver", JSON.from(true))
end
