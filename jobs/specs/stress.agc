## Many consumers on one queue while producers still add to it, on a manual clock. Each consumer runs its jobs for a
## moment (a yield), and drops every SEVENTH delivery of the first attempt without ack, as a consumer that died would.
## A round ends when the consumers find the queue empty; then the clock moves past the leases, and the dropped jobs
## come back for the next round. The run checks that:
## - no job runs twice at the same time (a counter of the runs of each job never goes above 1);
## - every job runs at least once, and is acked in the end (none is lost);
## - a dropped job ran again, and was acked with a higher attempt;
## - with groups, no group has more live leases than the limit (a count of this run, not a sleep).
##
## With a capture of the events of `jobs`, the run also checks that the events match what happened: the jobs enqueued, the
## jobs fetched (the acked ones and each dropped one), and one ack for each acked job, whatever task acked it.
##
## With a `wait_ms` the consumers fetch with a wait, so many fetches are parked at once and compete for each job.

import Conformance from "pkg/telemetry/conformance"
import Jobs from "../jobs"
import Telemetry from "pkg/telemetry/telemetry"
import Testing from "pkg/telemetry/testing"

## What a run does: `consumers` tasks work off `jobs` jobs, fetching with a wait of `wait_ms` (0 does not wait). With
## `groups` above 0 the jobs are in that many groups and the consumers fetch with `limit` as `max_per_group`.
struct Plan
  consumers: Int
  jobs: Int
  wait_ms: Int = 0
  groups: Int = 0
  limit: Int = 0
end

## Runs the stress and gives `ok`, or what the backend got wrong.
def run(backend: Jobs.Backend, clock: Jobs.Clock, plan: Plan, events: Optional[Testing.Capture]) -> String
  work = Work(
    backend: backend,
    plan: plan,
    running: ATS.new(),
    live: ATS.new(),
    acked: ATS.new(),
    dropped: ATS.new(),
    problems: ATS.new(),
    events: events,
  )

  rounds = 0
  while rounds < MAX_ROUNDS and not finished?(backend, plan.jobs, work.acked)
    play(work, rounds == 0)
    clock.advance.call(LEASE_MS + 1)
    # Every lease ended with the clock, the dropped ones too.
    work.live.clear
    rounds += 1
  end

  verdict(work, rounds)
end

private

QUEUE = "stress"
LEASE_MS = 1_000
MAX_ROUNDS = 10
PRODUCERS = 4
SEVENTH = 7
TASK_MS = 120_000

struct Work
  backend: Jobs.Backend
  plan: Plan
  running: ATS[String, Int]
  live: ATS[String, Int]
  acked: ATS[String, Int]
  dropped: ATS[String, Int]
  problems: ATS[String, Int]
  events: Optional[Testing.Capture]
end

struct Shift
  work: Work
  producing: ATS[String, Int]
  producer: Int
end

def finished?(backend: Jobs.Backend, jobs: Int, acked: ATS[String, Int]) -> Bool
  return false if acked.size < jobs

  case Jobs.counts(backend, QUEUE)
    ok(counts) -> counts.ready + counts.scheduled + counts.leased == 0
    error(_) -> false
  end
end

# One round: the producers add the jobs (in the first round) while the consumers work, and each consumer stops when it
# finds the queue empty and the producers are done.
def play(work: Work, first: Bool) -> Void
  producing: ATS[String, Int] = ATS.new()
  producing.put("left", if_first(first))
  producers = (0...PRODUCERS).map(
    ->(n) { Task.spawn do produce(Shift(work: work, producing: producing, producer: n)) end },
  )

  workers = (0...work.plan.consumers).map(->(n) { Task.spawn do consume(work, producing, n) end })
  for task in producers
    _ = Task.await(task, TASK_MS)
  end

  for task in workers
    _ = Task.await(task, TASK_MS)
  end
end

def if_first(first: Bool) -> Int
  return PRODUCERS if first

  0
end

# The last producer takes what the division left.
def share_of(shift: Shift, from: Int) -> Int
  return shift.work.plan.jobs - from if shift.producer == PRODUCERS - 1

  shift.work.plan.jobs / PRODUCERS
end

# The group of the job with this number: they are dealt in turn, so every group has jobs from every producer.
def group_of(plan: Plan, number: Int) -> Optional[String]
  return none if plan.groups == 0

  some("g#{number % plan.groups}")
end

def produce(shift: Shift) -> Void
  if shift.producing.get("left").unwrap_or(0) > 0
    from = shift.producer * (shift.work.plan.jobs / PRODUCERS)
    count = share_of(shift, from)
    count.times do |n|
      new = Jobs.NewJob(queue: QUEUE, payload: "job #{from + n}".bytes, group: group_of(shift.work.plan, from + n))
      _ = Jobs.enqueue(shift.work.backend, new)
    end

    _ = shift.producing.add("left", -1)
  end
end

