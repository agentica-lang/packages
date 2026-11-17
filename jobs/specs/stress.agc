## Many consumers on one queue while producers still add to it, on a manual clock. Each consumer runs its jobs for a
## moment (a yield), and drops every SEVENTH delivery of the first attempt without ack, as a consumer that died would.
## A round ends when the consumers find the queue empty; then the clock moves past the leases, and the dropped jobs
## come back for the next round. The run checks that:
## - no job runs twice at the same time (a counter of the runs of each job never goes above 1);
## - every job runs at least once, and is acked in the end (none is lost);
## - a dropped job ran again, and was acked with a higher attempt.
##
## With a `wait_ms` the consumers fetch with a wait, so many fetches are parked at once and compete for each job.

import Jobs from "../jobs"

## Runs the stress and gives `ok`, or what the backend got wrong.
def run(backend: Jobs.Backend, clock: Jobs.Clock, consumers: Int, jobs: Int, wait_ms: Int) -> String
  running: ATS[String, Int] = ATS.new()
  acked: ATS[String, Int] = ATS.new()
  dropped: ATS[String, Int] = ATS.new()
  problems: ATS[String, Int] = ATS.new()
  work = Work(backend: backend, running: running, acked: acked, dropped: dropped, problems: problems, wait_ms: wait_ms)
  rounds = 0
  while rounds < MAX_ROUNDS and not finished?(backend, jobs, acked)
    play(work, rounds == 0, consumers, jobs)
    clock.advance.call(LEASE_MS + 1)
    rounds += 1
  end

  verdict(work, jobs, rounds)
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
  running: ATS[String, Int]
  acked: ATS[String, Int]
  dropped: ATS[String, Int]
  problems: ATS[String, Int]
  wait_ms: Int
end

struct Shift
  work: Work
  producing: ATS[String, Int]
  producer: Int
  jobs: Int
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
def play(work: Work, first: Bool, consumers: Int, jobs: Int) -> Void
  producing: ATS[String, Int] = ATS.new()
  producing.put("left", if_first(first))
  producers = (0...PRODUCERS).map(
    ->(n) { Task.spawn do produce(Shift(work: work, producing: producing, producer: n, jobs: jobs)) end },
  )

  workers = (0...consumers).map(->(n) { Task.spawn do consume(work, producing, n) end })
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
  return shift.jobs - from if shift.producer == PRODUCERS - 1

  shift.jobs / PRODUCERS
end

def produce(shift: Shift) -> Void
  if shift.producing.get("left").unwrap_or(0) > 0
    from = shift.producer * (shift.jobs / PRODUCERS)
    count = share_of(shift, from)
    count.times do |n|
      new = Jobs.NewJob(queue: QUEUE, payload: "job #{from + n}".bytes)
      _ = Jobs.enqueue(shift.work.backend, new)
    end

    _ = shift.producing.add("left", -1)
  end
end

# A consumer fetches one job at a time. An empty fetch while the producers are still adding is not the end.
def consume(work: Work, producing: ATS[String, Int], me: Int) -> Void
  idle = false
  while not idle
    case Jobs.fetch(work.backend, Jobs.Fetch(queue: QUEUE, lease_ms: LEASE_MS, wait_ms: work.wait_ms))
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

  Task.sleep(0)
  _ = work.running.add(id, -1)
  if dropped?(lease, me)
    work.dropped.put(id, 1)
    return
  end

  case Jobs.ack(work.backend, lease)
    ok(_) -> work.acked.put(id, lease.job.attempt)
    error(_) -> problem(work, "an ack of job #{id} failed")
  end
end

def dropped?(lease: Jobs.Lease, me: Int) -> Bool
  lease.job.attempt == 1 and (lease.job.id.to_i.unwrap_or(0) + me) % SEVENTH == 0
end

def verdict(work: Work, jobs: Int, rounds: Int) -> String
  for id in work.dropped.keys
    if work.acked.get(id).unwrap_or(0) < 2
      problem(work, "the dropped job #{id} was not acked with a higher attempt")
    end
  end

  if work.dropped.size == 0
    problem(work, "no job was dropped")
  end

  return "ok" if work.problems.size == 0 and work.acked.size == jobs

  "#{work.acked.size} of #{jobs} jobs acked after #{rounds} rounds; problems: #{work.problems.to_map}"
end