# A consumer fetches one job at a time. An empty fetch while the producers are still adding is not the end.
def consume(work: Work, producing: ATS[String, Int], me: Int) -> Void
  idle = false
  while not idle
    case Jobs.fetch(
      work.backend,
      Jobs.Fetch(queue: QUEUE, lease_ms: LEASE_MS, wait_ms: work.plan.wait_ms, max_per_group: work.plan.limit),
    )
      error(_) -> problem(work, "a fetch failed")
      ok(leases) if leases.empty? -> idle = producing.get("left").unwrap_or(0) == 0
      ok(leases) -> handle(work, leases[0], me)
    end

    Task.sleep(0)
  end
end

def problem(work: Work, text: String) -> Void
  _ = work.problems.add(text, 1)
end

# The job runs for a yield. A dropped job is not acked, and its lease runs out.
def handle(work: Work, lease: Jobs.Lease, me: Int) -> Void
  id = lease.job.id
  if work.running.add(id, 1) > 1
    problem(work, "job #{id} ran twice at the same time")
  end

  count_live(work, lease, 1)
  Task.sleep(0)
  _ = work.running.add(id, -1)
  if dropped?(lease, me)
    work.dropped.put(id, 1)
    return
  end

  # The count goes down before the ack, so it is never above what the backend holds: a group over its limit here is a
  # group that the backend gave too many jobs.
  count_live(work, lease, -1)
  case Jobs.ack(work.backend, lease)
    ok(_) -> work.acked.put(id, lease.job.attempt)
    error(_) -> problem(work, "an ack of job #{id} failed")
  end
end

# The live leases of the group of the job, as this run sees them: a dropped one stays until the clock moves. A group
# with more than the limit is a problem.
def count_live(work: Work, lease: Jobs.Lease, change: Int) -> Void
  case lease.job.group
    some(group) ->
      live = work.live.add(group, change)
      if live > work.plan.limit and work.plan.limit > 0
        problem(work, "the group #{group} has #{live} live leases, and the limit is #{work.plan.limit}")
      end

    none -> nil
  end
end

def dropped?(lease: Jobs.Lease, me: Int) -> Bool
  lease.job.attempt == 1 and (lease.job.id.to_i.unwrap_or(0) + me) % SEVENTH == 0
end

def verdict(work: Work, rounds: Int) -> String
  for id in work.dropped.keys
    if work.acked.get(id).unwrap_or(0) < 2
      problem(work, "the dropped job #{id} was not acked with a higher attempt")
    end
  end

  if work.dropped.size == 0
    problem(work, "no job was dropped")
  end

  case work.events
    some(made) -> match_events(work, made)
    none -> nil
  end

  return "ok" if work.problems.size == 0 and work.acked.size == work.plan.jobs

  "#{work.acked.size} of #{work.plan.jobs} jobs acked after #{rounds} rounds; problems: #{work.problems.to_map}"
end

# What the events say must be what the run did: every job enqueued once, every delivery fetched (the acked jobs and the
# dropped ones, which came back once), and every acked job acked once, with the attempt that the run saw.
def match_events(work: Work, made: Testing.Capture) -> Void
  case Testing.events(made)
    error(e) -> problem(work, "the events gave #{e.kind}")
    ok(found) -> match_found(work, found)
  end
end

def match_found(work: Work, found: List[Telemetry.Event]) -> Void
  enqueued = 0
  fetched = 0
  acks: ATS[String, Int] = ATS.new()
  for event in found
    if not Conformance.check(event).ok?
      problem(work, "the event #{event.name} breaks the conventions")
    end

    case event.name
      "jobs.enqueue" -> enqueued += event.ints.get("count", 0)
      "jobs.fetch" -> fetched += event.ints.get("count", 0)
      "jobs.ack" -> count_ack(work, acks, event)
      _ -> problem(work, "an event named #{event.name}")
    end
  end

  if enqueued != work.plan.jobs
    problem(work, "the events enqueued #{enqueued} jobs, not #{work.plan.jobs}")
  end

  if fetched != work.acked.size + work.dropped.size
    problem(work, "the events fetched #{fetched} jobs, not #{work.acked.size} acked and #{work.dropped.size} dropped")
  end

  if acks.size != work.acked.size or work.acked.keys.any?(->(id) { acks.get(id).unwrap_or(0) != 1 })
    problem(work, "the events acked #{acks.size} jobs, and the run acked #{work.acked.size}")
  end
end

def count_ack(work: Work, acks: ATS[String, Int], event: Telemetry.Event) -> Void
  id = event.metadata.get("id", "")
  if acks.add(id, 1) > 1
    problem(work, "the job #{id} was acked twice")
  end

  if event.metadata.get("attempt", "") != work.acked.get(id).unwrap_or(0).to_s
    problem(work, "the ack of the job #{id} has the attempt #{event.metadata.get("attempt", "")}")
  end
end
